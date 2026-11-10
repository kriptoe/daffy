// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DaffyUSD} from "../src/DaffyUSD.sol";
import {DaffyUSDPools} from "../src/libraries/DaffyUSDPools.sol";
import {DaffyUSDHyperCore} from "../src/libraries/DaffyUSDHyperCore.sol";

/// @notice Deploys Daffy v2 (the USDC model): the linked libraries, then DaffyUSD, which deploys
///         DaffyToken and creates both HyperSwap pools (DAFF/USDC at $1, DAFF/WHYPE at $1 of HYPE).
///
/// Required env:
///   PRIVATE_KEY    deployer key (needs HyperEVM big blocks enabled: the deploy is ~20M gas)
///   MIGRATOR       your address: migrator role and, in test mode, the test controls
/// Optional env (mainnet defaults):
///   TEST_MODE      true = migrator gets testWithdraw / testCoreAction / early launch etc.
///   LAUNCH_MINUTES deposit window in minutes (else LAUNCH_DAYS, default 7)
///   MIN_LAUNCH_USDC   never launches below this many USDC, default 100000
///   EARLY_LAUNCH_USDC launches before the window ends once this many USDC are in, default 10000000
///   BORROW_AT_LAUNCH  borrow tranche on from launch (portfolio margin after launch), default true
///   ORDER_SETTLE_SECS seconds to wait after a HyperCore order before the next step, default 20
///   PM_CODE        CoreWriter abstraction code for portfolio margin (borrow tranche), default 3
///   V3_FACTORY     HyperSwap V3 factory, default 0xB1c0fa0B789320044A6F623cFe5eBda9562602E3
///   USDC           native USDC, default 0xb88339CB7199b77E23DB6E890353E22632Ba630f
///   DEPOSIT_WALLET Circle's CoreDepositWallet, default 0x6b9e773128f453f5c2c60935ee2de2cbc5390a24
///   WHYPE          default 0x5555555555555555555555555555555555555555
///   HYPE_TOKEN 150, USDC_TOKEN 0, PERP_INDEX 159, SPOT_ASSET 10107, SZ_DECIMALS 2, POOL_FEE 3000 (0.3%)
///   MAX_TRADE_USD  largest single HYPE order in USD, default 25000
///
/// Usage:
///   forge script script/DeployUSD.s.sol --rpc-url $RPC --broadcast --slow
contract DeployUSD is Script {
    function params(uint256 launchDuration, uint256 maxTradeUsd) public pure returns (DaffyUSD.Params memory p) {
        p.launchDuration = launchDuration;
        p.minLaunchUsdc = 100_000e6; // never launches below $100k
        p.earlyLaunchUsdc = 10_000_000e6; // launches early once $10M is in
        p.hypeBps = 7500; // 75% HYPE at launch (55% held + 20% as the DAFF/HYPE bid)
        p.usdcBidBps = 500; // 5% USDC bid (the HYPE bid takes 20%: it can't be overpaid in a dump)
        p.askBps = 1000; // each pool offers 10% of circulating DAFF at 2x-10x NAV
        p.recenterMoveBps = 500; // re-place a pool's positions when NAV moves 5%...
        p.recenterInterval = 7 days; // ...or weekly
        p.incomingHypeBps = 7500; // 75% of new USDC buys HYPE
        p.feeCollectInterval = 1 days;
        p.rewardInterval = 10 minutes;
        p.pokeReward = 1e6; // 1 USDC per useful upkeep, from fees and premium sales
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
            maxTradeUsd: maxTradeUsd * 1e18,
            borrowBps: 2000, // borrow tranche (BORROW_AT_LAUNCH, or setBorrowing(true)): 20% of the HYPE's value
            deleverageBps: 5000, // debt over 50% of the HYPE -> sell back to 40%
            deleverageTargetBps: 4000,
            dipStepBps: 500, // deeper dips after bigger runs: +5 points per +50% above launch...
            dipStepRiseBps: 5000,
            dipMaxExtraBps: 1500 // ...at most +15 points
        });
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address migrator = vm.envAddress("MIGRATOR");
        address factory = vm.envOr("V3_FACTORY", address(0xB1c0fa0B789320044A6F623cFe5eBda9562602E3));
        address usdc = vm.envOr("USDC", address(0xb88339CB7199b77E23DB6E890353E22632Ba630f));
        address cdw = vm.envOr("DEPOSIT_WALLET", address(0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24));
        address whype = vm.envOr("WHYPE", address(0x5555555555555555555555555555555555555555));

        DaffyUSDHyperCore.Config memory hc;
        hc.hypeToken = uint64(vm.envOr("HYPE_TOKEN", uint256(150)));
        hc.usdcToken = uint64(vm.envOr("USDC_TOKEN", uint256(0)));
        hc.perpIndex = uint32(vm.envOr("PERP_INDEX", uint256(159)));
        hc.spotAsset = uint32(vm.envOr("SPOT_ASSET", uint256(10107)));
        hc.perpSzDecimals = uint8(vm.envOr("SZ_DECIMALS", uint256(2)));
        hc.spotSzDecimals = hc.perpSzDecimals;
        hc.pmAbstraction = uint8(vm.envOr("PM_CODE", uint256(3)));
        hc.borrowAtLaunch = vm.envOr("BORROW_AT_LAUNCH", true);
        hc.orderSettleSecs = uint32(vm.envOr("ORDER_SETTLE_SECS", uint256(20)));
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(3_000)));

        uint256 launchMinutes = vm.envOr("LAUNCH_MINUTES", uint256(0));
        uint256 duration = launchMinutes > 0 ? launchMinutes * 1 minutes : vm.envOr("LAUNCH_DAYS", uint256(7)) * 1 days;
        DaffyUSD.Params memory p = params(duration, vm.envOr("MAX_TRADE_USD", uint256(25_000)));
        p.testMode = vm.envOr("TEST_MODE", false);
        p.minLaunchUsdc = vm.envOr("MIN_LAUNCH_USDC", uint256(100_000)) * 1e6;
        p.earlyLaunchUsdc = vm.envOr("EARLY_LAUNCH_USDC", uint256(10_000_000)) * 1e6;

        vm.startBroadcast(pk);
        DaffyUSD core = new DaffyUSD(p, usdc, whype, cdw, hc, factory, fee, migrator);
        vm.stopBroadcast();

        console2.log("DaffyUSD   ", address(core));
        console2.log("DaffyToken ", address(core.token()));
        console2.log("DAFF/USDC  ", address(core.poolUsdc()));
        console2.log("DAFF/WHYPE ", address(core.poolHype()));
        console2.log("Test mode:", core.testMode());
        console2.log("Deposits close at", core.launchEnd());
        console2.log("NEXT: send DaffyUSD a few USDC on HyperCore to activate its account");
    }
}
