// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DaffyMath} from "../src/libraries/DaffyMath.sol";
import {DaffyUSDBase} from "./DaffyUSDBase.t.sol";
import {DaffyUSD} from "../src/DaffyUSD.sol";
import {DaffyToken} from "../src/DaffyToken.sol";
import {DaffyUSDHyperCore} from "../src/libraries/DaffyUSDHyperCore.sol";
import {MockSuccessorUSD} from "./mocks/Mocks.sol";

/// @notice v2 behaviour. Runs for both token orders in both pools (see the two contracts at the end).
abstract contract DaffyUSDTests is DaffyUSDBase {
    // ------------------------------------------------------------------ deposits

    function test_DepositMintsOneToOne() public {
        vm.prank(alice);
        core.deposit(1_000e6);
        assertEq(daff.balanceOf(alice), 1_000e18);
        assertEq(usdc.balanceOf(address(core)), 1_000e6);
    }

    function test_WithdrawDepositBeforeLaunch() public {
        vm.prank(alice);
        core.deposit(1_000e6);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        core.withdrawDeposit(400e18);
        assertEq(usdc.balanceOf(alice) - before, 400e6);
        assertEq(daff.balanceOf(alice), 600e18);
    }

    function test_TransfersLockedUntilLaunch() public {
        vm.prank(alice);
        core.deposit(1_000e6);
        vm.prank(alice);
        vm.expectRevert(DaffyToken.TransfersLocked.selector);
        daff.transfer(bob, 1e18);
    }

    function test_DepositsCloseAtLaunchEnd() public {
        vm.warp(core.launchEnd());
        vm.prank(alice);
        vm.expectRevert(DaffyUSD.DepositWindowClosed.selector);
        core.deposit(1e6);
    }

    function test_LaunchNeedsTheWindowAndACoreAccount() public {
        vm.prank(alice);
        core.deposit(100_000e6);
        vm.expectRevert(DaffyUSD.DepositWindowOpen.selector);
        core.finalizeLaunch();
        vm.warp(core.launchEnd());
        hl.setExists(address(core), false);
        vm.expectRevert(DaffyUSD.CoreAccountNotActivated.selector);
        core.finalizeLaunch();
    }

    // ------------------------------------------------------------------ allocation

    function test_LaunchAllocatesTheTreasury() public {
        _launch();
        DaffyUSDHyperCore.Totals memory t = _totals();
        DaffyUSDHyperCore.Snapshot memory n = _snap();
        assertApproxEqAbs(core.navUsd(), 1e18, 0.002e18, "NAV ~$1, less trading fees");
        assertApproxEqAbs(_share(t.hypeAllUsd, t.total), 7425, 100, "~75% HYPE (sized at the limit price)");
        assertApproxEqAbs(_share(t.hypeBidUsd, t.total), 2000, 50, "20% as the DAFF/HYPE bid");
        assertApproxEqAbs(_share(n.supplied, t.total), 2075, 100, "~20% dip fund in lending");
        assertEq(n.usdc, 0, "no idle USDC on HyperCore");
        assertEq(hl.rejected(), 0, "every HyperCore action was valid");
    }

    function test_BidsSitBelowNavAndAsksAtTwice() public {
        _launch();
        uint256 nav = core.navUsd();
        (uint256 topU, uint256 topH) = core.bidTops();
        assertLe(topU * 1e12, (nav * 8) / 10, "USDC bid at most 0.8x NAV");
        assertGt(topU * 1e12, (nav * 75) / 100, "and close to it");
        assertLe((topH * _snap().px) / 1e18, (nav * 8) / 10, "HYPE bid at most 0.8x NAV");
        // the cheapest DAFF anyone can buy from the treasury costs at least 2x NAV
        uint256 got = _buyTo(whale, true, 1_000_000e6, 1.99e18);
        assertEq(got, 0, "nothing for sale below 2x NAV");
    }

    // ------------------------------------------------------------------ exits

    function test_ExitForUsdcBelowNavRaisesNavForHolders() public {
        _launch();
        uint256 navBefore = core.navUsd();
        uint256 sold = daff.balanceOf(bob);
        uint256 got = _sellTo(bob, true, sold, 0.6e18);
        uint256 used = sold - daff.balanceOf(bob);
        assertGt(got, 0, "got USDC");
        assertLe((got * 1e12 * 1e18) / used, (navBefore * 8) / 10, "paid at most 0.8x NAV");
        assertGt(core.navUsd(), navBefore, "NAV up for everyone left");
        // the next re-placement burns what the bid bought
        uint256 supplyBefore = daff.totalSupply();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _settle(1);
        assertLt(daff.totalSupply(), supplyBefore, "bought DAFF burned");
    }

    function test_ExitForHype() public {
        _launch();
        uint256 navBefore = core.navUsd();
        uint256 before = whype.balanceOf(alice);
        _sellTo(alice, false, 5_000e18, 0.6e18);
        uint256 got = whype.balanceOf(alice) - before;
        uint256 used = 60_000e18 - daff.balanceOf(alice);
        assertGt(got, 0, "got HYPE");
        assertLe((got * _snap().px) / used, (navBefore * 8) / 10, "paid at most 0.8x NAV in HYPE");
        assertGt(core.navUsd(), navBefore);
    }

    /// @notice An empty USDC bid is not refilled by selling HYPE.
    function test_UsdcBidNotRefilledFromHype() public {
        _launch();
        _sellTo(bob, true, daff.balanceOf(bob), 0.5e18); // empties the USDC bid
        uint256 sellsBefore = hl.spotSells(address(core));
        vm.warp(vm.getBlockTimestamp() + 8 days);
        _settle(6);
        assertEq(hl.spotSells(address(core)), sellsBefore, "no HYPE sold");
    }

    // ------------------------------------------------------------------ premium

    function test_PremiumBuysRaiseNavAndBuyHype() public {
        _launch();
        uint256 navBefore = core.navUsd();
        uint256 hypeBefore = _totals().hypeAll;
        _buyTo(whale, true, 20_000e6, 3e18); // buys from the 2x-10x asks
        assertGt(core.navUsd(), navBefore, "selling DAFF at 2x+ NAV raises NAV");
        vm.warp(vm.getBlockTimestamp() + 7 days); // re-placement collects the USDC
        _settle(6);
        assertGt(_totals().hypeAll, hypeBefore, "70% of the new USDC bought HYPE");
    }

    // ------------------------------------------------------------------ dips

    /// @notice Each tranche pulls a third of the dip fund (as it stood at the first) out of lending.
    ///         The fund also gains a little on the way down: a falling NAV shrinks the USDC bid's
    ///         target, and 30% of the USDC that frees goes to the dip fund (70% buys HYPE).
    function test_DipTranchesBuyHypeInThirds() public {
        _launch();
        uint256 third = _snap().supplied / 3;
        uint256 hype0 = _totals().hypeAll;

        _price(30e18); // -25%
        uint256 s0 = _snap().supplied;
        _settle(3);
        uint256 s1 = _snap().supplied;
        assertApproxEqRel(s0 - s1, third, 0.1e18, "first third spent");
        uint256 hype1 = _totals().hypeAll;
        assertGt(hype1, hype0, "bought HYPE");

        _price(29e18); // above -40%: nothing more
        _settle(3);
        assertGe(_snap().supplied, s1, "no second tranche yet");

        _price(24e18); // -40%
        s1 = _snap().supplied;
        _settle(3);
        assertApproxEqRel(s1 - _snap().supplied, third, 0.15e18, "second third");

        _price(18e18); // -55%
        _settle(3);
        // the rest, bar change and the dip fund's share of USDC freed as the USDC bid's target shrinks
        assertLt(_snap().supplied, _totals().total / 200, "the rest");
        assertGt(_totals().hypeAll, hype1);
        assertEq(hl.spotSells(address(core)), 0, "never sold HYPE on the way down");
        assertEq(hl.rejected(), 0);
    }

    function test_TranchesResetAtANewHigh() public {
        _launch();
        _price(30e18);
        _settle(3);
        assertEq(core.coreState().tranchesFired, 1);
        _price(45e18); // new high
        _settle(1);
        assertEq(core.coreState().tranchesFired, 0, "levels reset");
    }

    // ------------------------------------------------------------------ lending read missing

    /// @notice On mainnet the 0x811 read reverted until the contract first supplied to lending (and
    ///         an erroring read burns all the gas it's given). The core seeds lending with the $10
    ///         minimum, then uses it as normal once the read works.
    function test_LendingReadOpensAfterTheSeed() public {
        hl.setLendingReadBroken(true);
        vm.prank(alice);
        core.deposit(60_000e6);
        vm.prank(bob);
        core.deposit(40_000e6);
        vm.warp(core.launchEnd());
        core.finalizeLaunch{gas: 3_000_000}(); // the failing read burns only its own 50k
        _next();
        _settle(14);
        DaffyUSDHyperCore.Snapshot memory n = _snap();
        DaffyUSDHyperCore.Totals memory t = _totals();
        assertTrue(n.lendingReadable, "read works after the seed");
        assertTrue(core.coreState().lendingSeeded);
        assertApproxEqAbs(_share(n.supplied, t.total), 2075, 100, "the dip fund went to lending");
        assertApproxEqAbs(core.navUsd(), 1e18, 0.002e18);
        assertEq(hl.rejected(), 0);
    }

    /// @notice If the read never works, only the $10 seed goes in; the dip fund stays on spot,
    ///         still counted, and tranches spend it directly.
    function test_WorksWhenTheLendingReadNeverWorks() public {
        hl.setLendingReadBrokenForever(true);
        _launch();
        DaffyUSDHyperCore.Totals memory t = _totals();
        DaffyUSDHyperCore.Snapshot memory n = _snap();
        assertFalse(n.lendingReadable);
        assertEq(hl.suppliedOf(address(core)), 10e8, "only the $10 seed");
        assertApproxEqAbs(_share(n.usdc, t.total), 2075, 100, "dip fund held as spot USDC");
        assertApproxEqAbs(core.navUsd(), 1e18, 0.002e18, "NAV misses only the seed");

        uint256 hypeBefore = t.hypeAll;
        _price(30e18);
        _settle(3);
        assertApproxEqRel(_snap().usdc, (n.usdc * 2) / 3, 0.1e18, "a third of the dip fund spent");
        assertGt(_totals().hypeAll, hypeBefore, "bought HYPE");
        assertEq(hl.rejected(), 0);
    }

    // ------------------------------------------------------------------ deeper dips after bigger runs

    /// @notice Launch at $40. A $61.6 high is 54% above it: every tranche ~5.4 points deeper.
    function test_DipsDeepenAfterARun() public {
        _launch();
        (uint256 a,,) = core.dipLevels();
        assertEq(a, 30e18, "at the launch price: -25%");
        _price(61.6e18); // the same +54% as $78 -> $120
        _settle(12);
        (uint256 first, uint256 second, uint256 third) = core.dipLevels();
        assertApproxEqRel(first, (61.6e18 * (10_000 - 2500 - 540)) / 10_000, 0.001e18, "about -30%");
        assertApproxEqRel(second, (61.6e18 * (10_000 - 4000 - 540)) / 10_000, 0.001e18, "about -45%");
        assertApproxEqRel(third, (61.6e18 * (10_000 - 5500 - 540)) / 10_000, 0.001e18, "about -60%");

        uint256 fund = _snap().supplied;
        _price(first + 0.5e18); // a 25% pullback is no longer enough
        _settle(3);
        assertGe(_snap().supplied, fund, "no tranche yet");
        _price(first);
        _settle(3);
        assertLt(_snap().supplied, fund, "the first tranche fires at the deeper level");
    }

    function test_DipDeepeningIsCapped() public {
        _launch();
        _price(200e18); // 5x launch
        _settle(12);
        (uint256 first,, uint256 third) = core.dipLevels();
        assertEq(first, (200e18 * (10_000 - 2500 - 1500)) / 10_000, "-40% at most");
        assertEq(third, (200e18 * (10_000 - 5500 - 1500)) / 10_000, "-70% at most");
    }

    // ------------------------------------------------------------------ rally trims

    function test_RallyTrimsBackToSeventyPercent() public {
        _launch();
        uint256 suppliedBefore = _snap().supplied;
        _price(120e18); // 3x: HYPE ~90% of the treasury
        _settle(8);
        DaffyUSDHyperCore.Totals memory t = _totals();
        assertApproxEqAbs(_share(t.hypeAllUsd, t.total), 7500, 150, "trimmed to ~75%");
        assertGt(_snap().supplied, suppliedBefore, "proceeds went to the dip fund");
        assertGt(hl.spotSells(address(core)), 0);
    }

    function test_NoTrimBelowNinetyPercentOfTheHigh() public {
        _launch();
        _price(18e18); // all three tranches: HYPE share rises
        _settle(10);
        _price(34e18); // below 0.9 x 40: no trim, whatever the share
        _settle(10);
        assertEq(hl.spotSells(address(core)), 0, "dip buys are kept");
    }

    // ------------------------------------------------------------------ HYPE bid refills

    function test_HypeBidRefillIsCappedPerWeek() public {
        _launch();
        uint256 hypeAll = _totals().hypeAll;
        // sellers take most of the HYPE bid
        _sellTo(alice, false, daff.balanceOf(alice), 0.4e18);
        uint256 bidAfterSell = _totals().hypeBidUsd;
        assertLt(bidAfterSell, (_totals().total * 2000) / 10_000 / 2, "bid mostly taken");
        _settle(10);
        uint256 refilled = core.coreState().refilledInWindow;
        assertGt(refilled, 0, "refilled");
        assertLe(refilled, (hypeAll * 500) / 10_000 + 1e18, "at most 5% of the HYPE this week");
    }

    // ------------------------------------------------------------------ lending, rewards

    function test_LendingInterestRaisesNav() public {
        _launch();
        uint256 navBefore = core.navUsd();
        hl.accrueLending(10_000); // +1% on the dip fund
        assertGt(core.navUsd(), navBefore);
    }

    function test_KeeperPaidForRealWork() public {
        _launch();
        usdc.mint(address(core), 100e6); // fees and premium sales fund the reward reserve
        _price(30e18);
        uint256 before = usdc.balanceOf(keeper);
        _settle(1);
        assertEq(usdc.balanceOf(keeper) - before, 1e6, "paid for the dip tranche");
        _settle(1); // just buying: no reward, and the interval hasn't passed
        assertEq(usdc.balanceOf(keeper) - before, 1e6);
    }

    function test_RecentersWhenNavMoves() public {
        _launch();
        _price(60e18); // NAV up ~35%
        _settle(3);
        uint256 nav = core.navUsd();
        uint256 navAtPlace = core.book(true).navAtPlace;
        assertApproxEqRel(navAtPlace * 1e12, nav, 0.01e18, "USDC pool re-placed at the new NAV");
        (uint256 topU, uint256 topH) = core.bidTops();
        assertLe(topU * 1e12, (nav * 8) / 10, "USDC bid under NAV");
        // nobody has traded and there is no other liquidity, so the pool price is moved up for free
        // and the bid sits at 0.6-0.8x the new NAV (never above the pool price)
        assertGe(topU * 1e12, (nav * 78) / 100, "USDC bid follows NAV");
        (uint160 sq,,,,,,) = poolU.slot0();
        assertLe(topU, DaffyMath.priceFromSqrt(sq, core.daffIsToken0U()) + 1, "and not above the pool price");
        assertLe((topH * _snap().px) / 1e18, (nav * 8) / 10, "HYPE bid under NAV");
    }

    // ------------------------------------------------------------------ launch rules

    function test_NoLaunchBelowTheMinimumAndRefundsStayOpen() public {
        vm.prank(alice);
        core.deposit(99_999e6);
        vm.warp(core.launchEnd());
        vm.expectRevert(DaffyUSD.MinimumNotReached.selector);
        core.finalizeLaunch();
        (,,,,, bool canLaunch, bool failed) = core.launchStatus();
        assertFalse(canLaunch);
        assertTrue(failed, "shown as failed");
        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        core.withdrawDeposit(99_999e18);
        assertEq(usdc.balanceOf(alice) - before, 99_999e6, "full refund, any time");
        vm.expectRevert(DaffyUSD.DepositWindowClosed.selector);
        vm.prank(bob);
        core.deposit(1e6);
    }

    function test_TenMillionLaunchesEarly() public {
        vm.prank(whale);
        core.deposit(9_999_999e6);
        vm.expectRevert(DaffyUSD.DepositWindowOpen.selector);
        core.finalizeLaunch();
        vm.prank(alice);
        core.deposit(1e6);
        (uint256 deposited,,,,, bool canLaunch,) = core.launchStatus();
        assertEq(deposited, 10_000_000e6);
        assertTrue(canLaunch, "$10M reached");
        vm.prank(carol); // anyone
        core.finalizeLaunch();
        assertTrue(core.launched());
    }

    function test_LaunchStatusTracksDeposits() public {
        vm.prank(alice);
        core.deposit(70_000e6);
        vm.prank(alice);
        core.withdrawDeposit(20_000e18);
        usdc.mint(address(core), 1_000e6); // a plain transfer doesn't count as a deposit
        (uint256 deposited, uint256 minimum, uint256 earlyAt, uint256 endsAt, bool isLaunched,,) = core.launchStatus();
        assertEq(deposited, 50_000e6);
        assertEq(minimum, 100_000e6);
        assertEq(earlyAt, 10_000_000e6);
        assertEq(endsAt, core.launchEnd());
        assertFalse(isLaunched);
    }

    // ------------------------------------------------------------------ rewards

    /// @notice Rewards come out of a reserve capped at 20 rewards, at most one per interval.
    function test_RewardsOnlyFromTheReserve() public {
        _launch();
        assertEq(core.rewardReserve(), 0, "nothing spare yet");
        usdc.mint(address(core), 50e6); // incoming USDC: the first 20 fill the reserve
        _price(30e18); // a dip tranche: real work
        uint256 before = usdc.balanceOf(keeper);
        _settle(1);
        assertEq(usdc.balanceOf(keeper) - before, 1e6, "paid once");
        assertEq(core.rewardReserve(), 19e6, "from the reserve");
        _price(24e18); // more real work, inside the 10-minute interval
        _settle(1);
        assertEq(usdc.balanceOf(keeper) - before, 1e6, "one reward per interval");
        usdc.mint(address(core), 500e6);
        _settle(2);
        assertLe(core.rewardReserve(), 20e6, "the reserve never holds more than 20 rewards");
    }

    function test_SetRewardsWithinBounds() public {
        vm.prank(migrator);
        core.setRewards(0.25e6, 1 hours);
        assertEq(core.getParams().pokeReward, 0.25e6);
        vm.prank(migrator);
        vm.expectRevert(DaffyUSD.BadReward.selector);
        core.setRewards(6e6, 1 hours);
        vm.prank(migrator);
        vm.expectRevert(DaffyUSD.BadReward.selector);
        core.setRewards(1e6, 5 minutes);
        vm.prank(alice);
        vm.expectRevert(DaffyUSD.NotMigrator.selector);
        core.setRewards(1e6, 1 hours);
    }

    // ------------------------------------------------------------------ borrow tranche

    function _debt() internal view returns (uint256) {
        return _snap().borrowed;
    }

    function _ltvBps() internal view returns (uint256) {
        DaffyUSDHyperCore.Snapshot memory n = _snap();
        uint256 coll = (n.hype * n.px) / 1e18;
        return coll == 0 ? 0 : (n.borrowed * 10_000) / coll;
    }

    function test_NoBorrowingUnlessTurnedOn() public {
        _launch();
        _price(18e18);
        _settle(12);
        assertEq(_debt(), 0, "off by default");
        assertFalse(hl.isPm(address(core)));
    }

    function test_BorrowTrancheAfterTheDipFund() public {
        _launch();
        vm.prank(migrator);
        core.setBorrowing(true);
        _next();
        assertTrue(hl.isPm(address(core)), "portfolio margin on");

        _price(18e18); // -55%: three tranches, then the borrow
        _settle(14);
        assertEq(core.coreState().tranchesFired, 3, "dip fund spent first");
        assertLt(_snap().supplied, _totals().total / 100, "bar the re-supplied change");
        assertGt(_debt(), 0, "borrowed");
        assertLe(_ltvBps(), 2100, "about 20% of the HYPE's value");
        assertTrue(core.coreState().borrowFired);

        _price(15e18); // lower still: no second loan
        _settle(6);
        assertLe(_ltvBps(), 2600);
        assertFalse(hl.liquidated());
        assertEq(hl.rejected(), 0);
    }

    function test_DeleveragesBeforeLiquidation() public {
        _launch();
        vm.prank(migrator);
        core.setBorrowing(true);
        _next();
        _price(18e18);
        _settle(14);
        _price(7e18); // HYPE -83% from its high: debt ~51% of the HYPE
        _settle(6);
        assertLe(_ltvBps(), 4200, "sold back to ~40%");
        assertFalse(hl.liquidated(), "never liquidatable");
        _price(5e18);
        _settle(6);
        assertLe(_ltvBps(), 5100);
        assertFalse(hl.liquidated());
    }

    function test_RallyRepaysTheLoan() public {
        _launch();
        vm.prank(migrator);
        core.setBorrowing(true);
        _next();
        _price(18e18);
        _settle(14);
        assertGt(_debt(), 0);
        _price(45e18); // a new high: trims sell HYPE, and the USDC repays the loan
        _settle(10);
        assertEq(_debt(), 0, "repaid");
        assertFalse(core.coreState().borrowFired, "free to borrow in the next dip");
    }

    function test_NoHypeBidRefillWhileInDebt() public {
        _launch();
        vm.prank(migrator);
        core.setBorrowing(true);
        _next();
        _price(18e18);
        _settle(14);
        uint256 refilled = core.coreState().refilledInWindow;
        _sellTo(alice, false, daff.balanceOf(alice), 0.3e18); // empty the HYPE bid
        _settle(6);
        assertEq(core.coreState().refilledInWindow, refilled, "HYPE stays as collateral");
    }

    function test_MigrationRepaysTheLoanFirst() public {
        _launch();
        vm.prank(migrator);
        core.setBorrowing(true);
        _next();
        _price(18e18);
        _settle(14);
        uint256 total = _totals().total;
        MockSuccessorUSD next = new MockSuccessorUSD();
        vm.prank(migrator);
        core.proposeMigration(address(next));
        vm.warp(vm.getBlockTimestamp() + 14 days);
        vm.prank(migrator);
        core.executeMigration();
        for (uint256 i; i < 8; i++) {
            _next();
            core.forwardToSuccessor();
        }
        assertEq(_debt(), 0, "loan repaid");
        uint256 got = usdc.balanceOf(address(next)) * 1e12 + (whype.balanceOf(address(next)) * _snap().px) / 1e18;
        assertApproxEqRel(got, total, 0.01e18, "the rest forwarded");
    }

    // ------------------------------------------------------------------ pool callbacks

    /// @notice HyperSwap V3 calls hyperswapV3MintCallback; only the two pools may call either name.
    function test_MintCallbacksOnlyFromThePools() public {
        assertEq(DaffyUSD.hyperswapV3MintCallback.selector, bytes4(0xf24aceb7), "HyperSwap's selector");
        vm.expectRevert(DaffyUSD.BadCallback.selector);
        core.hyperswapV3MintCallback(1, 1, "");
        vm.expectRevert(DaffyUSD.BadCallback.selector);
        core.uniswapV3MintCallback(1, 1, "");
    }

    // ------------------------------------------------------------------ migration

    function test_MigrationForwardsEverything() public {
        _launch();
        uint256 total = _totals().total;
        MockSuccessorUSD next = new MockSuccessorUSD();
        vm.prank(migrator);
        core.proposeMigration(address(next));
        vm.warp(vm.getBlockTimestamp() + 14 days);
        vm.prank(migrator);
        core.executeMigration();
        assertTrue(next.accepted());
        assertEq(daff.core(), address(next), "token handed over");
        for (uint256 i; i < 6; i++) {
            _next();
            core.forwardToSuccessor();
        }
        uint256 got = usdc.balanceOf(address(next)) * 1e12 + (whype.balanceOf(address(next)) * _snap().px) / 1e18;
        assertApproxEqRel(got, total, 0.001e18, "all value forwarded");
        DaffyUSDHyperCore.Snapshot memory n = _snap();
        assertEq(n.hype + n.usdc + n.supplied, 0, "HyperCore emptied");
    }

    function test_MigrationNeedsTheTimelock() public {
        _launch();
        address next = address(new MockSuccessorUSD());
        vm.prank(migrator);
        core.proposeMigration(next);
        vm.warp(vm.getBlockTimestamp() + 13 days);
        vm.prank(migrator);
        vm.expectRevert(DaffyUSD.MigrationNotReady.selector);
        core.executeMigration();
    }
}

/// @notice Test mode (testing deployments only).
abstract contract DaffyUSDTestModeTests is DaffyUSDBase {
    function defaultParams() internal pure override returns (DaffyUSD.Params memory p) {
        p = super.defaultParams();
        p.testMode = true;
    }

    function test_MigratorCanLaunchEarly() public {
        vm.prank(alice);
        core.deposit(1_000e6);
        vm.expectRevert(DaffyUSD.DepositWindowOpen.selector);
        core.finalizeLaunch();
        vm.prank(migrator);
        core.finalizeLaunch();
        assertTrue(core.launched());
    }

    function test_ManualStopsTheStrategy() public {
        vm.prank(alice);
        core.deposit(1_000e6);
        vm.prank(migrator);
        core.finalizeLaunch();
        vm.prank(migrator);
        core.setManual(true);
        _next();
        _settle(4);
        assertEq(_totals().hypeAll, 0, "no HYPE bought in manual mode");
    }

    function test_WithdrawPoolsAndCore() public {
        _launch();
        vm.startPrank(migrator);
        core.setManual(true);
        core.testPullPools();
        core.testCoreAction(15, abi.encode(uint8(1), uint64(0), uint64(0))); // withdraw the dip fund
        vm.stopPrank();
        _next();
        DaffyUSDHyperCore.Snapshot memory n = _snap();
        vm.startPrank(migrator);
        core.testCoreAction(13, abi.encode(address(0x2000000000000000000000000000000000000000), address(0), type(uint32).max, type(uint32).max, uint64(0), uint64(n.usdc / 1e10)));
        core.testCoreAction(13, abi.encode(address(0x2222222222222222222222222222222222222222), address(0), type(uint32).max, type(uint32).max, uint64(150), uint64(n.hype / 1e10)));
        vm.stopPrank();
        _next();
        address to = makeAddr("me");
        vm.prank(migrator);
        core.testWithdraw(to, type(uint256).max, type(uint256).max);
        uint256 got = usdc.balanceOf(to) * 1e12 + (to.balance * _snap().px) / 1e18;
        assertGt(got, 99_000e18, "nearly all $100k back");
    }

    function test_EmptyTreasuryThenTopUp() public {
        test_WithdrawPoolsAndCore();
        assertEq(_totals().total, 0, "drained");
        vm.prank(migrator);
        core.setManual(false);
        _wait(8 days);
        vm.prank(keeper);
        core.poke(); // must not revert while empty
        _next();
        usdc.mint(address(core), 20_000e6); // anyone sends USDC straight to the contract
        _settle(12);
        assertGt(_totals().hypeAll, 0, "top-up bought HYPE");
        assertGt(core.navUsd(), 0, "NAV back above zero");
        (uint256 topU,) = core.bidTops();
        assertGt(topU, 0, "USDC bid placed again");
    }

    function test_OnlyMigratorAndOnlyInTestMode() public {
        vm.prank(alice);
        vm.expectRevert(DaffyUSD.NotMigrator.selector);
        core.testWithdraw(alice, 1, 0);
        vm.prank(migrator);
        core.endTestMode();
        vm.prank(migrator);
        vm.expectRevert(DaffyUSD.NotTestMode.selector);
        core.testWithdraw(migrator, 1, 0);
    }
}

address constant LOW = 0x0000000000000000000000000000000000001111;
address constant HIGH = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
address constant HIGH2 = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;
address constant LOW2 = 0x0000000000000000000000000000000000002222;

/// @dev USDC sorts before DAFF, WHYPE after it.
contract DaffyUSDTest is DaffyUSDTests {
    function _usdcAddress() internal pure override returns (address) {
        return LOW;
    }

    function _whypeAddress() internal pure override returns (address) {
        return HIGH;
    }
}

/// @dev The other way round in both pools.
contract DaffyUSDTestFlipped is DaffyUSDTests {
    function _usdcAddress() internal pure override returns (address) {
        return HIGH2;
    }

    function _whypeAddress() internal pure override returns (address) {
        return LOW2;
    }
}

contract DaffyUSDTestModeTest is DaffyUSDTestModeTests {
    function _usdcAddress() internal pure override returns (address) {
        return LOW;
    }

    function _whypeAddress() internal pure override returns (address) {
        return HIGH;
    }
}

/// @notice The borrow tranche on from launch (BORROW_AT_LAUNCH, the deploy default).
abstract contract DaffyUSDBorrowAtLaunchTests is DaffyUSDBase {
    function hcConfig() internal pure override returns (DaffyUSDHyperCore.Config memory c) {
        c = super.hcConfig();
        c.borrowAtLaunch = true;
    }

    function _debt() internal view returns (uint256) {
        return _snap().borrowed;
    }

    function test_SwitchesToPortfolioMarginAfterLaunch() public {
        assertTrue(core.coreState().borrowEnabled, "on from deploy");
        _launch();
        assertTrue(core.coreState().pmSent, "switch sent after launch");
        assertTrue(hl.isPm(address(core)), "portfolio margin on");
        assertGt(_totals().hypeAll, 0, "launch buys still happened");

        _price(18e18); // -55%: three tranches, then the borrow
        _settle(14);
        assertEq(core.coreState().tranchesFired, 3);
        assertGt(_debt(), 0, "borrowed");
        assertFalse(hl.liquidated());
        assertEq(hl.rejected(), 0);
    }

    /// @notice If HyperCore ignores the switch, everything else keeps working.
    function test_NothingBreaksIfPortfolioMarginIsIgnored() public {
        hl.setPmAvailable(false);
        _launch();
        assertTrue(core.coreState().pmSent);
        assertFalse(hl.isPm(address(core)), "switch ignored");
        uint256 hypeAtLaunch = _totals().hypeAll;
        assertGt(hypeAtLaunch, 0, "launch buys happened");

        _price(18e18); // deep dip: tranches buy, the borrow buy fails on HyperCore
        _settle(14);
        assertEq(core.coreState().tranchesFired, 3, "dip tranches fired");
        assertGt(_totals().hypeAll, hypeAtLaunch, "dip buys happened");
        assertEq(_debt(), 0, "nothing borrowed");
        assertFalse(hl.liquidated());

        // exits, refills and upkeep keep working
        uint256 navBefore = core.navUsd();
        _sellTo(alice, false, daff.balanceOf(alice) / 2, 0.3e18);
        _wait(8 days);
        _settle(8);
        assertGe(core.navUsd(), navBefore, "exits below NAV still raise NAV");

        _price(45e18); // a new high: trims still sell
        uint256 hypeBefore = _snap().hype;
        _settle(10);
        assertLt(_snap().hype, hypeBefore, "rally trims still work");
    }
}

contract DaffyUSDBorrowAtLaunchTest is DaffyUSDBorrowAtLaunchTests {
    function _usdcAddress() internal pure override returns (address) {
        return LOW;
    }

    function _whypeAddress() internal pure override returns (address) {
        return HIGH;
    }
}
