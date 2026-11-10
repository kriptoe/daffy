// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICoreWriterV2 {
    function sendRawAction(bytes calldata data) external;
}

/// @notice Circle's CoreDepositWallet on HyperEVM: moves native USDC to the caller's HyperCore account.
interface ICoreDepositWallet {
    function deposit(uint256 amount, uint32 destinationDex) external;
}

/// @title DaffyUSDHyperCore - the v2 treasury's HyperCore account
/// @notice Linked library (public functions, called via DELEGATECALL), so it runs as DaffyUSD and
///         CoreWriter actions act on DaffyUSD's own HyperCore account. One action per EVM block:
///         reads show HyperCore as of the start of the block and actions run after it, so every
///         decision is made from fresh reads.
///
///         What it does, in priority order, each block:
///         a. dip tranches: HYPE 25% / 40% / 55% below its high -> pull a third of the dip fund
///            out of lending and earmark it for HYPE buys
///         b. buy HYPE with earmarked USDC, IOC on spot, in chunks
///         c. rally trims: HYPE over 80% of the treasury and within 10% of its high -> sell back
///            to 70%. Never otherwise: HYPE is never sold into a dump
///         d. refill the DAFF/HYPE pool bid by sending HYPE to the EVM, capped per week
///         e. supply idle USDC to HyperCore lending (the dip fund)
///
///         HyperCore facts this relies on (VERIFY on mainnet with test mode first):
///         - lending: CoreWriter action 15 (op, token, wei): op 0 supply, 1 withdraw, wei 0 = max;
///           precompile 0x811 returns (borrow basis, borrow value, supply basis, supply value)
///         - USDC EVM -> Core: approve + CoreDepositWallet.deposit(amount, spot dex)
///         - USDC Core -> EVM: sendAsset to 0x2000..0000 (USDC's system address)
///         - HYPE Core -> EVM: sendAsset to 0x2222..2222; arrives as native HYPE
///         - spot prices: 5 significant figures, (8 - szDecimals) decimals; sizes szDecimals
library DaffyUSDHyperCore {
    using SafeERC20 for IERC20;

    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address internal constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;
    address internal constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;
    address internal constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant CORE_USER_EXISTS = 0x0000000000000000000000000000000000000810;
    address internal constant BORROW_LEND_USER = 0x0000000000000000000000000000000000000811;

    /// @dev Gas for each precompile read. A read costs 2000 + 65 * (input + output bytes), under 20k
    ///      here, but one that errors "consumes all gas passed into the precompile call frame", so it
    ///      must never get all the gas left.
    uint256 internal constant PRECOMPILE_GAS = 50_000;

    uint24 internal constant LIMIT_ORDER = 1;
    uint24 internal constant SEND_ASSET = 13;
    uint24 internal constant BORROW_LEND = 15;
    uint24 internal constant SET_ABSTRACTION = 16;
    uint8 internal constant TIF_IOC = 3;
    uint32 internal constant SPOT_DEX = type(uint32).max;
    uint256 internal constant SCALE = 1e10; // WAD -> HyperCore 8 decimals
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    struct Config {
        uint64 hypeToken; // 150 on mainnet
        uint64 usdcToken; // 0
        uint32 perpIndex; // HYPE perp, for the oracle price: 159
        uint32 spotAsset; // HYPE/USDC spot asset: 10107
        uint8 perpSzDecimals; // 2
        uint8 spotSzDecimals; // 2
        uint8 pmAbstraction; // 3: "portfolio margin" for CoreWriter action 16
        bool borrowAtLaunch; // borrow tranche on from launch (portfolio margin switched on after launch)
        // HyperCore delays orders sent from the EVM "for a few seconds". Until an order has had this
        // long to execute, balance reads are stale, so the strategy takes no further step.
        uint32 orderSettleSecs; // 20
    }

    struct Rules {
        uint16 dip1Bps; // 2500: first tranche at 25% below the high
        uint16 dip2Bps; // 4000
        uint16 dip3Bps; // 5500: the rest of the fund
        uint16 trimShareBps; // 8000: trim when HYPE is over 80% of the treasury...
        uint16 trimTargetBps; // 7000: ...back down to 70%...
        uint16 trimNearHighBps; // 9000: ...only while HYPE is within 10% of its high
        uint16 hypeBidBps; // 1500: DAFF/HYPE pool bid target, share of the treasury
        uint16 refillCapBps; // 500: most HYPE sent to the bid per window, share of all treasury HYPE
        uint16 slippageBps; // 100: IOC limit 1% through the oracle
        uint32 refillWindow; // 7 days
        uint256 minTradeUsd; // 10e18: Hyperliquid's minimum order
        uint256 maxTradeUsd; // largest single spot order (WAD USD)
        // optional borrow tranche (portfolio margin; off until the migrator turns it on)
        uint16 borrowBps; // 2000: after the third tranche, borrow up to 20% of the HYPE's value
        uint16 deleverageBps; // 5000: debt over 50% of the HYPE's value -> sell back to...
        uint16 deleverageTargetBps; // 4000: ...40%. Liquidation: 0.95 margin ratio at 0.65 LTV, debt near 62% of the HYPE
        // deeper dips after bigger runs: every tranche goes dipStepBps deeper for each dipStepRiseBps
        // the high is above the launch price, by at most dipMaxExtraBps
        uint16 dipStepBps; // 500: 5 percentage points deeper...
        uint16 dipStepRiseBps; // 5000: ...per 50% above the launch price...
        uint16 dipMaxExtraBps; // 1500: ...at most 15 points deeper
    }

    struct State {
        Config cfg;
        uint64 actedBlock; // last block a CoreWriter action was sent
        uint64 budgetBlock; // last block the buy budget grew (its USDC lands a block later)
        uint64 inflightBlock; // block of the last EVM -> Core USDC bridge
        uint64 windowStart; // HYPE bid refill window
        uint8 tranchesFired; // 0..3 since the last high
        bool seeded; // the HYPE bid has been filled once (the weekly cap applies after)
        bool lendingSeeded; // one supply was tried while the lending read failed
        bool borrowEnabled; // the migrator turned the borrow tranche on (portfolio margin)
        bool borrowFired; // borrowed in this dip; resets at a new high once the debt is repaid
        bool pmSent; // the switch to portfolio margin has been sent
        uint64 orderAt; // when the last spot order or HYPE send went out (see orderSettleSecs)
        uint256 highPx; // highest oracle price seen at upkeep (WAD USD)
        uint256 launchPx; // oracle price at launch (WAD USD)
        uint256 trancheSize; // a third of the dip fund when the first tranche fired (WAD USD)
        uint256 buyBudget; // USDC on HyperCore earmarked for HYPE buys (WAD USD)
        uint256 inflightUsd; // USDC bridged in `inflightBlock`, not yet visible on HyperCore (WAD)
        uint256 refilledInWindow; // HYPE sent to the bid this window (WAD)
        uint256 borrowBudget; // USD still to buy with borrowed USDC (WAD)
    }

    /// @notice HyperCore account as of the start of the block (all WAD).
    struct Snapshot {
        uint256 px; // oracle price, USD per HYPE
        uint256 hype; // spot HYPE
        uint256 usdc; // spot USDC (USD)
        uint256 supplied; // USDC supplied to lending, with interest (USD)
        bool lendingReadable; // the 0x811 read worked; if not, the dip fund stays as spot USDC
        uint256 borrowed; // USDC borrowed under portfolio margin, with interest (USD)
    }

    /// @notice Treasury totals the core computes (WAD).
    struct Totals {
        uint256 total; // everything, in USD
        uint256 hypeAllUsd; // every HYPE the treasury holds, in USD
        uint256 hypeAll; // every HYPE the treasury holds, in HYPE
        uint256 hypeBidUsd; // HYPE in or waiting for the DAFF/HYPE bid, in USD
    }

    error PrecompileFailed(address precompile);

    event DipTranche(uint8 tranche, uint256 usd, uint256 px);
    event HypeBought(uint256 usd, uint256 limitPx);
    event RallyTrim(uint256 usd, uint256 limitPx);
    event HypeBidRefill(uint256 hype);
    event UsdcSupplied(uint256 usd);
    event UsdcBridged(uint256 usd);
    event Borrowed(uint256 usd, uint256 px);
    event Deleveraged(uint256 usd, uint256 px);
    event BorrowingSet(bool on);

    // ------------------------------------------------------------------ views

    function snapshot(State storage s) public view returns (Snapshot memory n) {
        n.px = oraclePrice(s);
        n.hype = uint256(_spot(s.cfg.hypeToken)) * SCALE;
        n.usdc = uint256(_spot(s.cfg.usdcToken)) * SCALE;
        // Lending state. If the read fails (seen on mainnet for an account that has never used
        // lending), count nothing there and don't supply: the dip fund stays as spot USDC instead.
        (bool ok, bytes memory ret) = BORROW_LEND_USER.staticcall{gas: PRECOMPILE_GAS}(abi.encode(address(this), s.cfg.usdcToken));
        if (ok && ret.length >= 128) {
            (, uint64 borrowValue,, uint64 supplyValue) = abi.decode(ret, (uint64, uint64, uint64, uint64));
            n.supplied = uint256(supplyValue) * SCALE;
            n.borrowed = uint256(borrowValue) * SCALE;
            n.lendingReadable = true;
        }
    }

    /// @notice USDC bridged this block that HyperCore doesn't show yet (WAD USD).
    function inflight(State storage s) public view returns (uint256) {
        return s.inflightBlock == block.number ? s.inflightUsd : 0;
    }

    function oraclePrice(State storage s) public view returns (uint256) {
        (bool ok, bytes memory ret) = ORACLE_PX.staticcall{gas: PRECOMPILE_GAS}(abi.encode(s.cfg.perpIndex));
        if (!ok || ret.length < 32) revert PrecompileFailed(ORACLE_PX);
        uint64 raw = abi.decode(ret, (uint64)); // 6 - szDecimals decimals
        if (raw == 0) revert PrecompileFailed(ORACLE_PX);
        return uint256(raw) * 10 ** (12 + s.cfg.perpSzDecimals);
    }

    function coreUserExists(address user) public view returns (bool) {
        (bool ok, bytes memory ret) = CORE_USER_EXISTS.staticcall{gas: PRECOMPILE_GAS}(abi.encode(user));
        if (!ok || ret.length < 32) revert PrecompileFailed(CORE_USER_EXISTS);
        return abi.decode(ret, (bool));
    }

    /// @notice False while the last order may not have executed on HyperCore yet.
    function settled(State storage s) public view returns (bool) {
        return block.timestamp >= uint256(s.orderAt) + s.cfg.orderSettleSecs;
    }

    /// @notice How many basis points deeper every dip tranche sits, given how far the high is above
    ///         the launch price (0 at or below it).
    function dipExtraBps(State storage s, Rules memory r) public view returns (uint256) {
        if (s.launchPx == 0 || s.highPx <= s.launchPx || r.dipStepRiseBps == 0) return 0;
        uint256 riseBps = ((s.highPx - s.launchPx) * BPS) / s.launchPx;
        uint256 extra = (riseBps * r.dipStepBps) / r.dipStepRiseBps;
        return extra > r.dipMaxExtraBps ? r.dipMaxExtraBps : extra;
    }

    // ------------------------------------------------------------------ actions

    /// @notice Send `amount` USDC (6 decimals) from the core to its HyperCore spot balance.
    ///         `hypeShareBps` of it is earmarked for HYPE buys; the rest goes to the dip fund.
    function bridgeUsdc(State storage s, IERC20 usdc, address depositWallet, uint256 amount, uint256 hypeShareBps)
        public
    {
        if (amount == 0) return;
        usdc.forceApprove(depositWallet, amount);
        ICoreDepositWallet(depositWallet).deposit(amount, SPOT_DEX);
        uint256 usd = amount * 1e12;
        if (s.inflightBlock == block.number) {
            s.inflightUsd += usd;
        } else {
            s.inflightBlock = uint64(block.number);
            s.inflightUsd = usd;
        }
        if (hypeShareBps > 0) {
            s.buyBudget += (usd * hypeShareBps) / BPS;
            s.budgetBlock = uint64(block.number);
        }
        emit UsdcBridged(usd);
    }

    /// @notice One upkeep step (see the library notes). Returns true when it did something a keeper
    ///         should be paid for: a dip tranche, a rally trim or a HYPE bid refill.
    function tick(State storage s, Rules memory r, Totals memory t, Snapshot memory n) public returns (bool) {
        if (s.actedBlock == block.number) return false;
        if (n.px > s.highPx) {
            s.highPx = n.px;
            s.tranchesFired = 0;
            s.trancheSize = 0;
        }
        // an order may still be on its way: the balances read this block don't show it yet, so acting
        // on them would repeat the trade or spend the USDC it needs
        if (!settled(s)) return false;

        // the borrow tranche re-arms once the loan is repaid and a new high has reset the tranches
        if (s.borrowFired && n.borrowed == 0 && s.tranchesFired == 0) s.borrowFired = false;

        // borrow tranche on from launch: switch to portfolio margin once the launch USDC has landed
        // (portfolio margin needs over $10k of account value). If HyperCore ignores the switch, the
        // borrow tranche's buy just fails on HyperCore and nothing else changes.
        if (s.borrowEnabled && !s.pmSent && block.number > uint256(s.budgetBlock) + 1) {
            _action(SET_ABSTRACTION, abi.encode(address(this), s.cfg.pmAbstraction));
            s.pmSent = true;
            s.actedBlock = uint64(block.number);
            emit BorrowingSet(true);
            return false;
        }

        // 0. too much debt (borrow tranche only): sell just enough HYPE to get back under the target
        if (n.borrowed > 0) {
            uint256 coll = (n.hype * n.px) / WAD;
            if (n.borrowed * BPS > coll * r.deleverageBps) {
                uint256 sell = n.borrowed - (coll * r.deleverageTargetBps) / BPS;
                sell = (sell * BPS) / (BPS - r.deleverageTargetBps); // selling also shrinks the collateral
                sell = _min(_min(sell, coll), r.maxTradeUsd);
                if (sell >= r.minTradeUsd) {
                    uint64 limit = _spotTrade(s, r, n.px, sell, false);
                    if (limit > 0) {
                        s.borrowBudget = 0;
                        emit Deleveraged(sell, limit);
                        return true;
                    }
                }
            }
        }

        // a. dip tranches: the fund is what's in lending, or idle spot USDC when lending isn't readable
        uint256 fund = n.supplied + (n.usdc > s.buyBudget ? n.usdc - s.buyBudget : 0);
        uint256 extra = dipExtraBps(s, r);
        if (s.tranchesFired < 3 && fund >= r.minTradeUsd) {
            uint256 lvl = extra + (s.tranchesFired == 0 ? r.dip1Bps : s.tranchesFired == 1 ? r.dip2Bps : r.dip3Bps);
            if (n.px * BPS <= s.highPx * (BPS - lvl)) {
                if (s.trancheSize == 0) s.trancheSize = fund / 3;
                bool last = s.tranchesFired == 2 || s.trancheSize >= fund;
                uint256 amt = last ? fund : s.trancheSize;
                // take it from spot first, then from lending (which lands next block)
                uint256 spot = fund - n.supplied;
                if (amt > spot) {
                    uint256 fromLending = amt - spot;
                    bool all = last || fromLending >= n.supplied;
                    _action(BORROW_LEND, abi.encode(uint8(1), s.cfg.usdcToken, all ? uint64(0) : uint64(fromLending / SCALE)));
                    s.actedBlock = uint64(block.number);
                }
                s.buyBudget += amt;
                s.budgetBlock = uint64(block.number);
                s.tranchesFired = last ? 3 : s.tranchesFired + 1;
                emit DipTranche(s.tranchesFired, amt, n.px);
                if (s.actedBlock == block.number) return true;
            }
        }

        // a2. borrow tranche: dip fund spent (all three tranches fired and their USDC used up, so the
        //     buy really borrows), HYPE still at the third level, no debt yet
        if (
            s.borrowEnabled && s.pmSent && n.lendingReadable && !s.borrowFired && s.tranchesFired == 3
                && n.borrowed == 0 && s.buyBudget == 0
                && n.usdc < r.minTradeUsd && n.px * BPS <= s.highPx * (BPS - r.dip3Bps - extra)
        ) {
            s.borrowFired = true;
            s.borrowBudget = (((n.hype * n.px) / WAD) * r.borrowBps) / BPS;
            emit Borrowed(s.borrowBudget, n.px);
        }
        if (s.borrowBudget > 0) {
            uint256 spend = _min(s.borrowBudget, r.maxTradeUsd);
            if (spend >= r.minTradeUsd) {
                uint64 limit = _spotTrade(s, r, n.px, spend, true);
                if (limit > 0) {
                    s.borrowBudget -= spend;
                    emit HypeBought(spend, limit);
                    return true;
                }
            }
            s.borrowBudget = 0;
        }

        // b. buy HYPE with earmarked USDC (it lands a block after it was earmarked)
        if (block.number > uint256(s.budgetBlock) + 1 && s.buyBudget > n.usdc) s.buyBudget = n.usdc;
        if (s.buyBudget < r.minTradeUsd && block.number > uint256(s.budgetBlock) + 1) s.buyBudget = 0;
        if (s.buyBudget > 0) {
            uint256 spend = _min(_min(s.buyBudget, n.usdc), r.maxTradeUsd);
            if (spend >= r.minTradeUsd) {
                uint64 limit = _spotTrade(s, r, n.px, spend, true);
                if (limit > 0) {
                    s.buyBudget -= spend;
                    emit HypeBought(spend, limit);
                    return false;
                }
            }
        }

        // c. rally trims, only near the high and never while buying
        if (
            s.buyBudget == 0 && t.hypeAllUsd * BPS > t.total * r.trimShareBps
                && n.px * BPS >= s.highPx * r.trimNearHighBps
        ) {
            uint256 sell = t.hypeAllUsd - (t.total * r.trimTargetBps) / BPS;
            sell = _min(_min(sell, (n.hype * n.px) / WAD), r.maxTradeUsd);
            if (sell >= r.minTradeUsd) {
                uint64 limit = _spotTrade(s, r, n.px, sell, false);
                if (limit > 0) {
                    emit RallyTrim(sell, limit);
                    return true;
                }
            }
        }

        // d. refill the DAFF/HYPE pool bid from HYPE held here
        uint256 target = (t.total * r.hypeBidBps) / BPS;
        if (!s.seeded && t.hypeBidUsd * 10 >= target * 9 && t.hypeBidUsd > 0) s.seeded = true;
        if (t.hypeBidUsd * 10 < target * 9 && n.borrowed == 0) {
            if (block.timestamp >= uint256(s.windowStart) + r.refillWindow) {
                s.windowStart = uint64(block.timestamp);
                s.refilledInWindow = 0;
            }
            uint256 amt = ((target - t.hypeBidUsd) * WAD) / n.px;
            if (s.seeded) {
                uint256 cap = (t.hypeAll * r.refillCapBps) / BPS;
                amt = _min(amt, cap > s.refilledInWindow ? cap - s.refilledInWindow : 0);
            }
            amt = _min(amt, n.hype);
            amt -= amt % SCALE;
            if ((amt * n.px) / WAD >= r.minTradeUsd) {
                _action(
                    SEND_ASSET, abi.encode(HYPE_SYSTEM, address(0), SPOT_DEX, SPOT_DEX, s.cfg.hypeToken, uint64(amt / SCALE))
                );
                if (s.seeded) s.refilledInWindow += amt;
                s.actedBlock = uint64(block.number);
                s.orderAt = uint64(block.timestamp); // the HYPE is in transit: wait before the next step
                emit HypeBidRefill(amt);
                return true;
            }
        }

        // e. supply idle USDC to lending. The 0x811 read fails until an account first uses lending,
        //    so while it fails, supply once with the minimum to open it; after that, only when readable.
        bool canSupply = n.lendingReadable || !s.lendingSeeded;
        if (canSupply && n.borrowed == 0 && n.usdc > s.buyBudget + r.minTradeUsd && s.inflightBlock != block.number) {
            uint256 idle = n.usdc - s.buyBudget;
            if (!n.lendingReadable) {
                idle = r.minTradeUsd;
                s.lendingSeeded = true;
            }
            _action(BORROW_LEND, abi.encode(uint8(0), s.cfg.usdcToken, uint64(idle / SCALE)));
            s.actedBlock = uint64(block.number);
            emit UsdcSupplied(idle);
        }
        return false;
    }

    /// @notice After a migration: one step per block until HyperCore is empty. Pull the dip fund out of
    ///         lending, send USDC to the EVM, then send HYPE to the EVM.
    function unwind(State storage s) public {
        if (s.actedBlock == block.number || !settled(s)) return;
        Snapshot memory n = snapshot(s);
        if (n.borrowed > 0 && n.supplied == 0) {
            // repay by selling a little more HYPE than the debt
            Rules memory r;
            r.slippageBps = 100;
            uint256 sell = (n.borrowed * 102) / 100;
            if (sell < 10e18) sell = 10e18;
            if (_spotTrade(s, r, n.px, sell, false) > 0) return;
        }
        if (n.supplied > 0) {
            _action(BORROW_LEND, abi.encode(uint8(1), s.cfg.usdcToken, uint64(0)));
        } else if (n.usdc >= SCALE) {
            _action(SEND_ASSET, abi.encode(USDC_SYSTEM, address(0), SPOT_DEX, SPOT_DEX, s.cfg.usdcToken, uint64(n.usdc / SCALE)));
        } else if (n.hype >= SCALE) {
            _action(SEND_ASSET, abi.encode(HYPE_SYSTEM, address(0), SPOT_DEX, SPOT_DEX, s.cfg.hypeToken, uint64(n.hype / SCALE)));
        } else {
            return;
        }
        s.actedBlock = uint64(block.number);
    }

    /// @notice Turn the borrow tranche on (switching the account to portfolio margin) or off. Turning
    ///         it off stops new borrowing; an open loan is still repaid by trims and incoming USDC.
    function setBorrowing(State storage s, bool on) public {
        s.borrowEnabled = on;
        if (on) {
            _action(SET_ABSTRACTION, abi.encode(address(this), s.cfg.pmAbstraction));
            s.pmSent = true;
        }
        if (!on) s.borrowBudget = 0;
        emit BorrowingSet(on);
    }

    /// @notice Raw CoreWriter action from the calling contract (test mode only, see DaffyUSD).
    function rawAction(uint24 kind, bytes memory params) public {
        _action(kind, params);
    }

    /// @notice A USD-per-HYPE price in HyperCore's format, 1e8-scaled: at most 5 significant figures
    ///         and (6, or 8 for spot) - szDecimals decimals; integer prices are always valid.
    function formatPx(uint256 pxWad, uint8 szDecimals, bool spot, bool roundUp) public pure returns (uint64) {
        uint256 p8 = roundUp ? (pxWad + SCALE - 1) / SCALE : pxWad / SCALE;
        uint256 decStep = 10 ** (8 - ((spot ? 8 : 6) - szDecimals));
        uint256 digits;
        for (uint256 v = p8; v > 0; v /= 10) digits++;
        uint256 sigStep = digits > 5 ? 10 ** (digits - 5) : 1;
        uint256 step = sigStep > decStep ? sigStep : decStep;
        if (step > 1e8 && p8 >= 1e8) step = 1e8;
        uint256 r = (p8 / step) * step;
        if (roundUp && r < p8) r += step;
        return uint64(r);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Spend `usd` on HYPE (buy) or sell enough HYPE to raise `usd` (sell), IOC on spot.
    ///      Returns the limit price used, 0 when the order would be below one size unit.
    function _spotTrade(State storage s, Rules memory r, uint256 px, uint256 usd, bool buy) private returns (uint64) {
        uint256 limitWad = buy ? (px * (BPS + r.slippageBps)) / BPS : (px * (BPS - r.slippageBps)) / BPS;
        uint64 limit = formatPx(limitWad, s.cfg.spotSzDecimals, true, buy);
        uint256 limitUsd = uint256(limit) * SCALE;
        uint256 hype = buy ? (usd * WAD) / limitUsd : (usd * WAD) / px;
        uint256 unit = 10 ** (18 - s.cfg.spotSzDecimals);
        uint256 sz = (hype / unit) * unit / SCALE;
        if (sz == 0) return 0;
        _action(LIMIT_ORDER, abi.encode(s.cfg.spotAsset, buy, limit, uint64(sz), false, TIF_IOC, uint128(0)));
        s.actedBlock = uint64(block.number);
        s.orderAt = uint64(block.timestamp);
        return limit;
    }

    function _spot(uint64 token) private view returns (uint64 total) {
        (bool ok, bytes memory ret) = SPOT_BALANCE.staticcall{gas: PRECOMPILE_GAS}(abi.encode(address(this), token));
        if (!ok || ret.length < 96) revert PrecompileFailed(SPOT_BALANCE);
        (total,,) = abi.decode(ret, (uint64, uint64, uint64));
    }

    function _action(uint24 kind, bytes memory params) private {
        ICoreWriterV2(CORE_WRITER).sendRawAction(abi.encodePacked(uint8(1), kind, params));
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
