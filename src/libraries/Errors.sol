// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Errors
/// @notice Custom errors for the Yield Subsidized Directional Hook
/// @dev Using custom errors for gas efficiency and clear error messages
library Errors {
    // ========== ACCESS CONTROL ERRORS ==========

    /// @notice Thrown when a callback is invoked by an address other than the PoolManager
    error UnauthorizedCaller();

    /// @notice Thrown when an administrative function is called by a non-owner address
    error Unauthorized();

    // ========== POOL REGISTRATION ERRORS ==========

    /// @notice Thrown when attempting to register a pool that is already registered
    /// @param poolId The pool identifier that is already registered
    error PoolAlreadyRegistered(bytes32 poolId);

    /// @notice Thrown when attempting to perform an operation on a pool that is not registered
    /// @param poolId The pool identifier that is not registered
    error PoolNotRegistered(bytes32 poolId);

    // ========== CONFIGURATION ERRORS ==========

    /// @notice Thrown when invalid configuration parameters are provided
    /// @param reason Description of the configuration error
    error InvalidConfiguration(string reason);

    /// @notice Thrown when an oracle address does not implement the required interface
    /// @param oracle The invalid oracle address
    error InvalidOracle(address oracle);

    /// @notice Thrown when a vault address does not implement the required interface
    /// @param vault The invalid vault address
    error InvalidVault(address vault);

    /// @notice Thrown when a vault's underlying asset does not match the expected token
    /// @param vault The vault address
    /// @param expected The expected token address
    /// @param actual The actual underlying asset address
    error VaultAssetMismatch(address vault, address expected, address actual);

    // ========== PAUSE MECHANISM ERRORS ==========

    /// @notice Thrown when attempting to perform a restricted operation on a paused pool
    /// @param poolId The paused pool identifier
    error PoolPaused(bytes32 poolId);

    /// @notice Thrown when attempting to perform a restricted operation on a paused pool
    error Paused();

    /// @notice Thrown when a vault deposit operation fails
    error VaultDepositFailed();

    /// @notice Thrown when attempting to sweep capital below the minimum threshold
    error BelowMinimumThreshold();

    // ========== CAPITAL SWEEP ERRORS ==========

    /// @notice Thrown when attempting to sweep capital below the minimum threshold
    /// @param amount0 The idle amount of token0
    /// @param amount1 The idle amount of token1
    /// @param minThreshold The minimum threshold required
    error BelowMinimumSweepThreshold(uint256 amount0, uint256 amount1, uint256 minThreshold);

    /// @notice Thrown when attempting to sweep capital but no idle capital exists
    error NoIdleCapital();

    /// @notice Thrown when attempting to sweep too soon after the last sweep
    /// @param lastSweepTime The timestamp of the last sweep
    /// @param minInterval The minimum interval required between sweeps
    error SweepTooSoon(uint256 lastSweepTime, uint256 minInterval);

    // ========== CLAIM TOKEN ERRORS ==========

    /// @notice Thrown when attempting to redeem a claim token that doesn't exist
    /// @param claimTokenId The invalid claim token ID
    error InvalidClaimToken(uint256 claimTokenId);

    /// @notice Thrown when attempting to redeem more claim tokens than owned
    /// @param claimTokenId The claim token ID
    /// @param requested The requested amount
    /// @param available The available balance
    error InsufficientClaimBalance(uint256 claimTokenId, uint256 requested, uint256 available);

    /// @notice Thrown when vault withdrawal fails during claim token redemption
    /// @param vault The vault address
    /// @param reason The failure reason
    error VaultWithdrawalFailed(address vault, string reason);

    // ========== SUBSIDY DISTRIBUTION ERRORS ==========

    /// @notice Thrown when subsidy pool has insufficient yield for distribution
    /// @param poolId The pool identifier
    /// @param requested The requested subsidy amount
    /// @param available The available yield balance
    error InsufficientSubsidyYield(bytes32 poolId, uint256 requested, uint256 available);

    // ========== ORACLE ERRORS ==========

    /// @notice Thrown when oracle price data is stale
    /// @param timestamp The price timestamp
    /// @param maxAge The maximum allowed age
    error StaleOraclePrice(uint256 timestamp, uint256 maxAge);

    /// @notice Thrown when oracle price is outside acceptable bounds
    /// @param price The oracle price
    /// @param minPrice The minimum acceptable price
    /// @param maxPrice The maximum acceptable price
    error OraclePriceOutOfBounds(uint256 price, uint256 minPrice, uint256 maxPrice);

    /// @notice Thrown when oracle call fails
    /// @param oracle The oracle address
    error OracleCallFailed(address oracle);

    // ========== ARITHMETIC ERRORS ==========

    /// @notice Thrown when a calculation would result in overflow
    /// @param operation Description of the operation
    error ArithmeticOverflow(string operation);

    /// @notice Thrown when a calculation would result in underflow
    /// @param operation Description of the operation
    error ArithmeticUnderflow(string operation);

    /// @notice Thrown when attempting division by zero
    error DivisionByZero();

    // ========== GENERAL ERRORS ==========

    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided where not allowed
    error ZeroAmount();

    /// @notice Thrown when an invalid parameter value is provided
    /// @param parameter The parameter name
    /// @param value The invalid value
    error InvalidParameter(string parameter, uint256 value);
}
