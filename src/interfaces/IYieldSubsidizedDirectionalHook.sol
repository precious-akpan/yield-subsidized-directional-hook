// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title IYieldSubsidizedDirectionalHook
/// @notice Interface for automation compatibility with the Yield Subsidized Directional Hook
/// @dev This interface defines the public API used by ReactiveKeeperCallback and ReactiveSubscriber
/// contracts for automated capital sweep orchestration and monitoring. It enables decentralized
/// keepers to interact with the hook for permissionless operations while ensuring type safety
/// and interface compatibility across Reactive Network deployments.
///
/// The interface exposes:
/// - Core permissionless functions for idle capital sweeps and claim token redemption
/// - View functions for pool state and configuration queries
/// - Events for monitoring hook activities and trigger automation
///
/// **Validates: Requirements 49.1-49.5**
interface IYieldSubsidizedDirectionalHook {
    // ========== DATA STRUCTURES ==========

    /// @notice Pool configuration parameters for directional fee scaling and vault management
    /// @dev These parameters control how the hook calculates dynamic fees and manages capital
    struct PoolConfig {
        /// @notice Address of the price oracle for directional fee calculation
        /// @dev Must implement IOracle interface with getPrice(token0, token1) function
        address oracle;

        /// @notice Address of the yield vault for token0
        /// @dev Must implement ERC-4626 interface with deposit/withdraw functions
        address vault0;

        /// @notice Address of the yield vault for token1
        /// @dev Must implement ERC-4626 interface with deposit/withdraw functions
        address vault1;

        /// @notice Baseline swap fee in basis points (e.g., 30 = 0.3%)
        /// @dev Applied to benign flow; toxic flow receives scaled fee = baseFeeBps * feeMultiplier
        uint24 baseFeeBps;

        /// @notice Maximum fee multiplier to cap scaled fees (e.g., 300 = 3x base fee)
        /// @dev Prevents excessive fees that could break pool competitiveness
        uint24 maxFeeMultiplier;

        /// @notice Price deviation threshold for toxic flow classification in basis points
        /// @dev Swaps exceeding this deviation from oracle price are classified as toxic (e.g., 50 = 0.5%)
        uint24 deviationThresholdBps;

        /// @notice Emergency pause flag for disabling non-critical operations
        /// @dev When true, sweepIdleCapital and redeemLockedCapital are disabled
        bool isPaused;
    }

    /// @notice Accumulation structure for yield and principal tracking in IL subsidy pools
    /// @dev Maintains separate accounting for token0 and token1 with vault share custody
    struct SubsidyPool {
        /// @notice Total accumulated yield in token0
        /// @dev Calculated as convertToAssets(vaultShares0) - totalToken0Principal
        uint256 totalToken0Yield;

        /// @notice Total accumulated yield in token1
        /// @dev Calculated as convertToAssets(vaultShares1) - totalToken1Principal
        uint256 totalToken1Yield;

        /// @notice Total principal deposited in token0 vault
        /// @dev Tracked separately from yield for accurate withdrawal calculations
        uint256 totalToken0Principal;

        /// @notice Total principal deposited in token1 vault
        /// @dev Tracked separately from yield for accurate withdrawal calculations
        uint256 totalToken1Principal;

        /// @notice Vault shares received for token0 deposits
        /// @dev Represents ownership stake in the external vault; used to calculate current value
        uint256 vaultShares0;

        /// @notice Vault shares received for token1 deposits
        /// @dev Represents ownership stake in the external vault; used to calculate current value
        uint256 vaultShares1;
    }

    // ========== EVENTS FOR AUTOMATION MONITORING ==========

    /// @notice Emitted when a pool is registered with the hook
    /// @dev Fired during beforeInitialize callback when a new pool is initialized
    /// @param poolId The unique Uniswap v4 pool identifier
    /// @param poolKey The complete PoolKey structure identifying the pool
    event PoolRegistered(PoolId indexed poolId, PoolKey poolKey);

    /// @notice Emitted when idle capital is swept to external yield vaults
    /// @dev Fired after successful flash accounting completion in sweepIdleCapital
    /// Triggers ReactiveSubscriber monitoring to notify ReactiveNetwork of vault deposits
    /// @param poolId The pool from which capital was swept
    /// @param amount0 Idle token0 amount deposited to vault
    /// @param amount1 Idle token1 amount deposited to vault
    /// @param shares0 Vault share tokens received for token0 deposit
    /// @param shares1 Vault share tokens received for token1 deposit
    /// @param caller The address that initiated the sweep (keeper/keeper contract)
    event CapitalSwept(
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 shares0,
        uint256 shares1,
        address indexed caller
    );

    /// @notice Emitted when IL subsidy is distributed to an LP on liquidity removal
    /// @dev Fired during beforeRemoveLiquidity when LP exits a position with accumulated IL
    /// Indicates successful or partial compensation from accumulated yield
    /// @param poolId The pool from which the LP is removing liquidity
    /// @param lp The liquidity provider receiving the subsidy
    /// @param ilToken0 Calculated impermanent loss in token0
    /// @param ilToken1 Calculated impermanent loss in token1
    /// @param subsidyToken0 Actual subsidy distributed in token0 (≤ ilToken0)
    /// @param subsidyToken1 Actual subsidy distributed in token1 (≤ ilToken1)
    /// @param partialCoverage True if subsidy was less than calculated IL (insufficient yield)
    event ILSubsidyDistributed(
        PoolId indexed poolId,
        address indexed lp,
        uint256 ilToken0,
        uint256 ilToken1,
        uint256 subsidyToken0,
        uint256 subsidyToken1,
        bool partialCoverage
    );

    /// @notice Emitted when claim tokens are minted for locked vault capital
    /// @dev Fired during beforeRemoveLiquidity if vault withdrawal fails (illiquid vault)
    /// Signals LP that capital is locked but redeemable when vault liquidity restores
    /// @param lp The liquidity provider receiving the claim token
    /// @param claimTokenId The ERC-1155 token ID representing this vault/token claim
    /// @param amount The amount of principal locked in vault
    /// @param vault The vault address holding the locked capital
    event ClaimTokenMinted(address indexed lp, uint256 indexed claimTokenId, uint256 amount, address vault);

    /// @notice Emitted when idle capital is detected in a pool
    /// @dev Fired to signal automation systems that sweep conditions may be favorable
    /// Enables ReactiveSubscriber to monitor and trigger ReactiveKeeperCallback for automated sweeps
    /// @param poolId The pool with detected idle capital
    /// @param idleAmount0 Amount of out-of-range token0 capital
    /// @param idleAmount1 Amount of out-of-range token1 capital
    /// @param poolKey The pool key used for sweepIdleCapital call
    event IdleCapitalDetected(PoolId indexed poolId, uint256 idleAmount0, uint256 idleAmount1, PoolKey poolKey);

    // ========== PERMISSIONLESS CAPITAL SWEEP FUNCTIONS ==========

    /// @notice Sweeps idle out-of-range capital to external yield vaults
    /// @dev Permissionless function callable by any address (keeper bots, ReactiveKeeperCallback, etc.)
    /// Uses Uniswap v4's flash accounting (unlock/lock) for atomic multi-step execution:
    /// 1. Calculates total out-of-range idle capital using current active tick
    /// 2. Withdraws idle liquidity from PoolManager via take operations
    /// 3. Deposits withdrawn tokens to configured external vaults
    /// 4. Tracks vault share ownership for future subsidy calculations
    /// 5. Settles flash accounting deltas to complete transaction atomically
    ///
    /// Reverts if:
    /// - Pool is not registered
    /// - Pool is paused
    /// - Idle capital is below minimum sweep threshold
    /// - Flash accounting delta balance fails
    ///
    /// Emits: CapitalSwept event upon successful completion
    ///
    /// @param key The PoolKey uniquely identifying the pool to sweep
    /// @dev **Validates: Requirements 9.1-9.5, 10.1-10.5**
    function sweepIdleCapital(PoolKey calldata key) external;

    /// @notice Redeems locked capital from claim tokens when vault becomes liquid
    /// @dev Permissionless function allowing claim token holders to recover locked principal
    /// Called by LPs after vault liquidity is restored following earlier illiquidity
    /// 1. Validates caller owns sufficient claim token balance
    /// 2. Attempts withdrawal from associated vault
    /// 3. Transfers withdrawn tokens to caller
    /// 4. Burns redeemed claim tokens
    /// 5. Updates accounting mappings
    ///
    /// Reverts if:
    /// - Caller does not own sufficient claim token balance
    /// - Claim token ID is invalid/uninitialized
    /// - Vault withdrawal fails (vault still illiquid)
    /// - Reentrancy detected
    ///
    /// Emits: ClaimTokenRedeemed event upon successful redemption
    ///
    /// @param claimTokenId The ERC-1155 claim token ID (encodes pool + vault + token)
    /// @param amount The amount of claim tokens to redeem (converted to underlying via vault)
    /// @dev **Validates: Requirements 17.1-17.5**
    function redeemLockedCapital(uint256 claimTokenId, uint256 amount) external;

    // ========== POOL STATE VIEW FUNCTIONS ==========

    /// @notice Calculates the total idle out-of-range capital in a pool
    /// @dev Used by keepers to determine sweep eligibility and optimization timing
    /// Iterates through registered LP positions comparing tick ranges against current active tick:
    /// - Positions with tickLower > currentTick or tickUpper < currentTick are out-of-range (idle)
    /// - Calculates token amounts for idle positions using uniswap math
    /// - Returns total idle amounts for both tokens
    ///
    /// Note: Intended for off-chain querying or gated automation use due to potential gas costs
    /// if many LP positions exist. Gas complexity: O(number of LP positions)
    ///
    /// @param key The PoolKey identifying the pool
    /// @return idleAmount0 Total idle capital denominated in token0
    /// @return idleAmount1 Total idle capital denominated in token1
    /// @dev **Validates: Requirements 8.1-8.5**
    function getIdleCapital(PoolKey calldata key) external view returns (uint256 idleAmount0, uint256 idleAmount1);

    /// @notice Returns the complete configuration for a pool
    /// @dev Used by automation systems to verify sweep parameters before triggering
    /// Contains oracle address, vault addresses, fee parameters, and pause state
    ///
    /// @param poolId The unique Uniswap v4 pool identifier
    /// @return config The PoolConfig structure with all configuration parameters
    /// @dev **Validates: Requirements 19.1-19.5, 20.1-20.5, 21.1-21.5**
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory config);

    /// @notice Returns the current subsidy pool state for a pool
    /// @dev Used by analytics and automation systems to track accumulated yield and principal
    /// Reflects real-time vault asset conversion for accurate yield calculations
    ///
    /// To calculate available yield:
    /// ```solidity
    /// SubsidyPool memory pool = hook.getSubsidyPool(poolId);
    /// uint256 availableYield0 = vault0.convertToAssets(pool.vaultShares0) - pool.totalToken0Principal;
    /// uint256 availableYield1 = vault1.convertToAssets(pool.vaultShares1) - pool.totalToken1Principal;
    /// ```
    ///
    /// @param poolId The unique Uniswap v4 pool identifier
    /// @return subsidyPool The SubsidyPool structure with yield and principal accounting
    /// @dev **Validates: Requirements 12.1-12.5**
    function getSubsidyPool(PoolId poolId) external view returns (SubsidyPool memory subsidyPool);

    /// @notice Checks whether a pool is registered with the hook
    /// @dev Used by automation systems for access control and pool validation
    /// Prevents processing of unregistered pools which would fail in beforeSwap/beforeRemoveLiquidity
    ///
    /// @param poolId The unique Uniswap v4 pool identifier
    /// @return registered True if pool was registered via beforeInitialize, false otherwise
    /// @dev **Validates: Requirements 1.1-1.7**
    function isPoolRegistered(PoolId poolId) external view returns (bool registered);
}
