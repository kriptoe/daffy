// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

/// @notice WETH9-style wrapped HYPE.
contract MockWHYPE is ERC20 {
    constructor() ERC20("Wrapped HYPE", "WHYPE") {}

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send failed");
    }

    receive() external payable {
        deposit();
    }
}

/// @notice Swaps and LPs on a V3 pool for tests; pulls tokens from the caller in callbacks.
contract PoolActor {
    IUniswapV3Pool public immutable pool;
    address internal payer;

    constructor(IUniswapV3Pool pool_) {
        pool = pool_;
    }

    /// @notice Exact-input swap of `tokenIn`, no price limit unless given.
    function swap(address tokenIn, uint256 amountIn, uint160 limit) external returns (uint256 amountOut) {
        payer = msg.sender;
        bool zeroForOne = tokenIn == pool.token0();
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        (int256 a0, int256 a1) = pool.swap(msg.sender, zeroForOne, int256(amountIn), limit, "");
        amountOut = uint256(-(zeroForOne ? a1 : a0));
    }

    function addLiquidity(int24 lo, int24 hi, uint128 liquidity) external {
        payer = msg.sender;
        pool.mint(msg.sender, lo, hi, liquidity, "");
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        require(msg.sender == address(pool));
        if (a0 > 0) IERC20(pool.token0()).transferFrom(payer, msg.sender, uint256(a0));
        if (a1 > 0) IERC20(pool.token1()).transferFrom(payer, msg.sender, uint256(a1));
    }

    function uniswapV3MintCallback(uint256 a0, uint256 a1, bytes calldata) external {
        require(msg.sender == address(pool));
        if (a0 > 0) IERC20(pool.token0()).transferFrom(payer, msg.sender, a0);
        if (a1 > 0) IERC20(pool.token1()).transferFrom(payer, msg.sender, a1);
    }
}

/// @notice Native USDC on HyperEVM (6 decimals); tests and the HyperCore mock mint freely.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IUsdcQueue {
    function queueUsdc(address user, uint256 amount8) external;
}

/// @notice Circle's CoreDepositWallet: pulls USDC and credits the caller on HyperCore next block.
contract MockCoreDepositWallet {
    IERC20 public immutable usdc;
    IUsdcQueue public immutable core;

    constructor(IERC20 usdc_, IUsdcQueue core_) {
        usdc = usdc_;
        core = core_;
    }

    function deposit(uint256 amount, uint32 destinationDex) external {
        require(destinationDex == type(uint32).max, "spot only in this mock");
        usdc.transferFrom(msg.sender, address(this), amount);
        core.queueUsdc(msg.sender, amount * 100);
    }
}

/// @notice Receives a DaffyUSD migration.
contract MockSuccessorUSD {
    bool public accepted;

    function acceptMigration() external {
        accepted = true;
    }

    receive() external payable {}
}
