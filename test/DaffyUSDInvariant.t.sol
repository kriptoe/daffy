// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {DaffyUSDBase} from "./DaffyUSDBase.t.sol";
import {DaffyUSD} from "../src/DaffyUSD.sol";
import {DaffyToken} from "../src/DaffyToken.sol";
import {DaffyMath} from "../src/libraries/DaffyMath.sol";
import {DaffyUSDHyperCore} from "../src/libraries/DaffyUSDHyperCore.sol";
import {MockWHYPE, PoolActor, MockUSDC} from "./mocks/Mocks.sol";
import {MockHyperCore} from "./mocks/MockHyperCore.sol";

/// @notice Random traders, keepers, price moves, interest and time against a launched DaffyUSD.
contract DaffyUSDHandler is Test {
    DaffyUSD public core;
    DaffyToken public daff;
    MockUSDC public usdc;
    MockWHYPE public whype;
    MockHyperCore public hl;
    PoolActor public actorU;
    PoolActor public actorH;
    address[3] internal traders;

    uint256 public price;
    bool public bidAboveNav; // a bid placed above 0.8x NAV
    bool public pokeLostValue; // upkeep cut NAV by more than trading costs
    bool public soldInDump; // HYPE sold with the price more than 10% under its high
    uint256 public trims;
    uint256 public pokesInDebt; // upkeep calls made while a loan was open (borrow variant)
    uint256 public worstPokeBps;
    mapping(bytes32 => uint256) public calls;

    constructor(DaffyUSD c, MockUSDC u, MockWHYPE w, MockHyperCore h, PoolActor aU, PoolActor aH, address[3] memory t) {
        core = c;
        daff = c.token();
        usdc = u;
        whype = w;
        hl = h;
        actorU = aU;
        actorH = aH;
        traders = t;
        price = 40e18;
    }

    function _who(uint256 seed) internal view returns (address) {
        return traders[seed % 3];
    }

    function _limit(bool usdcPool, uint256 navMult) internal view returns (uint160) {
        uint256 nav = core.navUsd();
        uint256 target = usdcPool ? (nav * navMult) / 1e18 / 1e12 : (((nav * 1e18) / price) * navMult) / 1e18;
        if (target == 0) target = 1;
        return DaffyMath.sqrtFromPrice(target, usdcPool ? core.daffIsToken0U() : core.daffIsToken0H());
    }

    function buy(uint256 seed, uint256 amount, bool usdcPool) external {
        calls["buy"]++;
        address who = _who(seed);
        uint160 lim = _limit(usdcPool, bound(seed, 1.5e18, 4e18));
        amount = usdcPool ? bound(amount, 10e6, 30_000e6) : bound(amount, 0.5e18, 800e18);
        vm.prank(who);
        try (usdcPool ? actorU : actorH).swap(usdcPool ? address(usdc) : address(whype), amount, lim) {} catch {}
    }

    function sell(uint256 seed, uint256 amount, bool usdcPool) external {
        calls["sell"]++;
        address who = _who(seed);
        uint256 bal = daff.balanceOf(who);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint160 lim = _limit(usdcPool, bound(seed, 0.3e18, 0.95e18));
        vm.prank(who);
        try (usdcPool ? actorU : actorH).swap(address(daff), amount, lim) {} catch {}
    }

    function poke(uint256 seed) external {
        _poke(seed);
    }

    /// @notice A crash to 30-45% of HYPE's high (tranches, then the borrow tranche), with upkeep.
    function crash(uint256 seed) external {
        calls["crash"]++;
        _next();
        uint256 high = core.coreState().highPx;
        uint256 p = (high * bound(seed, 30, 45)) / 100;
        if (p < 10e18) p = 10e18;
        price = p - (p % 1e14);
        hl.setOracle(price);
        for (uint256 i; i < 6; i++) _poke(seed + i);
    }

    function _poke(uint256 seed) internal {
        calls["poke"]++;
        uint256 navBefore = core.navUsd();
        uint256 sellsBefore = hl.spotSells(address(core));
        bool inDebt = core.coreSnapshot().borrowed > 0; // a deleverage sale is the one allowed in a dump
        vm.prank(_who(seed));
        core.poke();
        uint256 highPx = core.coreState().highPx;
        uint256 navAfter = core.navUsd();
        if (navAfter * 10_000 < navBefore * 9_970) {
            pokeLostValue = true;
            uint256 bps = ((navBefore - navAfter) * 10_000) / navBefore;
            if (bps > worstPokeBps) worstPokeBps = bps;
        }
        // positions placed in this block sit under 0.8x NAV
        (uint256 topU, uint256 topH) = core.bidTops();
        uint64 atU = core.book(true).placedAt;
        uint64 atH = core.book(false).placedAt;
        if (atU == block.timestamp && topU * 1e12 > (navAfter * 8001) / 10_000) bidAboveNav = true;
        if (atH == block.timestamp && (topH * price) / 1e18 > (navAfter * 8001) / 10_000) bidAboveNav = true;
        _next();
        if (core.coreSnapshot().borrowed > 0) pokesInDebt++;
        if (hl.spotSells(address(core)) > sellsBefore) {
            trims++;
            if (price * 10 < highPx * 9 && !inDebt) soldInDump = true;
        }
    }

    function warp(uint256 secs) external {
        calls["warp"]++;
        vm.warp(vm.getBlockTimestamp() + bound(secs, 60, 8 days));
        _next();
        // time passed, so HyperCore has run any delayed order by now
        for (uint256 i; i < hl.orderDelay(); i++) hl.nextBlock();
    }

    /// @notice HYPE moves 0.5x-2x in one block, kept within $10-$300.
    function jumpPrice(uint256 seed) external {
        calls["jump"]++;
        _next();
        uint256 lo = price / 2 < 10e18 ? 10e18 : price / 2;
        uint256 hi = price * 2 > 300e18 ? 300e18 : price * 2;
        price = bound(seed, lo, hi);
        price -= price % 1e14; // oracle has 4 decimals
        hl.setOracle(price);
    }

    function accrue(uint256 ppm) external {
        calls["accrue"]++;
        hl.accrueLending(bound(ppm, 0, 2_000));
    }

    function donate(uint256 amount) external {
        calls["donate"]++;
        usdc.mint(address(core), bound(amount, 1e6, 5_000e6));
    }

    function nextBlock() external {
        calls["next"]++;
        _next();
    }

    function _next() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        hl.nextBlock();
    }
}

abstract contract DaffyUSDInvariantBase is DaffyUSDBase {
    DaffyUSDHandler handler;

    function setUp() public virtual override {
        super.setUp();
        _launch();
        address[3] memory t = [alice, bob, carol];
        handler = new DaffyUSDHandler(core, usdc, whype, hl, actorU, actorH, t);
        for (uint256 i; i < 3; i++) {
            vm.startPrank(t[i]);
            usdc.approve(address(actorU), type(uint256).max);
            whype.approve(address(actorH), type(uint256).max);
            daff.approve(address(actorU), type(uint256).max);
            daff.approve(address(actorH), type(uint256).max);
            vm.stopPrank();
        }
        targetContract(address(handler));
    }

    /// @notice The treasury only borrows when the borrow tranche is on.
    function invariant_NoUsdcDebtUnlessBorrowing() public view {
        (,,, int256 u,,,) = hl.acct(address(core));
        if (!core.coreState().borrowEnabled) assertGe(u, 0, "USDC debt on HyperCore");
    }

    /// @notice Borrowing or not, the HyperCore account is never liquidatable.
    function invariant_NeverLiquidated() public view {
        assertFalse(hl.liquidated(), "liquidatable");
    }

    /// @notice Every CoreWriter action the treasury sent was one HyperCore accepts.
    function invariant_EveryActionValid() public view {
        assertEq(hl.rejected(), 0, "rejected HyperCore action");
    }

    function invariant_BidsPlacedUnderNav() public view {
        assertFalse(handler.bidAboveNav(), "a bid was placed above 0.8x NAV");
    }

    /// @notice HYPE is only ever sold within 10% of its high (rally trims), never into a dump.
    function invariant_NeverSellsHypeInADump() public view {
        assertFalse(handler.soldInDump(), "sold HYPE more than 10% under its high");
    }

    function invariant_UpkeepKeepsValue() public view {
        assertFalse(handler.pokeLostValue(), "upkeep lost value");
    }

    /// @notice The treasury's own total matches an independent count: HyperCore per the mock, EVM
    ///         balances, and everything the pools hold (the pools hold only treasury liquidity, plus
    ///         uncollected fees, so the independent count may be a little higher).
    function invariant_AccountingMatches() public view {
        uint256 px = handler.price();
        IUniswapV3Pool pU = core.poolUsdc();
        IUniswapV3Pool pH = core.poolHype();
        uint256 indep = hl.valueUsd(address(core)) + (usdc.balanceOf(address(core)) + usdc.balanceOf(address(pU))) * 1e12
            + ((whype.balanceOf(address(core)) + address(core).balance + whype.balanceOf(address(pH))) * px) / 1e18;
        DaffyUSDHyperCore.State memory st = core.coreState();
        if (st.inflightBlock == block.number) indep += st.inflightUsd;
        uint256 total = core.totals().total;
        assertLe(total, indep + 1e15, "treasury counts more than exists");
        assertGe(total * 1000, indep * 990, "treasury misses more than 1% (uncollected fees)");
    }

    function afterInvariant() public view {
        console2.log("worst poke loss bps", handler.worstPokeBps());
        console2.log("buys", handler.calls("buy"), "sells", handler.calls("sell"));
        console2.log("pokes", handler.calls("poke"), "jumps", handler.calls("jump"));
        console2.log("trims", handler.trims(), "pokes in debt", handler.pokesInDebt());
    }
}

address constant ILOW = 0x0000000000000000000000000000000000001111;
address constant IHIGH = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
address constant IHIGH2 = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
address constant ILOW2 = 0x0000000000000000000000000000000000002222;

contract DaffyUSDInvariantTest is DaffyUSDInvariantBase {
    function _usdcAddress() internal pure override returns (address) {
        return ILOW;
    }

    function _whypeAddress() internal pure override returns (address) {
        return IHIGH;
    }
}

contract DaffyUSDInvariantTestFlipped is DaffyUSDInvariantBase {
    function _usdcAddress() internal pure override returns (address) {
        return IHIGH2;
    }

    function _whypeAddress() internal pure override returns (address) {
        return ILOW2;
    }
}

/// @dev Same fuzzing with the borrow tranche turned on.
contract DaffyUSDInvariantBorrowTest is DaffyUSDInvariantBase {
    function _usdcAddress() internal pure override returns (address) {
        return ILOW;
    }

    function _whypeAddress() internal pure override returns (address) {
        return IHIGH;
    }

    function setUp() public override {
        super.setUp();
        vm.prank(migrator);
        core.setBorrowing(true);
        vm.roll(vm.getBlockNumber() + 1);
        hl.nextBlock();
    }
}

/// @notice HyperCore runs orders three blocks late (mainnet delays them "a few seconds"), with the
///         borrow tranche on: the strategy waits for each order before its next step.
contract DaffyUSDInvariantDelayedOrdersTest is DaffyUSDInvariantBase {
    function _usdcAddress() internal pure override returns (address) {
        return ILOW;
    }

    function _whypeAddress() internal pure override returns (address) {
        return IHIGH;
    }

    function hcConfig() internal pure override returns (DaffyUSDHyperCore.Config memory c) {
        c = super.hcConfig();
        c.orderSettleSecs = 5;
        c.borrowAtLaunch = true;
    }

    function setUp() public override {
        DaffyUSDBase.setUp();
        hl.setOrderDelay(3);
        vm.prank(alice);
        core.deposit(60_000e6);
        vm.prank(bob);
        core.deposit(30_000e6);
        vm.prank(carol);
        core.deposit(10_000e6);
        vm.warp(core.launchEnd());
        core.finalizeLaunch();
        _next();
        _settle(40);
        address[3] memory t = [alice, bob, carol];
        handler = new DaffyUSDHandler(core, usdc, whype, hl, actorU, actorH, t);
        for (uint256 i; i < 3; i++) {
            vm.startPrank(t[i]);
            usdc.approve(address(actorU), type(uint256).max);
            whype.approve(address(actorH), type(uint256).max);
            daff.approve(address(actorU), type(uint256).max);
            daff.approve(address(actorH), type(uint256).max);
            vm.stopPrank();
        }
        targetContract(address(handler));
    }
}
