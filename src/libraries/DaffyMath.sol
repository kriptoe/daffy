// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

/// @title DaffyMath - price, tick and liquidity helpers for DaffyCore
/// @notice Deployed once as a linked library (public functions) to keep DaffyCore under the
///         24 KB contract size limit. All prices are HYPE per DAFF in WAD.
library DaffyMath {
    uint256 internal constant WAD = 1e18;

    /// @notice HYPE per DAFF (WAD) from a pool sqrt price.
    function priceFromSqrt(uint160 sqrtP, bool daffIsToken0) public pure returns (uint256) {
        uint256 priceX128 = Math.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 64); // token1 per token0, Q128
        return daffIsToken0 ? Math.mulDiv(priceX128, WAD, 1 << 128) : Math.mulDiv(WAD, 1 << 128, priceX128);
    }

    /// @notice Pool sqrt price for a HYPE-per-DAFF price (WAD), clamped to the valid range.
    function sqrtFromPrice(uint256 price, bool daffIsToken0) public pure returns (uint160) {
        uint256 ratioX192 = daffIsToken0 ? Math.mulDiv(price, 1 << 192, WAD) : Math.mulDiv(WAD, 1 << 192, price);
        uint256 s = Math.sqrt(ratioX192);
        if (s <= TickMath.MIN_SQRT_RATIO) return TickMath.MIN_SQRT_RATIO + 1;
        if (s >= TickMath.MAX_SQRT_RATIO) return TickMath.MAX_SQRT_RATIO - 1;
        return uint160(s);
    }

    /// @notice HYPE per DAFF (WAD) at a tick.
    function priceAtTick(int24 tick, bool daffIsToken0) public pure returns (uint256) {
        return priceFromSqrt(TickMath.getSqrtRatioAtTick(tick), daffIsToken0);
    }

    function sqrtAtTick(int24 tick) public pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    /// @notice Ticks covering [low, high] HYPE-per-DAFF prices, rounded outward to the spacing.
    function ticksForPrices(uint256 low, uint256 high, bool daffIsToken0, int24 spacing)
        public
        pure
        returns (int24 lo, int24 hi)
    {
        int24 tA = TickMath.getTickAtSqrtRatio(sqrtFromPrice(low, daffIsToken0));
        int24 tB = TickMath.getTickAtSqrtRatio(sqrtFromPrice(high, daffIsToken0));
        (int24 a, int24 b) = tA < tB ? (tA, tB) : (tB, tA);
        lo = floorTick(a, spacing);
        hi = floorTick(b, spacing) + spacing;
        if (lo < TickMath.MIN_TICK) lo = ceilTick(TickMath.MIN_TICK, spacing);
        if (hi > TickMath.MAX_TICK) hi = floorTick(TickMath.MAX_TICK, spacing);
    }

    function floorTick(int24 t, int24 s) public pure returns (int24) {
        int24 q = t / s;
        if (t < 0 && t % s != 0) q--;
        return q * s;
    }

    function ceilTick(int24 t, int24 s) public pure returns (int24) {
        int24 f = floorTick(t, s);
        return f == t ? f : f + s;
    }

    /// @notice (daff, hype) amounts held by `liquidity` in [lo, hi] at `sqrtP`.
    function amountsForLiquidity(uint160 sqrtP, int24 lo, int24 hi, uint128 liquidity, bool daffIsToken0)
        public
        pure
        returns (uint256 daffAmt, uint256 hypeAmt)
    {
        if (liquidity == 0) return (0, 0);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(lo), TickMath.getSqrtRatioAtTick(hi), liquidity
        );
        return daffIsToken0 ? (a0, a1) : (a1, a0);
    }

    /// @notice Liquidity that `hypeAmount` of WHYPE supports in [lo, hi] at `sqrtP` (price inside the range).
    function liquidityForHype(uint160 sqrtP, int24 lo, int24 hi, uint256 hypeAmount, bool daffIsToken0)
        public
        pure
        returns (uint128)
    {
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(lo);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(hi);
        if (sqrtP <= sqrtA || sqrtP >= sqrtB) return 0;
        // HYPE sits below the price when it is token1, above the price when it is token0.
        return daffIsToken0
            ? LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtP, hypeAmount)
            : LiquidityAmounts.getLiquidityForAmount0(sqrtP, sqrtB, hypeAmount);
    }

    /// @notice Average tick over `window` from two cumulative tick readings, rounded down.
    function averageTick(int56 cumOld, int56 cumNew, uint32 window) public pure returns (int24 avg) {
        int56 delta = cumNew - cumOld;
        int56 w = int56(uint56(window));
        avg = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) avg--;
    }

    /// @notice A tick on the spacing grid whose price is at most (atMost) or at least `price`.
    function tickForPrice(uint256 price, bool daffIsToken0, int24 spacing, bool atMost)
        public
        pure
        returns (int24 t)
    {
        uint160 target = sqrtFromPrice(price, daffIsToken0);
        int24 raw = TickMath.getTickAtSqrtRatio(target);
        int24 f = floorTick(raw, spacing);
        bool exact = f == raw && TickMath.getSqrtRatioAtTick(raw) == target;
        // HYPE-per-DAFF price rises with the tick when DAFF is token0, falls when it is token1.
        bool wantLowerSqrt = atMost == daffIsToken0;
        t = wantLowerSqrt || exact ? f : f + spacing;
        if (t < TickMath.MIN_TICK) t = ceilTick(TickMath.MIN_TICK, spacing);
        if (t > TickMath.MAX_TICK) t = floorTick(TickMath.MAX_TICK, spacing);
    }

    struct Plan {
        int24 bidLo;
        int24 bidHi;
        int24 askLo;
        int24 askHi;
        uint128 bidLiq;
        uint128 askLiq;
    }

    /// @notice Plan the two protocol positions. Bids (HYPE only) sit in
    ///         [rangeLow x top, top] with top = min(spot, navLow); asks (DAFF only) sit in
    ///         [bottom, rangeHigh x bottom] with bottom = max(spot, navHigh). So the pool never buys
    ///         DAFF above NAV or sells it below NAV, wherever the price is. Both positions get the
    ///         liquidity that `hypeAmount` supports across the full bid range.
    function planPositions(
        uint160 spotSqrt,
        int24 currentTick,
        uint256 navLow,
        uint256 navHigh,
        uint256 rangeLowMult,
        uint256 rangeHighMult,
        uint256 hypeAmount,
        bool daffIsToken0,
        int24 spacing
    ) public pure returns (Plan memory p) {
        uint256 spot = priceFromSqrt(spotSqrt, daffIsToken0);
        uint256 top = spot < navLow ? spot : navLow;
        uint256 bottom = spot > navHigh ? spot : navHigh;

        (int24 bA, int24 bB) = _sorted(
            tickForPrice((top * rangeLowMult) / WAD, daffIsToken0, spacing, true),
            tickForPrice(top, daffIsToken0, spacing, true)
        );
        (int24 aA, int24 aB) = _sorted(
            tickForPrice(bottom, daffIsToken0, spacing, false),
            tickForPrice((bottom * rangeHighMult) / WAD, daffIsToken0, spacing, false)
        );

        // Keep each range strictly on its own side of the current tick (single-sided).
        int24 below = floorTick(currentTick, spacing); // ranges with hi <= this hold token1 only
        int24 above = below + spacing; // ranges with lo >= this hold token0 only
        // HYPE is token1 when DAFF is token0.
        (p.bidLo, p.bidHi) = daffIsToken0 ? (bA, _min(bB, below)) : (_max(bA, above), bB);
        (p.askLo, p.askHi) = daffIsToken0 ? (_max(aA, above), aB) : (aA, _min(aB, below));

        // Liquidity density: all of `hypeAmount` across the bid range actually used (or the
        // nominal one if clipping emptied it), shared by both sides.
        (int24 lA, int24 lB) = p.bidLo < p.bidHi ? (p.bidLo, p.bidHi) : (bA, bB);
        uint160 sA = TickMath.getSqrtRatioAtTick(lA);
        uint160 sB = TickMath.getSqrtRatioAtTick(lB);
        uint128 liq = sB > sA
            ? (daffIsToken0
                ? LiquidityAmounts.getLiquidityForAmount1(sA, sB, hypeAmount)
                : LiquidityAmounts.getLiquidityForAmount0(sA, sB, hypeAmount))
            : 0;
        if (p.bidLo < p.bidHi) p.bidLiq = liq;
        if (p.askLo < p.askHi) p.askLiq = liq;
    }

    function _sorted(int24 a, int24 b) private pure returns (int24, int24) {
        return a < b ? (a, b) : (b, a);
    }

    function _min(int24 a, int24 b) private pure returns (int24) {
        return a < b ? a : b;
    }

    function _max(int24 a, int24 b) private pure returns (int24) {
        return a > b ? a : b;
    }
}
