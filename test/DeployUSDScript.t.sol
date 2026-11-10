// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {DaffyUSDBase} from "./DaffyUSDBase.t.sol";
import {DaffyUSD} from "../src/DaffyUSD.sol";
import {DeployUSD} from "../script/DeployUSD.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The deploy script's settings build a working core, and the deploy fits a big block.
contract DeployUSDScriptTest is DaffyUSDBase {
    function _usdcAddress() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001111);
    }

    function _whypeAddress() internal pure override returns (address) {
        return address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
    }

    /// @notice forge script simulates locally, where HyperCore precompiles don't exist: the deploy
    ///         itself must not read any.
    function test_DeployNeedsNoPrecompiles() public {
        DeployUSD script = new DeployUSD();
        DaffyUSD.Params memory p = script.params(10 minutes, 25_000);
        address factory = deployCode("out/UniswapV3Factory.sol/UniswapV3Factory.json");
        uint160[5] memory pre = [uint160(0x801), 0x807, 0x810, 0x811, 0x813];
        for (uint256 i; i < pre.length; i++) vm.etch(address(pre[i]), "");
        new DaffyUSD(p, address(usdc), address(whype), address(cdw), hcConfig(), factory, FEE, migrator);
    }

    function test_ScriptParamsDeployAndLaunch() public {
        DeployUSD script = new DeployUSD();
        DaffyUSD.Params memory p = script.params(10 minutes, 25_000);
        p.testMode = true;
        address factory = deployCode("out/UniswapV3Factory.sol/UniswapV3Factory.json");
        uint256 g = gasleft();
        DaffyUSD c = new DaffyUSD(p, address(usdc), address(whype), address(cdw), hcConfig(), factory, FEE, migrator);
        uint256 used = g - gasleft();
        console2.log("deploy gas (core + token + 2 pools)", used);
        assertLt(used, 25_000_000, "fits a 30M big block with room");
        hl.setExists(address(c), true);
        vm.startPrank(alice);
        usdc.approve(address(c), type(uint256).max);
        c.deposit(1_000e6);
        vm.stopPrank();
        vm.prank(migrator);
        c.finalizeLaunch();
        assertTrue(c.launched());
    }
}
