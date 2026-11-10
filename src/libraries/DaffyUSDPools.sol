// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {DaffyMath} from "./DaffyMath.sol";

/// @title DaffyUSDPools - the treasury's one-sided positions in a DAFFY/quote pool
/// @notice Linked library (DELEGATECALL), so the pool sees DaffyUSD as the owner and calls its mint
///         callback. Prices are quote raw units per DAFFY raw unit, in WAD (so for USDC, with 6
///         decimals, $1 per DAFFY is 1e6). Every position sits on one side of the current price:
///         - bid: quote token only, in [low, high] x NAV, never above the pool price
///         - ask: DAFFY only, in [low, high] x NAV, never below the pool price
///         So the treasury never buys DAFFY above its bid range or sells it below its ask range.
library DaffyUSDPools {
    uint256 internal constant WAD = 1e18;

    struct Book {
        int24 bidLo;
        int24 bidHi;
        uint128 bidLiq;
        int24 askLo;
        int24 askHi;
        uint128 askLiq;
        uint256 navAtPlace; // NAV in this pool's units when last placed
        uint64 placedAt;
    }

    struct Ranges {
        uint256 bidLowMult; // 0.6e18
        uint256 bidHighMult; // 0.8e18
        uint256 askLowMult; // 2e18
        uint256 askHighMult; // 10e18
    }

    /// @notice (daff, quote) held by both positions at the pool's current price.
    function amounts(Book storage b, IUniswapV3Pool pool, bool daffIsToken0)
        public
        view
        returns (uint256 daffAmt, uint256 quoteAmt)
    {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        (uint256 d1, uint256 q1) = DaffyMath.amountsForLiquidity(sqrtP, b.bidLo, b.bidHi, b.bidLiq, daffIsToken0);
        (uint256 d2, uint256 q2) = DaffyMath.amountsForLiquidity(sqrtP, b.askLo, b.askHi, b.askLiq, daffIsToken0);
        return (d1 + d2, q1 + q2);
    }

    /// @notice Take both positions out of the pool, principal and fees, to the core.
    function withdrawAll(Book storage b, IUniswapV3Pool pool, bool daffIsToken0)
        public
        returns (uint256 quoteOut, uint256 daffOut)
    {
        if (b.bidLiq > 0) pool.burn(b.bidLo, b.bidHi, b.bidLiq);
        if (b.askLiq > 0) pool.burn(b.askLo, b.askHi, b.askLiq);
        b.bidLiq = 0;
        b.askLiq = 0;
        (uint256 q1, uint256 d1) = _collect(pool, b.bidLo, b.bidHi, daffIsToken0);
        (uint256 q2, uint256 d2) = _collect(pool, b.askLo, b.askHi, daffIsToken0);
        return (q1 + q2, d1 + d2);
    }

    /// @notice Collect swap fees from both positions without moving them.
    function collectFees(Book storage b, IUniswapV3Pool pool, bool daffIsToken0)
        public
        returns (uint256 quoteOut, uint256 daffOut)
    {
        if (b.bidLiq > 0) pool.burn(b.bidLo, b.bidHi, 0);
        if (b.askLiq > 0) pool.burn(b.askLo, b.askHi, 0);
        (uint256 q1, uint256 d1) = b.bidLiq > 0 ? _collect(pool, b.bidLo, b.bidHi, daffIsToken0) : (0, 0);
        (uint256 q2, uint256 d2) = b.askLiq > 0 ? _collect(pool, b.askLo, b.askHi, daffIsToken0) : (0, 0);
        return (q1 + q2, d1 + d2);
    }

    /// @notice Place a bid of `quoteAmt` and an ask of `daffAmt` around `nav`. The core's mint callback
    ///         pays the quote token and mints the DAFFY.
    function place(
        Book storage b,
        IUniswapV3Pool pool,
        bool daffIsToken0,
        int24 spacing,
        uint256 nav,
        Ranges memory r,
        uint256 quoteAmt,
        uint256 daffAmt
    ) public {
        (uint160 sqrtP, int24 tick,,,,,) = pool.slot0();
        uint256 spot = DaffyMath.priceFromSqrt(sqrtP, daffIsToken0);
        {
            // The pool price can sit anywhere when there is no liquidity around it: moving it through
            // empty space costs nothing, for anyone. If it is outside [bid top, ask bottom], try to
            // bring it back the same way. The core's swap callback refuses to pay anything, so this
            // only ever succeeds when it is free, and changes nobody's balances.
            uint256 want = spot < (nav * r.bidHighMult) / WAD
                ? (nav * r.bidHighMult) / WAD
                : spot > (nav * r.askLowMult) / WAD ? (nav * r.askLowMult) / WAD : 0;
            if (want > 0) {
                uint160 target = DaffyMath.sqrtFromPrice(want, daffIsToken0);
                if (target != sqrtP) {
                    try pool.swap(address(this), target < sqrtP, 1, target, "") {
                        (sqrtP, tick,,,,,) = pool.slot0();
                        spot = DaffyMath.priceFromSqrt(sqrtP, daffIsToken0);
                    } catch {}
                }
            }
            // whatever the price is, keep the maths in range
            uint256 floor_ = nav / 1000 == 0 ? 1 : nav / 1000;
            if (spot < floor_) spot = floor_;
            if (spot > nav * 1000) spot = nav * 1000;
        }
        int24 below = DaffyMath.floorTick(tick, spacing); // ranges ending here hold token1 only
        int24 above = below + spacing; // ranges starting here hold token0 only
        b.navAtPlace = nav;
        b.placedAt = uint64(block.timestamp);

        // bid: quote token. Quote is token1 when DAFFY is token0 (sits below the tick), else token0.
        uint256 top = (nav * r.bidHighMult) / WAD;
        if (spot < top) top = spot;
        (int24 lo, int24 hi) = _sorted(
            DaffyMath.tickForPrice((top * r.bidLowMult) / r.bidHighMult, daffIsToken0, spacing, true),
            DaffyMath.tickForPrice(top, daffIsToken0, spacing, true)
        );
        if (daffIsToken0) hi = hi < below ? hi : below;
        else lo = lo > above ? lo : above;
        uint128 liq;
        if (lo < hi && quoteAmt > 0) {
            (uint160 sA, uint160 sB) = (TickMath.getSqrtRatioAtTick(lo), TickMath.getSqrtRatioAtTick(hi));
            liq = daffIsToken0
                ? LiquidityAmounts.getLiquidityForAmount1(sA, sB, quoteAmt)
                : LiquidityAmounts.getLiquidityForAmount0(sA, sB, quoteAmt);
            if (liq > 0) pool.mint(address(this), lo, hi, liq, "");
        }
        (b.bidLo, b.bidHi, b.bidLiq) = (lo, hi, liq);

        // ask: DAFFY. DAFFY is token0 above the tick when it is token0, else token1 below it.
        uint256 bottom = (nav * r.askLowMult) / WAD;
        if (spot > bottom) bottom = spot;
        (lo, hi) = _sorted(
            DaffyMath.tickForPrice(bottom, daffIsToken0, spacing, false),
            DaffyMath.tickForPrice((bottom * r.askHighMult) / r.askLowMult, daffIsToken0, spacing, false)
        );
        if (daffIsToken0) lo = lo > above ? lo : above;
        else hi = hi < below ? hi : below;
        liq = 0;
        if (lo < hi && daffAmt > 0) {
            (uint160 sA, uint160 sB) = (TickMath.getSqrtRatioAtTick(lo), TickMath.getSqrtRatioAtTick(hi));
            liq = daffIsToken0
                ? LiquidityAmounts.getLiquidityForAmount0(sA, sB, daffAmt)
                : LiquidityAmounts.getLiquidityForAmount1(sA, sB, daffAmt);
            if (liq > 0) pool.mint(address(this), lo, hi, liq, "");
        }
        (b.askLo, b.askHi, b.askLiq) = (lo, hi, liq);
    }

    /// @notice Top of the bid range, as a price (for checks and tests).
    function bidTop(Book storage b, bool daffIsToken0) public view returns (uint256) {
        if (b.bidLiq == 0) return 0;
        return DaffyMath.priceAtTick(daffIsToken0 ? b.bidHi : b.bidLo, daffIsToken0);
    }

    function _collect(IUniswapV3Pool pool, int24 lo, int24 hi, bool daffIsToken0)
        private
        returns (uint256 quoteOut, uint256 daffOut)
    {
        if (lo >= hi) return (0, 0);
        (uint128 c0, uint128 c1) = pool.collect(address(this), lo, hi, type(uint128).max, type(uint128).max);
        (daffOut, quoteOut) = daffIsToken0 ? (uint256(c0), uint256(c1)) : (uint256(c1), uint256(c0));
    }

    function _sorted(int24 a, int24 b) private pure returns (int24, int24) {
        return a < b ? (a, b) : (b, a);
    }
}
