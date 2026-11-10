// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {DaffyUSD} from "./DaffyUSD.sol";
import {DaffyUSDPools} from "./libraries/DaffyUSDPools.sol";
import {IWHYPE} from "./interfaces/IExternal.sol";

/// @title DaffySwap - buy and sell DAFF straight against Daffy's two pools
/// @notice A small router so a front end can trade DAFF without any DEX website. It talks to the
///         DAFF/USDC and DAFF/WHYPE pools directly, takes native HYPE in and pays native HYPE out,
///         and holds nothing between calls. No owner, no fees of its own (the pool fee goes to the
///         pool's liquidity, mostly the treasury).
///
///         Price guard: a swap never goes past the edge of the treasury's own positions (the top of
///         the ask on a buy, the bottom of the bid on a sell). A buy bigger than the ask, or a sell
///         bigger than the bid, fills what it can there and the rest stays with the trader, so the
///         pool price can't be pushed into empty space. `minOut` protects against the rest.
///
///         Approvals: USDC (buys) or DAFF (sells) to this contract, for the amount you trade.
contract DaffySwap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    DaffyUSD public immutable core;
    IERC20 public immutable daff;
    IERC20 public immutable usdc;
    IWHYPE public immutable whype;
    IUniswapV3Pool public immutable poolUsdc;
    IUniswapV3Pool public immutable poolHype;
    bool public immutable daffIsToken0U;
    bool public immutable daffIsToken0H;

    address private activePool; // the pool allowed to call back, set only during a swap
    address private payer; // who pays in the callback (this contract for native HYPE)
    bool private quoting; // callback reverts with the amounts instead of paying

    event Swapped(address indexed trader, bool usdcPool, bool buying, uint256 amountIn, uint256 amountOut);

    error Expired();
    error ZeroAmount();
    error TooLittleOut(uint256 out, uint256 minOut);
    error NoLiquidityInRange();
    error NotPool();
    error HypeSendFailed();

    constructor(DaffyUSD core_) {
        core = core_;
        daff = IERC20(address(core_.token()));
        usdc = core_.usdc();
        whype = core_.whype();
        poolUsdc = core_.poolUsdc();
        poolHype = core_.poolHype();
        daffIsToken0U = core_.daffIsToken0U();
        daffIsToken0H = core_.daffIsToken0H();
    }

    receive() external payable {
        if (msg.sender != address(whype)) revert NotPool();
    }

    // ------------------------------------------------------------------ trades

    /// @notice Spend up to `usdcIn` USDC on DAFF. Returns the DAFF bought and the USDC spent.
    function buyWithUsdc(uint256 usdcIn, uint256 minDaff, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 daffOut, uint256 usdcUsed)
    {
        _checks(usdcIn, deadline);
        (daffOut, usdcUsed) = _swap(true, true, usdcIn, msg.sender, to);
        if (daffOut < minDaff) revert TooLittleOut(daffOut, minDaff);
        emit Swapped(msg.sender, true, true, usdcUsed, daffOut);
    }

    /// @notice Spend the HYPE sent (native) on DAFF. Any HYPE the pool didn't take comes back.
    function buyWithHype(uint256 minDaff, address to, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 daffOut, uint256 hypeUsed)
    {
        _checks(msg.value, deadline);
        whype.deposit{value: msg.value}();
        (daffOut, hypeUsed) = _swap(false, true, msg.value, address(this), to);
        if (daffOut < minDaff) revert TooLittleOut(daffOut, minDaff);
        if (msg.value > hypeUsed) _sendHype(msg.sender, msg.value - hypeUsed);
        emit Swapped(msg.sender, false, true, hypeUsed, daffOut);
    }

    /// @notice Sell up to `daffIn` DAFF for USDC.
    function sellForUsdc(uint256 daffIn, uint256 minUsdc, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcOut, uint256 daffUsed)
    {
        _checks(daffIn, deadline);
        (usdcOut, daffUsed) = _swap(true, false, daffIn, msg.sender, to);
        if (usdcOut < minUsdc) revert TooLittleOut(usdcOut, minUsdc);
        emit Swapped(msg.sender, true, false, daffUsed, usdcOut);
    }

    /// @notice Sell up to `daffIn` DAFF for native HYPE.
    function sellForHype(uint256 daffIn, uint256 minHype, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 hypeOut, uint256 daffUsed)
    {
        _checks(daffIn, deadline);
        (hypeOut, daffUsed) = _swap(false, false, daffIn, msg.sender, address(this));
        if (hypeOut < minHype) revert TooLittleOut(hypeOut, minHype);
        _sendHype(to, hypeOut);
        emit Swapped(msg.sender, false, false, daffUsed, hypeOut);
    }

    /// @notice What a trade would give now: (amount out, amount of the input used). Not a view (it
    ///         runs the swap and undoes it), so call it with eth_call / staticCall.
    function quote(bool usdcPool, bool buying, uint256 amountIn)
        external
        nonReentrant
        returns (uint256 amountOut, uint256 amountUsed)
    {
        if (amountIn == 0) revert ZeroAmount();
        quoting = true;
        IUniswapV3Pool pool = usdcPool ? poolUsdc : poolHype;
        bool zeroForOne = _zeroForOne(usdcPool, buying);
        uint160 limit = _limit(usdcPool, buying, zeroForOne);
        activePool = address(pool);
        try pool.swap(address(this), zeroForOne, int256(amountIn), limit, "") {
            revert NoLiquidityInRange(); // unreachable: the callback always reverts while quoting
        } catch (bytes memory reason) {
            if (reason.length != 64) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
            (int256 a0, int256 a1) = abi.decode(reason, (int256, int256));
            (amountOut, amountUsed) = _amounts(zeroForOne, a0, a1);
        }
        activePool = address(0);
        quoting = false;
    }

    // ------------------------------------------------------------------ pool callbacks

    function hyperswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        _callback(a0, a1);
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        _callback(a0, a1);
    }

    function _callback(int256 a0, int256 a1) private {
        if (msg.sender != activePool || activePool == address(0)) revert NotPool();
        if (quoting) {
            assembly {
                let p := mload(0x40)
                mstore(p, a0)
                mstore(add(p, 32), a1)
                revert(p, 64)
            }
        }
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        (IERC20 token, uint256 amount) =
            a0 > 0 ? (IERC20(pool.token0()), uint256(a0)) : (IERC20(pool.token1()), uint256(a1));
        if (payer == address(this)) token.safeTransfer(msg.sender, amount);
        else token.safeTransferFrom(payer, msg.sender, amount);
    }

    // ------------------------------------------------------------------ internals

    function _swap(bool usdcPool, bool buying, uint256 amountIn, address from, address to)
        private
        returns (uint256 amountOut, uint256 amountUsed)
    {
        IUniswapV3Pool pool = usdcPool ? poolUsdc : poolHype;
        bool zeroForOne = _zeroForOne(usdcPool, buying);
        uint160 limit = _limit(usdcPool, buying, zeroForOne);
        (activePool, payer) = (address(pool), from);
        (int256 a0, int256 a1) = pool.swap(to, zeroForOne, int256(amountIn), limit, "");
        (activePool, payer) = (address(0), address(0));
        (amountOut, amountUsed) = _amounts(zeroForOne, a0, a1);
        if (amountOut == 0) revert NoLiquidityInRange();
    }

    /// @dev Buying DAFF sends the quote token in: token1 when DAFF is token0, else token0.
    function _zeroForOne(bool usdcPool, bool buying) private view returns (bool) {
        bool d0 = usdcPool ? daffIsToken0U : daffIsToken0H;
        return buying ? !d0 : d0;
    }

    /// @dev The far edge of the treasury's ask (buys) or bid (sells), as a sqrt price limit.
    function _limit(bool usdcPool, bool buying, bool zeroForOne) private view returns (uint160 limit) {
        DaffyUSDPools.Book memory b = core.book(usdcPool);
        bool d0 = usdcPool ? daffIsToken0U : daffIsToken0H;
        int24 edge = buying ? (d0 ? b.askHi : b.askLo) : (d0 ? b.bidLo : b.bidHi);
        bool unset = buying ? b.askLo == b.askHi : b.bidLo == b.bidHi;
        if (unset) limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        else limit = TickMath.getSqrtRatioAtTick(edge);
        (uint160 sqrtP,,,,,,) = (usdcPool ? poolUsdc : poolHype).slot0();
        // the price is already at or past the edge: nothing left to trade inside the book
        if (zeroForOne ? limit >= sqrtP : limit <= sqrtP) revert NoLiquidityInRange();
    }

    function _amounts(bool zeroForOne, int256 a0, int256 a1) private pure returns (uint256 out, uint256 used) {
        (int256 inD, int256 outD) = zeroForOne ? (a0, a1) : (a1, a0);
        used = uint256(inD);
        out = uint256(-outD);
    }

    function _checks(uint256 amount, uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (amount == 0) revert ZeroAmount();
    }

    function _sendHype(address to, uint256 amount) private {
        whype.withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert HypeSendFailed();
    }
}
