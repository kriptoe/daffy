// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DaffyUSDBase} from "./DaffyUSDBase.t.sol";
import {DaffySwap} from "../src/DaffySwap.sol";
import {DaffyMath} from "../src/libraries/DaffyMath.sol";

abstract contract DaffySwapTests is DaffyUSDBase {
    DaffySwap router;
    address dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        _launch();
        router = new DaffySwap(core);
        vm.deal(dave, 10_000 ether);
        usdc.mint(dave, 1_000_000e6);
        vm.startPrank(dave);
        usdc.approve(address(router), type(uint256).max);
        daff.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _poolPrice(bool usdcPool) internal view returns (uint256) {
        (uint160 s,,,,,,) = (usdcPool ? poolU : poolH).slot0();
        return DaffyMath.priceFromSqrt(s, usdcPool ? core.daffIsToken0U() : core.daffIsToken0H());
    }

    function test_BuyWithUsdcAtTheAsk() public {
        uint256 navBefore = core.navUsd();
        (uint256 q,) = router.quote(true, true, 5_000e6);
        vm.prank(dave);
        (uint256 out, uint256 used) = router.buyWithUsdc(5_000e6, q, dave, block.timestamp);
        assertEq(out, q, "quote matches the trade");
        assertEq(used, 5_000e6);
        assertEq(daff.balanceOf(dave), out);
        // bought at 2x NAV or more
        assertGe((5_000e18 * 1e18) / out, (2 * navBefore * 99) / 100, "paid at least 2x NAV");
        assertGt(core.navUsd(), navBefore, "issuing at a premium raises NAV");
    }

    function test_BuyWithNativeHype() public {
        uint256 hypeBefore = dave.balance;
        (uint256 q,) = router.quote(false, true, 50 ether);
        vm.prank(dave);
        (uint256 out, uint256 used) = router.buyWithHype{value: 50 ether}(q, dave, block.timestamp);
        assertEq(out, q);
        assertEq(daff.balanceOf(dave), out);
        assertEq(hypeBefore - dave.balance, used, "only what the pool took");
        assertEq(address(router).balance, 0);
        assertEq(whype.balanceOf(address(router)), 0);
    }

    function test_SellForUsdcAndHypeAtTheBid() public {
        // alice sells launch DAFF: nothing sits above the bid, so it fills there
        vm.prank(alice);
        daff.approve(address(router), type(uint256).max);
        uint256 bal = daff.balanceOf(alice);
        uint256 nav = core.navUsd();

        (uint256 qU,) = router.quote(true, false, 1_000e18);
        vm.prank(alice);
        (uint256 usdcOut, uint256 used) = router.sellForUsdc(1_000e18, qU, alice, block.timestamp);
        assertEq(usdcOut, qU);
        assertEq(used, 1_000e18);
        // sold at 0.8x NAV or less, 0.6x or more
        uint256 px = (usdcOut * 1e12 * 1e18) / used;
        assertLe(px, (nav * 8001) / 10_000, "at or under 0.8x NAV");
        assertGe(px, (nav * 5999) / 10_000, "at or over 0.6x NAV");

        uint256 hypeBefore = alice.balance;
        vm.prank(alice);
        (uint256 hypeOut,) = router.sellForHype(1_000e18, 1, alice, block.timestamp);
        assertEq(alice.balance - hypeBefore, hypeOut, "native HYPE paid out");
        assertEq(daff.balanceOf(alice), bal - 2_000e18);
        assertEq(address(router).balance, 0);
        assertEq(whype.balanceOf(address(router)), 0);
    }

    /// @notice A buy bigger than the ask stops at the ask's top; the price never runs into empty space.
    function test_HugeBuyStopsAtTheTopOfTheAsk() public {
        uint256 nav = core.navUsd();
        vm.prank(dave);
        (uint256 out, uint256 used) = router.buyWithUsdc(900_000e6, 0, dave, block.timestamp);
        assertGt(out, 0);
        assertLt(used, 900_000e6, "only part of the USDC spent");
        assertEq(usdc.balanceOf(dave), 1_000_000e6 - used, "the rest stays with the trader");
        assertLe(_poolPrice(true) * 1e12, (nav * 10_100) / 1000, "price at most ~10x NAV");
        // nothing left: the next buy is refused instead of filling at any price
        vm.prank(dave);
        vm.expectRevert(DaffySwap.NoLiquidityInRange.selector);
        router.buyWithUsdc(1_000e6, 0, dave, block.timestamp);
    }

    function test_MinOutAndDeadline() public {
        (uint256 q,) = router.quote(true, true, 1_000e6);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(DaffySwap.TooLittleOut.selector, q, q + 1));
        router.buyWithUsdc(1_000e6, q + 1, dave, block.timestamp);

        vm.prank(dave);
        vm.expectRevert(DaffySwap.Expired.selector);
        router.buyWithUsdc(1_000e6, 0, dave, block.timestamp - 1);
    }

    function test_CallbackOnlyFromThePoolMidSwap() public {
        vm.expectRevert(DaffySwap.NotPool.selector);
        router.uniswapV3SwapCallback(1, 0, "");
        vm.prank(address(poolU));
        vm.expectRevert(DaffySwap.NotPool.selector);
        router.hyperswapV3SwapCallback(1, 0, "");
    }

    /// @notice Treasury upkeep still works around router trades.
    function test_PokeAfterRouterTrades() public {
        vm.startPrank(dave);
        router.buyWithUsdc(50_000e6, 0, dave, block.timestamp);
        router.sellForUsdc(daff.balanceOf(dave) / 2, 0, dave, block.timestamp);
        vm.stopPrank();
        _wait(8 days);
        _settle(6);
        (uint256 q,) = router.quote(true, true, 1_000e6);
        assertGt(q, 0, "re-placed ask is tradable");
    }
}

contract DaffySwapTest is DaffySwapTests {
    function _usdcAddress() internal pure override returns (address) {
        return 0x0000000000000000000000000000000000001111;
    }

    function _whypeAddress() internal pure override returns (address) {
        return 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    }
}

contract DaffySwapTestFlipped is DaffySwapTests {
    function _usdcAddress() internal pure override returns (address) {
        return 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
    }

    function _whypeAddress() internal pure override returns (address) {
        return 0x0000000000000000000000000000000000002222;
    }
}
