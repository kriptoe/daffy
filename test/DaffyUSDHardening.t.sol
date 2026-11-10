// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {DaffyUSDBase} from "./DaffyUSDBase.t.sol";
import {DaffyUSD} from "../src/DaffyUSD.sol";
import {DaffyMath} from "../src/libraries/DaffyMath.sol";
import {DaffyUSDHyperCore} from "../src/libraries/DaffyUSDHyperCore.sol";

/// @dev Moves an empty pool's price for free, as anyone can.
contract FreePusher {
    function push(IUniswapV3Pool pool, uint160 limit) external {
        (uint160 s,,,,,,) = pool.slot0();
        pool.swap(address(this), limit < s, 1, limit, "");
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external {}
}

/// @notice Attacks found in review, kept as regression tests.
abstract contract DaffyUSDHardeningTests is DaffyUSDBase {
    FreePusher pusher;

    function hcConfig() internal pure override returns (DaffyUSDHyperCore.Config memory c) {
        c = super.hcConfig();
        c.orderSettleSecs = 6;
    }

    function _deposits() internal {
        pusher = new FreePusher();
        vm.prank(alice);
        core.deposit(60_000e6);
        vm.prank(bob);
        core.deposit(40_000e6);
        vm.warp(core.launchEnd());
    }

    function _pokes(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.prank(keeper);
            core.poke();
            _next();
        }
    }

    function _checkBooks() internal {
        uint256 nav = core.navUsd();
        (uint256 topU, uint256 topH) = core.bidTops();
        assertApproxEqRel(topU * 1e12, (nav * 8) / 10, 0.02e18, "USDC bid top at 0.8x NAV");
        topH; // the HYPE bid is filled a few blocks after launch
        // asks start at 2x NAV
        (uint256 q,) = _quoteBuy(true);
        assertApproxEqRel(q, 2 * nav, 0.03e18, "USDC ask starts at 2x NAV");
    }

    /// @dev Price paid per DAFF (WAD USD) for a small buy in the USDC pool.
    function _quoteBuy(bool) internal returns (uint256 px, uint256 out) {
        uint256 snap = vm.snapshotState();
        out = _buy(whale, true, 100e6);
        px = (100e18 * 1e18) / out;
        vm.revertToState(snap);
    }

    // ---- anyone can move an empty pool's price for free before launch

    function test_LaunchSurvivesUsdcPoolPushedToMax() public {
        _deposits();
        pusher.push(poolU, core.daffIsToken0U() ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1);
        core.finalizeLaunch();
        _checkBooks();
    }

    function test_LaunchSurvivesUsdcPoolPushedToZero() public {
        _deposits();
        pusher.push(poolU, core.daffIsToken0U() ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1);
        core.finalizeLaunch();
        _checkBooks();
    }

    function test_LaunchSurvivesUsdcPoolPushedToOneCent() public {
        _deposits();
        pusher.push(poolU, DaffyMath.sqrtFromPrice(1e4, core.daffIsToken0U()));
        core.finalizeLaunch();
        _checkBooks();
    }

    function test_LaunchSurvivesHypePoolInitializedByAStranger() public {
        _deposits();
        poolH.initialize(TickMath.MAX_SQRT_RATIO - 1);
        core.finalizeLaunch();
        _next();
        _pokes(30);
        uint256 nav = core.navUsd();
        (, uint256 topH) = core.bidTops();
        assertApproxEqRel((topH * _snap().px) / 1e18, (nav * 8) / 10, 0.02e18, "HYPE bid top at 0.8x NAV");
        assertGt(core.book(false).bidLiq, 0, "HYPE bid placed");
    }

    function test_LaunchSurvivesHypePoolInitializedAtZero() public {
        _deposits();
        poolH.initialize(TickMath.MIN_SQRT_RATIO + 1);
        core.finalizeLaunch();
        _next();
        _pokes(30);
        uint256 nav = core.navUsd();
        (, uint256 topH) = core.bidTops();
        assertApproxEqRel((topH * _snap().px) / 1e18, (nav * 8) / 10, 0.02e18, "HYPE bid top at 0.8x NAV");
    }

    /// @notice After launch too: the price is pushed around in empty space, upkeep still runs.
    function test_PokeSurvivesPricePushedToExtremes() public {
        _launch();
        pusher = new FreePusher();
        // sell through the whole USDC bid, then push the price to zero for free
        _sell(alice, true, daff.balanceOf(alice)); // more than the bid holds: the price runs to zero
        try pusher.push(poolU, core.daffIsToken0U() ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1) {} catch {}
        _wait(8 days);
        _pokes(8);
        uint256 nav = core.navUsd();
        (uint256 topU,) = core.bidTops();
        if (core.book(true).bidLiq > 0) assertLe(topU * 1e12, (nav * 8001) / 10_000, "bid under 0.8x NAV");
    }

    /// @notice The treasury's swap callback never pays, whoever calls it and whenever.
    function test_SwapCallbackNeverPays() public {
        _launch();
        vm.expectRevert(DaffyUSD.BadCallback.selector);
        core.uniswapV3SwapCallback(0, 0, "");
        vm.prank(address(poolU));
        vm.expectRevert(DaffyUSD.BadCallback.selector);
        core.hyperswapV3SwapCallback(1, 0, "");
        vm.prank(address(poolU));
        vm.expectRevert(DaffyUSD.BadCallback.selector);
        core.uniswapV3MintCallback(1e18, 0, "");
    }

    /// @notice Someone else's liquidity in the way: the free reset is abandoned, nothing is paid.
    function test_NoResetThroughOtherPeoplesLiquidity() public {
        _launch();
        // carol quotes DAFF between the bid and the ask; alice sells into it, so the price sits below 0.8x NAV
        int24 sp = poolU.tickSpacing();
        (, int24 tick,,,,,) = poolU.slot0();
        int24 base = (tick / sp) * sp;
        vm.prank(carol);
        actorU.addLiquidity(base - 10 * sp, base + 10 * sp, 1e15);
        uint256 usdcBefore = usdc.balanceOf(address(core));
        uint256 supplyBefore = daff.totalSupply();
        _price(60e18);
        _pokes(3);
        assertLe(usdc.balanceOf(address(core)), usdcBefore + 1e6, "nothing paid out");
        supplyBefore;
        (uint256 topU,) = core.bidTops();
        assertLe(topU * 1e12, (core.navUsd() * 8001) / 10_000);
    }

    // ---- HyperCore runs orders a few seconds after they are sent

    function test_DelayedOrders_LaunchStillBuysTheHype() public {
        hl.setOrderDelay(4);
        _deposits();
        core.finalizeLaunch();
        _next();
        _pokes(60);
        DaffyUSDHyperCore.Totals memory t = _totals();
        assertApproxEqAbs((t.hypeAllUsd * 10_000) / t.total, 7500, 100, "75% HYPE (less the 1% price limit and fees)");
        assertEq(hl.rejected(), 0, "no order failed");
    }

    function test_DelayedOrders_TrimSellsOnce() public {
        hl.setOrderDelay(4);
        _deposits();
        core.finalizeLaunch();
        _next();
        _pokes(60);
        _price(80e18); // HYPE doubles: a new high with HYPE well over 85%
        _pokes(60);
        DaffyUSDHyperCore.Totals memory t = _totals();
        assertApproxEqAbs((t.hypeAllUsd * 10_000) / t.total, 7500, 100, "trimmed back to 75%, not past it");
        assertEq(hl.rejected(), 0);
    }

    function test_DelayedOrders_DipAndBorrow() public {
        hl.setOrderDelay(4);
        _deposits();
        core.finalizeLaunch();
        _next();
        _pokes(60);
        _price(17e18);
        _pokes(80);
        assertEq(core.coreState().tranchesFired, 3);
        assertEq(hl.rejected(), 0, "no order failed");
        assertFalse(hl.liquidated());
    }
}

contract DaffyUSDHardeningTest is DaffyUSDHardeningTests {
    function _usdcAddress() internal pure override returns (address) {
        return 0x0000000000000000000000000000000000001111;
    }

    function _whypeAddress() internal pure override returns (address) {
        return 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    }
}

contract DaffyUSDHardeningTestFlipped is DaffyUSDHardeningTests {
    function _usdcAddress() internal pure override returns (address) {
        return 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    }

    function _whypeAddress() internal pure override returns (address) {
        return 0x0000000000000000000000000000000000002222;
    }
}
