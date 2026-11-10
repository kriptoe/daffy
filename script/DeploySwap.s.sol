// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DaffyUSD} from "../src/DaffyUSD.sol";
import {DaffySwap} from "../src/DaffySwap.sol";

/// @notice Deploys DaffySwap, the router the deposit page's Trade tab uses, for an existing DaffyUSD.
///         Needs the pools to exist (they are created with DaffyUSD), so it can be deployed any time.
///
/// Required env: PRIVATE_KEY, CORE (the DaffyUSD address)
/// Usage: forge script script/DeploySwap.s.sol --rpc-url $RPC --broadcast
contract DeploySwap is Script {
    function run() external returns (DaffySwap router) {
        DaffyUSD core = DaffyUSD(payable(vm.envAddress("CORE")));
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        router = new DaffySwap(core);
        vm.stopBroadcast();
        console2.log("DaffySwap  ", address(router));
        console2.log("NEXT: set DEFAULT_SWAP in frontend/index.html, or open the page with &swap=", address(router));
    }
}
