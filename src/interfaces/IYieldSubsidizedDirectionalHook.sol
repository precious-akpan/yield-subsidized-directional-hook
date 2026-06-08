// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title IYieldSubsidizedDirectionalHook
/// @notice Interface for the Yield Subsidized Directional Hook
/// @dev Used by automation contracts to interact with the hook
interface IYieldSubsidizedDirectionalHook {
    // ========== STRUCTS ==========

    struct PoolConfig {
        address oracle;
        address vault0;
        address vault1;
        uint24 baseFeeBps;
        uint24 maxFeeMultiplier;
        uint24 deviationThresholdBps;
        bool isPaused;
    }

    struct SubsidyPool {
        uint256 totalToken0Yield;
        uint256 totalToken1Yield;
        uint256 totalToken0Principal;
        uint256 totalToken1Principal;
        uint256 vaultShares0;
        uint256 vaultShares1;
    }

    // ========== EVENTS ==========

    event PoolRegistered(PoolId indexed poolId, PoolKey poolKey);
    event CapitalSwept(
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 shares0,
        uint256 shares1,
        address indexed caller
    );
    event ILSubsidyDistributed(
        PoolId indexed poolId,
        address indexed lp,
        uint256 ilToken0,
        uint256 ilToken1,
        uint256 subsidyToken0,
        uint256 subsidyToken1,
        bool partialCoverage
    );
    event ClaimTokenMinted(
        address indexed lp,
        uint256 indexed claimTokenId,
        uint256 amount,
        address vault
    );
    event IdleCapitalDetected(
        PoolId indexed poolId,
        uint256 idleAmount0,
        uint256 idleAmount1
    );

    // ========== PERMISSIONLESS FUNCTIONS ==========

    /// @notice Sweeps idle out-of-range capital to external yield vaults
    /// @param key The pool key for the pool to sweep
    function sweepIdleCapital(PoolKey calldata key) external;

    /// @notice Redeems locked capital from claim tokens
    /// @param claimTokenId The ERC-1155 token ID to redeem
    /// @param amount The amount of claim tokens to redeem
    function redeemLockedCapital(uint256 claimTokenId, uint256 amount) external;

    // ========== VIEW FUNCTIONS ==========

    /// @notice Returns the total idle capital in a pool
    /// @param key The pool key
    /// @return idleAmount0 Idle capital in token0
    /// @return idleAmount1 Idle capital in token1
    function getIdleCapital(PoolKey calldata key)
        external
        view
        returns (uint256 idleAmount0, uint256 idleAmount1);

    /// @notice Returns the pool configuration
    /// @param poolId The pool identifier
    /// @return config The pool configuration
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory config);

    /// @notice Returns the subsidy pool state
    /// @param poolId The pool identifier
    /// @return subsidyPool The subsidy pool accounting data
    function getSubsidyPool(PoolId poolId) external view returns (SubsidyPool memory subsidyPool);

    /// @notice Checks if a pool is registered
    /// @param poolId The pool identifier
    /// @return registered True if the pool is registered
    function isPoolRegistered(PoolId poolId) external view returns (bool registered);
}
