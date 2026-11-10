// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {DaffyUSD} from "../src/DaffyUSD.sol";
import {DaffyToken} from "../src/DaffyToken.sol";
import {DaffyMath} from "../src/libraries/DaffyMath.sol";
import {DaffyUSDPools} from "../src/libraries/DaffyUSDPools.sol";
import {DaffyUSDHyperCore} from "../src/libraries/DaffyUSDHyperCore.sol";
import {MockWHYPE, PoolActor, MockUSDC, MockCoreDepositWallet, IUsdcQueue} from "./mocks/Mocks.sol";
import {MockHyperCore, MockCoreWriter, MockHypeSystem, MockPrecompile} from "./mocks/MockHyperCore.sol";

/// @notice Shared v2 setup: real Uniswap V3 factory and two pools, mock USDC + CoreDepositWallet,
///         mock WHYPE, and the HyperCore mock (spot, lending, bridges, precompiles).
abstract contract DaffyUSDBase is Test {
    DaffyUSD core;
    DaffyToken daff;
    MockUSDC usdc;
    MockWHYPE whype;
    MockCoreDepositWallet cdw;
    IUniswapV3Pool poolU;
    IUniswapV3Pool poolH;
    PoolActor actorU;
    PoolActor actorH;
    MockHyperCore hl;

    uint256 constant LAUNCH_PRICE = 40e18;
    uint24 constant FEE = 3_000; // 0.3%, the deploy default

    address migrator = makeAddr("migrator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address whale = makeAddr("whale");
    address keeper = makeAddr("keeper");

    /// @dev Fixed token addresses, low or high, so subclasses cover both token orders in both pools.
    function _usdcAddress() internal view virtual returns (address);
    function _whypeAddress() internal view virtual returns (address);

    function defaultParams() internal pure virtual returns (DaffyUSD.Params memory p) {
        p.launchDuration = 7 days;
        p.minLaunchUsdc = 100_000e6;
        p.earlyLaunchUsdc = 10_000_000e6;
        p.hypeBps = 7500; // 75% HYPE at launch (55% held + 20% as the DAFF/HYPE bid)
        p.usdcBidBps = 500; // 5% USDC bid (the HYPE bid takes 20%: it can't be overpaid in a dump)
        p.askBps = 1000;
        p.recenterMoveBps = 500; // re-place a pool's positions when NAV moves 5%...
        p.recenterInterval = 7 days;
        p.incomingHypeBps = 7500; // 75% of new USDC buys HYPE
        p.feeCollectInterval = 1 days;
        p.rewardInterval = 10 minutes;
        p.pokeReward = 1e6;
        p.ranges = DaffyUSDPools.Ranges(0.6e18, 0.8e18, 2e18, 10e18);
        p.rules = DaffyUSDHyperCore.Rules({
            dip1Bps: 2500,
            dip2Bps: 4000,
            dip3Bps: 5500,
            trimShareBps: 8500, // trim when HYPE is over 85% of the treasury...
            trimTargetBps: 7500, // ...back down to 75%
            trimNearHighBps: 9000,
            hypeBidBps: 2000,
            refillCapBps: 500,
            slippageBps: 100,
            refillWindow: 7 days,
            minTradeUsd: 10e18,
            maxTradeUsd: 50_000e18,
            borrowBps: 2000,
            deleverageBps: 5000,
            deleverageTargetBps: 4000,
            dipStepBps: 500, // deeper dips after bigger runs: +5 points per +50% above launch...
            dipStepRiseBps: 5000,
            dipMaxExtraBps: 1500 // ...at most +15 points
        });
    }

    function hcConfig() internal pure virtual returns (DaffyUSDHyperCore.Config memory c) {
        c.hypeToken = 150;
        c.usdcToken = 0;
        c.perpIndex = 159;
        c.spotAsset = 10107;
        c.perpSzDecimals = 2;
        c.spotSzDecimals = 2;
        c.pmAbstraction = 3;
    }

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        _installHyperCore();
        deployCodeTo("Mocks.sol:MockWHYPE", _whypeAddress());
        whype = MockWHYPE(payable(_whypeAddress()));
        deployCodeTo("Mocks.sol:MockUSDC", _usdcAddress());
        usdc = MockUSDC(_usdcAddress());
        hl.setEvmUsdc(address(usdc));
        cdw = new MockCoreDepositWallet(IERC20(address(usdc)), IUsdcQueue(address(hl)));
        address factory = deployCode("out/UniswapV3Factory.sol/UniswapV3Factory.json");

        core = new DaffyUSD(
            defaultParams(), address(usdc), address(whype), address(cdw), hcConfig(), factory, FEE, migrator
        );
        hl.setExists(address(core), true); // mainnet: send it a little USDC on HyperCore first
        daff = core.token();
        poolU = core.poolUsdc();
        poolH = core.poolHype();
        actorU = new PoolActor(poolU);
        actorH = new PoolActor(poolH);

        address[6] memory users = [alice, bob, carol, whale, keeper, address(this)];
        for (uint256 i; i < users.length; i++) {
            vm.deal(users[i], 1_000_000 ether);
            usdc.mint(users[i], 10_000_000e6);
            vm.startPrank(users[i]);
            whype.deposit{value: 100_000 ether}();
            usdc.approve(address(core), type(uint256).max);
            usdc.approve(address(actorU), type(uint256).max);
            whype.approve(address(actorH), type(uint256).max);
            daff.approve(address(actorU), type(uint256).max);
            daff.approve(address(actorH), type(uint256).max);
            daff.approve(address(core), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------ helpers

    /// @dev $100k of deposits, launch, then upkeep until the treasury is allocated.
    function _launch() internal {
        vm.prank(alice);
        core.deposit(60_000e6);
        vm.prank(bob);
        core.deposit(30_000e6);
        vm.prank(carol);
        core.deposit(10_000e6);
        vm.warp(core.launchEnd());
        core.finalizeLaunch();
        _next();
        _settle(12);
    }

    /// @dev `n` rounds of: upkeep, then let HyperCore apply it.
    function _settle(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.prank(keeper);
            core.poke();
            _next();
        }
    }

    function _price(uint256 usd) internal {
        hl.setOracle(usd);
    }

    function _installHyperCore() internal {
        hl = new MockHyperCore();
        vm.deal(address(hl), 10_000_000 ether);
        vm.etch(0x3333333333333333333333333333333333333333, address(new MockCoreWriter(hl)).code);
        vm.etch(0x2222222222222222222222222222222222222222, address(new MockHypeSystem(hl)).code);
        address pre = address(new MockPrecompile(hl));
        uint160[5] memory addrs = [uint160(0x801), 0x807, 0x810, 0x811, 0x813];
        for (uint256 i; i < addrs.length; i++) vm.etch(address(addrs[i]), pre.code);
        hl.setOracle(LAUNCH_PRICE);
    }

    /// @dev Next EVM block, then HyperCore runs this block's actions (live clock, see v1 base).
    function _next() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        hl.nextBlock();
    }

    function _wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        _next();
    }

    function _totals() internal view returns (DaffyUSDHyperCore.Totals memory) {
        return core.totals();
    }

    function _snap() internal view returns (DaffyUSDHyperCore.Snapshot memory) {
        return core.coreSnapshot();
    }

    /// @dev Sell `amount` DAFF into a pool with no price limit; returns what came out.
    function _sell(address who, bool usdcPool, uint256 amount) internal returns (uint256 out) {
        vm.prank(who);
        out = (usdcPool ? actorU : actorH).swap(address(daff), amount, 0);
    }

    /// @dev Buy DAFF with `amount` of the pool's quote token.
    function _buy(address who, bool usdcPool, uint256 amount) internal returns (uint256 out) {
        vm.prank(who);
        out = (usdcPool ? actorU : actorH).swap(usdcPool ? address(usdc) : address(whype), amount, 0);
    }

    /// @dev Sell up to `amount` DAFF, stopping at `navFrac` x NAV (WAD) in that pool's units.
    function _sellTo(address who, bool usdcPool, uint256 amount, uint256 navFrac) internal returns (uint256 out) {
        uint256 nav = core.navUsd();
        uint256 px = _snap().px;
        uint256 target = usdcPool ? (nav * navFrac) / 1e18 / 1e12 : (((nav * 1e18) / px) * navFrac) / 1e18;
        bool d0 = usdcPool ? core.daffIsToken0U() : core.daffIsToken0H();
        uint160 limit = DaffyMath.sqrtFromPrice(target, d0); // before the prank: it's an external call
        vm.prank(who);
        out = (usdcPool ? actorU : actorH).swap(address(daff), amount, limit);
    }

    /// @dev Buy DAFF with up to `amount` quote, stopping at `navMult` x NAV.
    function _buyTo(address who, bool usdcPool, uint256 amount, uint256 navMult) internal returns (uint256 out) {
        uint256 nav = core.navUsd();
        uint256 px = _snap().px;
        uint256 target = usdcPool ? (nav * navMult) / 1e18 / 1e12 : (((nav * 1e18) / px) * navMult) / 1e18;
        bool d0 = usdcPool ? core.daffIsToken0U() : core.daffIsToken0H();
        uint160 limit = DaffyMath.sqrtFromPrice(target, d0);
        vm.prank(who);
        out = (usdcPool ? actorU : actorH).swap(usdcPool ? address(usdc) : address(whype), amount, limit);
    }

    function _share(uint256 part, uint256 whole) internal pure returns (uint256) {
        return whole == 0 ? 0 : (part * 10_000) / whole;
    }
}
