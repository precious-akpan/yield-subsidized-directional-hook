// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title DataTypes
/// @notice Core data structures for the Yield Subsidized Directional Hook
/// @dev Contains all structs used across the hook implementation
library DataTypes {
    // ========== POOL CONFIGURATION ==========

    /// @notice Configuration parameters for a registered pool
    /// @dev Stored per PoolId in the hook contract
    struct PoolConfig {
        address oracle; // Price oracle for directional fee calculation
        address vault0; // Yield vault for token0
        address vault1; // Yield vault for token1
        uint24 baseFeeBps; // Baseline fee in basis points (e.g., 30 = 0.3%)
        uint24 maxFeeMultiplier; // Maximum fee multiplier (e.g., 300 = 3x)
        uint24 deviationThresholdBps; // Price deviation threshold for toxic flow classification
        bool isPaused; // Emergency pause flag
    }

    // ========== SUBSIDY POOL ACCOUNTING ==========

    /// @notice Accumulates yield for IL compensation per pool
    /// @dev Tracks principal and yield separately for accurate accounting
    struct SubsidyPool {
        uint256 totalToken0Yield; // Accumulated yield in token0
        uint256 totalToken1Yield; // Accumulated yield in token1
        uint256 totalToken0Principal; // Principal locked in vault for token0
        uint256 totalToken1Principal; // Principal locked in vault for token1
        uint256 vaultShares0; // Vault shares held for token0
        uint256 vaultShares1; // Vault shares held for token1
    }

    // ========== LP POSITION TRACKING ==========

    /// @notice Tracks LP position data for IL calculation
    /// @dev Stores initial deposit information to calculate impermanent loss
    struct LPPosition {
        uint256 token0Initial; // Initial token0 deposited
        uint256 token1Initial; // Initial token1 deposited
        uint160 sqrtPriceX96Initial; // Pool price at deposit time
        int24 tickLower; // Lower tick of position
        int24 tickUpper; // Upper tick of position
        uint256 liquidityAmount; // Liquidity amount in pool units
        uint256 lastUpdateTimestamp; // Last modification timestamp
    }

    // ========== CLAIM TOKEN SYSTEM ==========

    /// @notice Metadata for each claim token type (ERC-1155)
    /// @dev Token ID encodes: poolId (bytes32) + tokenIndex (uint8)
    /// Token ID = uint256(keccak256(abi.encodePacked(poolId, tokenIndex)))
    struct ClaimTokenMetadata {
        PoolId poolId; // Associated pool
        address vaultAddress; // Vault holding the locked capital
        address underlyingToken; // Token type (token0 or token1)
        uint256 totalLockedAmount; // Total principal locked in vault
    }

    // ========== FLASH ACCOUNTING CALLBACK DATA ==========

    /// @notice Data passed to unlock callback for capital sweep operations
    /// @dev Encoded and decoded during flash accounting flow
    struct SweepCallbackData {
        PoolId poolId; // Pool identifier
        address currency0; // Token0 address
        address currency1; // Token1 address
        uint256 amount0; // Amount of token0 to sweep
        uint256 amount1; // Amount of token1 to sweep
    }
}
