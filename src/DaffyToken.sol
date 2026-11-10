// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Daffy ($DAFFY) - Degenerate Assistance Fund Fund
/// @notice A plain ERC-20 that never moves or changes. It stores one address, the current core,
///         which is the only contract allowed to mint and burn. A migration points the token at a
///         new core; holders never need to swap tokens.
/// @dev Unofficial parody, not affiliated with Hyperliquid.
contract DaffyToken is ERC20 {
    /// @notice The only address allowed to mint, burn, enable transfers and hand over to a successor.
    address public core;

    /// @notice User-to-user transfers are locked until the launch is finalized, so nobody can
    ///         trade or LP DAFFY before the protocol pool is seeded. One-way switch.
    bool public transfersEnabled;

    event CoreChanged(address indexed oldCore, address indexed newCore);
    event TransfersEnabled();

    error NotCore();
    error TransfersLocked();
    error ZeroAddress();

    modifier onlyCore() {
        if (msg.sender != core) revert NotCore();
        _;
    }

    constructor(address core_) ERC20("Daffy", "DAFFY") {
        if (core_ == address(0)) revert ZeroAddress();
        core = core_;
        emit CoreChanged(address(0), core_);
    }

    function mint(address to, uint256 amount) external onlyCore {
        _mint(to, amount);
    }

    /// @notice Burns from the core's own balance only. A core can never burn tokens straight out of
    ///         a holder's wallet; holders transfer to the core (redeem, refund) first.
    function burn(uint256 amount) external onlyCore {
        _burn(msg.sender, amount);
    }

    function enableTransfers() external onlyCore {
        if (!transfersEnabled) {
            transfersEnabled = true;
            emit TransfersEnabled();
        }
    }

    /// @notice Hand the token to a new core. Only the current core can call this, and the core
    ///         only does so at the end of a timelocked migration.
    function setCore(address newCore) external onlyCore {
        if (newCore == address(0)) revert ZeroAddress();
        emit CoreChanged(core, newCore);
        core = newCore;
    }

    function _update(address from, address to, uint256 value) internal override {
        // Mints and burns (from or to zero) and anything touching the core are always allowed.
        if (!transfersEnabled && from != address(0) && to != address(0) && from != core && to != core) {
            revert TransfersLocked();
        }
        super._update(from, to, value);
    }
}
