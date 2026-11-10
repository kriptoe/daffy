// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {DaffyToken} from "./DaffyToken.sol";
import {IWHYPE, IV3Factory} from "./interfaces/IExternal.sol";
import {DaffyMath} from "./libraries/DaffyMath.sol";
import {DaffyUSDPools} from "./libraries/DaffyUSDPools.sol";
import {DaffyUSDHyperCore} from "./libraries/DaffyUSDHyperCore.sol";

/// @notice A contract that can receive a DaffyUSD migration.
interface IDaffyUSDSuccessor {
    function acceptMigration() external;
}

/// @title DaffyUSD - Daffy v2, the USDC model
/// @notice USDC deposits mint DAFF 1:1 ($1 NAV). At launch the treasury is split:
///         - 70% HYPE: 55% held on HyperCore, 15% as a bid in the DAFF/HYPE pool
///         - 20% dip fund: USDC supplied to HyperCore lending, spent on big HYPE drops
///         - 10% USDC bid in the DAFF/USDC pool
///         Holders exit by selling DAFF into either pool; the treasury's bids sit at 0.6-0.8x NAV
///         and the DAFF they buy is burned. Its only asks sit at 2x NAV and up. Nothing defends NAV,
///         there is no redeem function, and HYPE is sold only in trims after a rally.
/// @dev Unofficial parody, not affiliated with Hyperliquid.
contract DaffyUSD is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using DaffyUSDPools for DaffyUSDPools.Book;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_LAUNCH = 10e6; // 10 USDC: the floor even in test mode
    uint256 public constant MAX_REWARD = 5e6; // keeper reward bounds the migrator can set
    uint32 public constant MIN_REWARD_INTERVAL = 10 minutes;
    uint256 public constant MIGRATION_DELAY = 14 days;

    struct Params {
        uint256 launchDuration; // 7 days
        uint256 minLaunchUsdc; // 100_000e6: below this when the window ends, it never launches
        uint256 earlyLaunchUsdc; // 10_000_000e6: at this, anyone can launch before the window ends
        uint16 hypeBps; // 7000: share bought as HYPE at launch (includes the HYPE bid)
        uint16 usdcBidBps; // 1000: USDC bid at launch; the rest (20%) is the dip fund
        uint16 askBps; // 1000: DAFF offered in each pool's ask, share of circulating DAFF
        uint16 recenterMoveBps; // 1000: re-place a pool's positions when NAV moved 10%...
        uint32 recenterInterval; // ...or after 7 days
        uint16 incomingHypeBps; // 7000: share of incoming USDC that buys HYPE
        uint32 feeCollectInterval; // 1 day
        uint32 rewardInterval; // 10 minutes between keeper rewards
        uint256 pokeReward; // USDC (6 decimals) paid for upkeep that did real work
        DaffyUSDPools.Ranges ranges;
        DaffyUSDHyperCore.Rules rules;
        bool testMode;
    }

    DaffyToken public immutable token;
    IERC20 public immutable usdc;
    IWHYPE public immutable whype;
    address public immutable depositWallet;
    IUniswapV3Pool public immutable poolUsdc;
    IUniswapV3Pool public immutable poolHype;
    bool public immutable daffIsToken0U;
    bool public immutable daffIsToken0H;
    int24 internal immutable spacingU;
    int24 internal immutable spacingH;

    Params internal params;
    DaffyUSDHyperCore.State public hc;
    DaffyUSDPools.Book public bookU;
    DaffyUSDPools.Book public bookH;

    uint256 public launchEnd;
    uint256 public totalDeposited; // USDC deposited and not withdrawn, before launch (6 decimals)
    uint256 public rewardReserve; // USDC set aside for keeper rewards (6 decimals)
    bool public launched;
    uint64 public lastFeeCollect;
    uint64 public lastReward;

    address public migrator;
    address public successor;
    uint256 public migrationReadyAt;
    bool public migrated;

    bool public testMode;
    bool public manual;
    bool internal placing; // true only while positions are being placed

    event Deposited(address indexed user, uint256 usdc);
    event DepositWithdrawn(address indexed user, uint256 usdc);
    event Launched(uint256 usdc, uint256 hypePx);
    event Recentered(bool usdcPool, uint256 nav, uint256 bid, uint256 ask);
    event Burned(uint256 daff);
    event Rewarded(address indexed keeper, uint256 usdc);
    event MigrationProposed(address indexed successor, uint256 readyAt);
    event MigrationCancelled();
    event Migrated(address indexed successor);
    event MigratorRenounced();
    event ManualSet(bool manual);
    event TestModeEnded();
    event RewardsSet(uint256 amount, uint32 interval);

    error NotMigrator();
    error NotTestMode();
    error AlreadyLaunched();
    error NotLaunched();
    error DepositWindowClosed();
    error DepositWindowOpen();
    error NothingDeposited();
    error CoreAccountNotActivated();
    error IsMigrated();
    error NotMigrated();
    error MigrationNotReady();
    error BadCallback();
    error ZeroAmount();
    error MinimumNotReached();
    error BadReward();

    modifier onlyMigrator() {
        if (msg.sender != migrator) revert NotMigrator();
        _;
    }

    modifier onlyTester() {
        if (msg.sender != migrator) revert NotMigrator();
        if (!testMode) revert NotTestMode();
        _;
    }

    constructor(
        Params memory p,
        address usdc_,
        address whype_,
        address depositWallet_,
        DaffyUSDHyperCore.Config memory cfg,
        address factory,
        uint24 fee,
        address migrator_
    ) {
        params = p;
        testMode = p.testMode;
        usdc = IERC20(usdc_);
        whype = IWHYPE(whype_);
        depositWallet = depositWallet_;
        migrator = migrator_;
        hc.cfg = cfg;
        hc.borrowEnabled = cfg.borrowAtLaunch; // the switch to portfolio margin is sent after launch
        launchEnd = block.timestamp + p.launchDuration;
        token = new DaffyToken(address(this));

        // DAFF/USDC starts at $1. DAFF/HYPE gets its starting price ($1 of HYPE) at launch: the
        // HYPE oracle is a HyperCore precompile, which local simulations (forge script) don't have.
        (poolUsdc, daffIsToken0U, spacingU) = _pool(factory, usdc_, fee, WAD / 1e12);
        (poolHype, daffIsToken0H, spacingH) = _pool(factory, whype_, fee, 0);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ deposits and launch

    /// @notice Deposit USDC (6 decimals) before launch for DAFF 1:1.
    function deposit(uint256 amount) external nonReentrant {
        if (launched || block.timestamp >= launchEnd) revert DepositWindowClosed();
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        token.mint(msg.sender, amount * 1e12);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Before launch, hand back DAFF (approve this contract first) for the USDC 1:1. Stays open
    ///         for good if the window ends under the minimum and Daffy never launches.
    function withdrawDeposit(uint256 daffAmount) external nonReentrant {
        if (launched) revert AlreadyLaunched();
        uint256 amount = daffAmount / 1e12;
        if (amount == 0) revert ZeroAmount();
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount * 1e12);
        token.burn(amount * 1e12);
        totalDeposited -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit DepositWithdrawn(msg.sender, amount);
    }

    /// @notice Anyone, once deposits reach earlyLaunchUsdc, or after the window if they reached
    ///         minLaunchUsdc (in test mode the migrator may launch any time). Bridges 90% of the USDC
    ///         to HyperCore (70% earmarked for HYPE, 20% for the dip fund), seeds the USDC bid with
    ///         the rest, places asks in both pools and opens transfers.
    function finalizeLaunch() external nonReentrant {
        if (launched) revert AlreadyLaunched();
        if (!(testMode && msg.sender == migrator) && totalDeposited < params.earlyLaunchUsdc) {
            if (block.timestamp < launchEnd) revert DepositWindowOpen();
            if (totalDeposited < params.minLaunchUsdc) revert MinimumNotReached();
        }
        if (!DaffyUSDHyperCore.coreUserExists(address(this))) revert CoreAccountNotActivated();
        uint256 total = usdc.balanceOf(address(this));
        if (total < MIN_LAUNCH) revert NothingDeposited();
        launched = true;
        token.enableTransfers();
        lastFeeCollect = uint64(block.timestamp);

        uint256 bid = (total * params.usdcBidBps) / BPS;
        uint256 toCore = total - bid;
        // earmark hypeBps of the total out of what goes to HyperCore
        DaffyUSDHyperCore.bridgeUsdc(hc, usdc, depositWallet, toCore, (uint256(params.hypeBps) * BPS) / (BPS - params.usdcBidBps));
        hc.highPx = DaffyUSDHyperCore.oraclePrice(hc);
        hc.launchPx = hc.highPx;
        (uint160 sqrtH,,,,,,) = poolHype.slot0();
        if (sqrtH == 0) poolHype.initialize(DaffyMath.sqrtFromPrice((WAD * WAD) / hc.highPx, daffIsToken0H));

        uint256 nav = navUsd();
        _place(true, nav, bid);
        _place(false, nav, 0);
        emit Launched(total, hc.highPx);
    }

    // ------------------------------------------------------------------ upkeep

    /// @notice Anyone: collect fees, re-place pool positions when due, run the HyperCore step, route
    ///         new USDC. Pays a small USDC reward when it did real work.
    function poke() external nonReentrant {
        if (!launched) revert NotLaunched();
        if (migrated) revert IsMigrated();
        _wrapNative();
        if (block.timestamp >= uint256(lastFeeCollect) + params.feeCollectInterval) {
            lastFeeCollect = uint64(block.timestamp);
            (, uint256 d1) = bookU.collectFees(poolUsdc, daffIsToken0U);
            (, uint256 d2) = bookH.collectFees(poolHype, daffIsToken0H);
            _burn(d1 + d2);
        }
        if (manual) return;

        (DaffyUSDHyperCore.Totals memory t, DaffyUSDHyperCore.Snapshot memory n, uint256 nav) = _totals();
        bool work = _maybeRecenter(true, t, n.px, nav);
        work = _maybeRecenter(false, t, n.px, nav) || work;
        work = DaffyUSDHyperCore.tick(hc, params.rules, t, n) || work;
        _routeUsdc();
        if (work) _reward(msg.sender);
    }

    // ------------------------------------------------------------------ views

    /// @notice NAV in USD per DAFF (WAD). DAFF held by the treasury or sitting in its pool
    ///         positions isn't circulating.
    function navUsd() public view returns (uint256 nav) {
        (,, nav) = _totals();
    }

    /// @notice Treasury totals (WAD): everything in USD, all HYPE in USD and in HYPE, the HYPE bid.
    function totals() external view returns (DaffyUSDHyperCore.Totals memory t) {
        (t,,) = _totals();
    }

    /// @notice The HyperCore strategy's state (tranches, budgets, borrowing, refills).
    function coreState() external view returns (DaffyUSDHyperCore.State memory) {
        return hc;
    }

    /// @notice Today's dip-buy levels (USD per HYPE, WAD): tranches 1-3 below the current high.
    function dipLevels() external view returns (uint256 first, uint256 second, uint256 third) {
        DaffyUSDHyperCore.Rules memory r = params.rules;
        uint256 extra = DaffyUSDHyperCore.dipExtraBps(hc, r);
        uint256 h = hc.highPx;
        first = (h * (BPS - r.dip1Bps - extra)) / BPS;
        second = (h * (BPS - r.dip2Bps - extra)) / BPS;
        third = (h * (BPS - r.dip3Bps - extra)) / BPS;
    }

    function coreSnapshot() external view returns (DaffyUSDHyperCore.Snapshot memory) {
        return DaffyUSDHyperCore.snapshot(hc);
    }

    function circulating() public view returns (uint256) {
        (uint256 dU,) = bookU.amounts(poolUsdc, daffIsToken0U);
        (uint256 dH,) = bookH.amounts(poolHype, daffIsToken0H);
        uint256 held = token.balanceOf(address(this)) + dU + dH;
        uint256 supply = token.totalSupply();
        return supply > held ? supply - held : 0;
    }

    /// @notice A pool's three positions and when they were last placed.
    function book(bool usdcPool) external view returns (DaffyUSDPools.Book memory) {
        return usdcPool ? bookU : bookH;
    }

    /// @notice Top of each bid range (pool units: USDC raw per DAFF raw, HYPE per DAFF; WAD).
    function bidTops() external view returns (uint256 usdcPool, uint256 hypePool) {
        return (bookU.bidTop(daffIsToken0U), bookH.bidTop(daffIsToken0H));
    }

    /// @notice Everything a deposit page needs in one call.
    function launchStatus()
        external
        view
        returns (
            uint256 deposited,
            uint256 minimum,
            uint256 earlyAt,
            uint256 endsAt,
            bool isLaunched,
            bool canLaunch,
            bool failed
        )
    {
        deposited = totalDeposited;
        minimum = params.minLaunchUsdc;
        earlyAt = params.earlyLaunchUsdc;
        endsAt = launchEnd;
        isLaunched = launched;
        bool ended = block.timestamp >= launchEnd;
        canLaunch = !launched && (deposited >= earlyAt || (ended && deposited >= minimum));
        failed = !launched && ended && deposited < minimum;
    }

    function getParams() external view returns (Params memory) {
        return params;
    }

    // ------------------------------------------------------------------ migration

    function proposeMigration(address next) external onlyMigrator {
        if (migrated) revert IsMigrated();
        successor = next;
        migrationReadyAt = block.timestamp + MIGRATION_DELAY;
        emit MigrationProposed(next, migrationReadyAt);
    }

    function cancelMigration() external onlyMigrator {
        successor = address(0);
        migrationReadyAt = 0;
        emit MigrationCancelled();
    }

    /// @notice After the timelock: take both pools' positions out, burn the DAFF, hand the token to
    ///         the successor and forward everything. HyperCore is emptied by forwardToSuccessor().
    function executeMigration() external onlyMigrator nonReentrant {
        if (successor == address(0) || migrationReadyAt == 0 || block.timestamp < migrationReadyAt) {
            revert MigrationNotReady();
        }
        if (migrated) revert IsMigrated();
        migrated = true;
        _pullPools();
        token.setCore(successor);
        IDaffyUSDSuccessor(successor).acceptMigration();
        _forward();
        emit Migrated(successor);
    }

    /// @notice Anyone, after a migration: one HyperCore unwind step, then forward what's on the EVM.
    function forwardToSuccessor() external nonReentrant {
        if (!migrated) revert NotMigrated();
        DaffyUSDHyperCore.unwind(hc);
        _forward();
    }

    /// @notice Keeper reward per useful upkeep (USDC, 6 decimals, at most 5) and the gap between
    ///         rewards (at least 10 minutes). Fixed for good once the migrator is renounced.
    function setRewards(uint256 amount, uint32 interval) external onlyMigrator {
        if (amount > MAX_REWARD || interval < MIN_REWARD_INTERVAL) revert BadReward();
        params.pokeReward = amount;
        params.rewardInterval = interval;
        emit RewardsSet(amount, interval);
    }

    /// @notice Turn the optional borrow tranche on (switches the HyperCore account to portfolio
    ///         margin) or off. Off by default.
    function setBorrowing(bool on) external onlyMigrator {
        DaffyUSDHyperCore.setBorrowing(hc, on);
    }

    function renounceMigrator() external onlyMigrator {
        migrator = address(0);
        testMode = false;
        manual = false;
        emit MigratorRenounced();
    }

    // ------------------------------------------------------------------ test mode (testing only)

    /// @notice Send EVM-side USDC (6 decimals) and HYPE (WHYPE + native, unwrapped) to `to`.
    ///         type(uint256).max = all.
    function testWithdraw(address to, uint256 usdcAmount, uint256 hypeAmount) external onlyTester nonReentrant {
        uint256 u = usdc.balanceOf(address(this));
        if (usdcAmount == type(uint256).max) usdcAmount = u;
        if (usdcAmount > 0) usdc.safeTransfer(to, usdcAmount);
        uint256 left = u - usdcAmount;
        if (rewardReserve > left) rewardReserve = left;
        if (!launched) totalDeposited = totalDeposited > usdcAmount ? totalDeposited - usdcAmount : 0;
        uint256 w = whype.balanceOf(address(this));
        if (hypeAmount == type(uint256).max) hypeAmount = w + address(this).balance;
        if (hypeAmount > address(this).balance) whype.withdraw(hypeAmount - address(this).balance);
        if (hypeAmount > 0) {
            (bool ok,) = to.call{value: hypeAmount}("");
            require(ok, "send failed");
        }
    }

    /// @notice Any CoreWriter action: `kind` = action id, `actionParams` = its abi-encoded arguments.
    function testCoreAction(uint24 kind, bytes calldata actionParams) external onlyTester {
        DaffyUSDHyperCore.rawAction(kind, actionParams);
    }

    /// @notice Take both pools' positions out to this contract (DAFF burned).
    function testPullPools() external onlyTester nonReentrant {
        _pullPools();
    }

    /// @notice Pause (true) or resume the automatic pool and HyperCore logic.
    function setManual(bool on) external onlyTester {
        manual = on;
        emit ManualSet(on);
    }

    function endTestMode() external onlyTester {
        testMode = false;
        manual = false;
        emit TestModeEnded();
    }

    // ------------------------------------------------------------------ pool callback

    /// @notice HyperSwap V3 pools call this name (selector 0xf24aceb7) when liquidity is added.
    function hyperswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        _mintCallback(owed0, owed1);
    }

    /// @notice Uniswap V3 pools (and the test suite's factory) call this one.
    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        _mintCallback(owed0, owed1);
    }

    /// @notice Swap callbacks, used only by the free price reset in DaffyUSDPools.place. The
    ///         treasury never pays in a swap: any amount owed reverts, and the reset is abandoned.
    function hyperswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external view {
        if (!placing || a0 > 0 || a1 > 0) revert BadCallback();
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external view {
        if (!placing || a0 > 0 || a1 > 0) revert BadCallback();
    }

    function _mintCallback(uint256 owed0, uint256 owed1) internal {
        if (!placing || (msg.sender != address(poolUsdc) && msg.sender != address(poolHype))) revert BadCallback();
        IUniswapV3Pool p = IUniswapV3Pool(msg.sender);
        if (owed0 > 0) _pay(p.token0(), owed0);
        if (owed1 > 0) _pay(p.token1(), owed1);
    }

    // ------------------------------------------------------------------ internals

    function _pay(address tokenAddr, uint256 amount) internal {
        if (tokenAddr == address(token)) token.mint(msg.sender, amount);
        else IERC20(tokenAddr).safeTransfer(msg.sender, amount);
    }

    function _totals()
        internal
        view
        returns (DaffyUSDHyperCore.Totals memory t, DaffyUSDHyperCore.Snapshot memory n, uint256 nav)
    {
        n = DaffyUSDHyperCore.snapshot(hc);
        (uint256 dU, uint256 qU) = bookU.amounts(poolUsdc, daffIsToken0U);
        (uint256 dH, uint256 qH) = bookH.amounts(poolHype, daffIsToken0H);
        uint256 evmHype = whype.balanceOf(address(this)) + address(this).balance;
        uint256 usd = (usdc.balanceOf(address(this)) + qU) * 1e12 + n.usdc + n.supplied
            + DaffyUSDHyperCore.inflight(hc);
        t.hypeAll = n.hype + evmHype + qH;
        t.hypeAllUsd = (t.hypeAll * n.px) / WAD;
        t.hypeBidUsd = ((evmHype + qH) * n.px) / WAD;
        t.total = usd + t.hypeAllUsd;
        t.total = t.total > n.borrowed ? t.total - n.borrowed : 0;
        uint256 held = token.balanceOf(address(this)) + dU + dH;
        uint256 supply = token.totalSupply();
        uint256 circ = supply > held ? supply - held : 0;
        nav = circ == 0 ? WAD : (t.total * WAD) / circ;
    }

    /// @dev Re-place a pool's positions when NAV (in that pool's units) moved enough, the interval
    ///      passed, or quote is waiting to go into the bid.
    function _maybeRecenter(bool isUsdc, DaffyUSDHyperCore.Totals memory t, uint256 px, uint256 nav)
        internal
        returns (bool)
    {
        DaffyUSDPools.Book storage b = isUsdc ? bookU : bookH;
        uint256 navQ = isUsdc ? nav / 1e12 : (nav * WAD) / px;
        uint256 last = b.navAtPlace;
        bool due = block.timestamp >= uint256(b.placedAt) + params.recenterInterval
            || (navQ > last ? navQ - last : last - navQ) * BPS >= last * params.recenterMoveBps;
        uint256 idleUsd = isUsdc ? _spendableUsdc() * 1e12 : (whype.balanceOf(address(this)) * px) / WAD;
        if (!due && idleUsd * 100 < t.total) return false; // idle quote under 1% of the treasury waits
        (uint256 quoteOut, uint256 daffOut) =
            isUsdc ? bookU.withdrawAll(poolUsdc, daffIsToken0U) : bookH.withdrawAll(poolHype, daffIsToken0H);
        quoteOut; // now on this contract's balance
        _burn(daffOut);
        uint256 quoteAmt;
        if (isUsdc) {
            uint256 target = (t.total * params.usdcBidBps) / BPS / 1e12;
            quoteAmt = _spendableUsdc();
            if (quoteAmt > target) quoteAmt = target;
        } else {
            quoteAmt = whype.balanceOf(address(this));
        }
        _place(isUsdc, nav, quoteAmt);
        return true;
    }

    function _place(bool isUsdc, uint256 nav, uint256 quoteAmt) internal {
        uint256 ask = (circulating() * params.askBps) / BPS;
        uint256 navQ = isUsdc ? nav / 1e12 : (nav * WAD) / DaffyUSDHyperCore.oraclePrice(hc);
        DaffyUSDPools.Book storage b = isUsdc ? bookU : bookH;
        if (navQ == 0) {
            // nothing to price the positions from (an empty treasury): leave the book empty, and
            // place it again on the first poke once the treasury holds value
            (b.bidLiq, b.askLiq, b.navAtPlace, b.placedAt) = (0, 0, 0, uint64(block.timestamp));
            emit Recentered(isUsdc, nav, 0, 0);
            return;
        }
        placing = true;
        if (isUsdc) {
            bookU.place(poolUsdc, daffIsToken0U, spacingU, navQ, params.ranges, quoteAmt, ask);
        } else {
            bookH.place(poolHype, daffIsToken0H, spacingH, navQ, params.ranges, quoteAmt, ask);
        }
        placing = false;
        emit Recentered(isUsdc, nav, quoteAmt, ask);
    }

    /// @dev Spare USDC on the EVM (fees, premium sales, or USDC freed when the bid's target shrinks)
    ///      first fills the keeper reward reserve (20 rewards), then the USDC
    ///      bid's needs; the rest goes to HyperCore: incomingHypeBps to HYPE buys, the rest to the
    ///      dip fund.
    function _routeUsdc() internal {
        uint256 cap = params.pokeReward * 20;
        if (rewardReserve < cap) {
            uint256 room = cap - rewardReserve;
            uint256 free = _spendableUsdc();
            rewardReserve += free < room ? free : room;
        }
        uint256 spare = _spendableUsdc();
        if (spare * 1e12 < params.rules.minTradeUsd) return;
        (uint256 total,,) = _totalsLite();
        uint256 target = (total * params.usdcBidBps) / BPS / 1e12;
        (, uint256 qU) = bookU.amounts(poolUsdc, daffIsToken0U);
        uint256 bidNeed = target > qU ? target - qU : 0;
        if (spare <= bidNeed) return; // kept for the bid's next placement
        DaffyUSDHyperCore.bridgeUsdc(hc, usdc, depositWallet, spare - bidNeed, params.incomingHypeBps);
    }

    function _totalsLite() internal view returns (uint256 total, uint256 px, uint256 nav) {
        (DaffyUSDHyperCore.Totals memory t, DaffyUSDHyperCore.Snapshot memory n, uint256 v) = _totals();
        return (t.total, n.px, v);
    }

    /// @dev EVM USDC minus the keeper reward reserve.
    function _spendableUsdc() internal view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        return bal > rewardReserve ? bal - rewardReserve : 0;
    }

    /// @dev Rewards come only out of the reserve, which only incoming USDC fills.
    function _reward(address to) internal {
        if (block.timestamp < uint256(lastReward) + params.rewardInterval) return;
        uint256 r = params.pokeReward;
        if (r == 0 || rewardReserve < r || usdc.balanceOf(address(this)) < r) return;
        lastReward = uint64(block.timestamp);
        rewardReserve -= r;
        usdc.safeTransfer(to, r);
        emit Rewarded(to, r);
    }

    function _pullPools() internal {
        (, uint256 d1) = bookU.withdrawAll(poolUsdc, daffIsToken0U);
        (, uint256 d2) = bookH.withdrawAll(poolHype, daffIsToken0H);
        bookU.placedAt = 0;
        bookH.placedAt = 0;
        _burn(d1 + d2);
    }

    function _burn(uint256 extra) internal {
        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) {
            token.burn(bal);
            emit Burned(bal);
        }
        extra;
    }

    function _forward() internal {
        rewardReserve = 0;
        _wrapNative();
        uint256 u = usdc.balanceOf(address(this));
        if (u > 0) usdc.safeTransfer(successor, u);
        uint256 w = whype.balanceOf(address(this));
        if (w > 0) IERC20(address(whype)).safeTransfer(successor, w);
    }

    function _wrapNative() internal {
        uint256 bal = address(this).balance;
        if (bal > 0) whype.deposit{value: bal}();
    }

    function _pool(address factory, address quote, uint24 fee, uint256 priceDaffInQuote)
        internal
        returns (IUniswapV3Pool p, bool daffIs0, int24 spacing)
    {
        address addr = IV3Factory(factory).getPool(address(token), quote, fee);
        if (addr == address(0)) addr = IV3Factory(factory).createPool(address(token), quote, fee);
        p = IUniswapV3Pool(addr);
        daffIs0 = p.token0() == address(token);
        spacing = p.tickSpacing();
        (uint160 sqrtP,,,,,,) = p.slot0();
        if (sqrtP == 0 && priceDaffInQuote > 0) p.initialize(DaffyMath.sqrtFromPrice(priceDaffInQuote, daffIs0));
    }
}
