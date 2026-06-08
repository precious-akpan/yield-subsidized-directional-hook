// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Constants
/// @notice System-wide constants for the Yield Subsidized Directional Hook
/// @dev Centralized constant definitions for maintainability
library Constants {
    // ========== ORACLE CONSTANTS ==========

    /// @notice Maximum age of oracle price data before considered stale (5 minutes)
    uint256 internal constant ORACLE_STALENESS_THRESHOLD = 5 minutes;

    /// @notice Maximum price deviation from pool price (50% = 5000 bps)
    /// @dev Used to validate oracle prices are within reasonable bounds
    uint256 internal constant MAX_ORACLE_DEVIATION_BPS = 5000;

    /// @notice Gas limit for external oracle calls to prevent griefing
    uint256 internal constant ORACLE_GAS_LIMIT = 50_000;

    // ========== CAPITAL SWEEP CONSTANTS ==========

    /// @notice Minimum amount of idle capital required to trigger a sweep (0.1 ETH equivalent)
    /// @dev Prevents spam sweeps with tiny amounts
    uint256 internal constant MIN_SWEEP_THRESHOLD = 0.1 ether;

    /// @notice Minimum interval between consecutive sweeps (1 hour)
    /// @dev Prevents excessive sweep operations on the same pool
    uint256 internal constant MIN_SWEEP_INTERVAL = 1 hours;

    /// @notice Gas limit for external vault deposit calls
    uint256 internal constant VAULT_DEPOSIT_GAS_LIMIT = 150_000;

    /// @notice Gas limit for external vault withdrawal calls
    uint256 internal constant VAULT_WITHDRAW_GAS_LIMIT = 150_000;

    // ========== FEE SCALING CONSTANTS ==========

    /// @notice Basis points denominator (100% = 10000 bps)
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Default baseline fee in basis points (0.3% = 30 bps)
    uint24 internal constant DEFAULT_BASE_FEE_BPS = 30;

    /// @notice Default maximum fee multiplier (3x = 30000 bps)
    uint24 internal constant DEFAULT_MAX_FEE_MULTIPLIER = 30_000;

    /// @notice Default price deviation threshold for toxic flow (0.5% = 50 bps)
    uint24 internal constant DEFAULT_DEVIATION_THRESHOLD_BPS = 50;

    /// @notice Maximum allowed fee multiplier cap (10x = 100000 bps)
    uint24 internal constant MAX_FEE_MULTIPLIER_CAP = 100_000;

    // ========== PRICE PRECISION CONSTANTS ==========

    /// @notice Precision for price calculations (18 decimals)
    uint256 internal constant PRICE_PRECISION = 1e18;

    /// @notice Q96 precision for sqrtPriceX96 conversions
    uint256 internal constant Q96 = 2 ** 96;

    // ========== IDLE CAPITAL DETECTION CONSTANTS ==========

    /// @notice Minimum idle capital threshold for event emission (0.1 ETH equivalent)
    uint256 internal constant IDLE_CAPITAL_EVENT_THRESHOLD = 0.1 ether;

    // ========== ERC-1155 CLAIM TOKEN CONSTANTS ==========

    /// @notice Token index for token0 claim tokens
    uint8 internal constant TOKEN0_INDEX = 0;

    /// @notice Token index for token1 claim tokens
    uint8 internal constant TOKEN1_INDEX = 1;

    // ========== REENTRANCY GUARD CONSTANTS ==========

    /// @notice Unlocked state for reentrancy guard
    uint256 internal constant NOT_ENTERED = 1;

    /// @notice Locked state for reentrancy guard
    uint256 internal constant ENTERED = 2;
}
