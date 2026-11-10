// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Wrapped HYPE on HyperEVM (WETH9-style), 0x5555555555555555555555555555555555555555.
interface IWHYPE is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice Minimal Uniswap V3 factory surface (HyperSwap V3 is a V3 fork).
interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}
