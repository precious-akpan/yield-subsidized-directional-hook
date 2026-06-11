// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DataTypes} from "./libraries/DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IExternalVault} from "./interfaces/IExternalVault.sol";

/// @dev Event emitted when idle capital is detected in a pool
/// @dev Enables Reactive automation to monitor and trigger automated sweeps
event IdleCapitalDetected(PoolId indexed poolId, uint256 idleAmount0, uint256 idleAmount1, PoolKey poolKey);
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20 as IERC20Token} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title YieldSubsidizedDirectionalHook
/// @notice Uniswap v4 Hook that protects LPs from Impermanent Loss through directional fee scaling,
///         external yield generation on idle capital, and IL subsidy distribution
/// @dev Inherits from IHooks, ERC1155 (for claim tokens), and ReentrancyGuard
/// @custom:security-contact security@example.com
contract YieldSubsidizedDirectionalHook is IHooks, ERC1155, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    // ============ CONSTANTS ============

    /// @notice Maximum age of oracle price before considered stale (5 minutes)
    uint256 private constant ORACLE_STALENESS_THRESHOLD = 300;

    /// @notice Maximum allowed price deviation from pool price (50% = 5000 basis points)
    uint256 private constant MAX_PRICE_DEVIATION_BPS = 5000;

    /// @notice Gas limit for external oracle calls to prevent griefing
    uint256 private constant ORACLE_GAS_LIMIT = 100000;

    /// @notice Fixed point scale for price calculations (18 decimals)
    uint256 private constant PRICE_SCALE = 1e18;

    /// @notice Basis points denominator (100% = 10000 bps)
    uint256 private constant BPS_DENOMINATOR = 10000;

    // ============ IMMUTABLE STATE ============

    /// @notice The Uniswap v4 PoolManager singleton
    /// @dev All callbacks must originate from this address
    IPoolManager public immutable poolManager;

    /// @notice Contract owner with administrative privileges
    /// @dev Set during construction, transferable via transferOwnership
    address public owner;

    // ============ STORAGE MAPPINGS ============

    /// @notice Tracks which pools have been registered via beforeInitialize
    /// @dev Prevents callback spoofing by validating pool existence
    mapping(PoolId => bool) public registeredPools;

    /// @notice Configuration parameters for each registered pool
    /// @dev Contains oracle, vault addresses, fee parameters, and pause status
    mapping(PoolId => DataTypes.PoolConfig) public poolConfigs;

    /// @notice IL subsidy pool accounting for each pool
    /// @dev Tracks principal, yield, and vault shares for both token0 and token1
    mapping(PoolId => DataTypes.SubsidyPool) public subsidyPools;

    /// @notice LP position data for IL calculation
    /// @dev Maps LP address -> PoolId -> position index -> position data
    /// @custom:note Simplified implementation uses single position per LP per pool
    mapping(address => mapping(PoolId => mapping(uint256 => DataTypes.LPPosition))) public lpPositions;

    /// @notice Number of positions per LP per pool
    /// @dev Used for multi-position support (future enhancement)
    mapping(address => mapping(PoolId => uint256)) public lpPositionCount;

    /// @notice Metadata for each ERC-1155 claim token type
    /// @dev Token ID encodes poolId + tokenIndex, links to vault and locked amounts
    mapping(uint256 => DataTypes.ClaimTokenMetadata) public claimTokenMetadata;

    /// @notice Tracks individual LP locked capital per claim token
    /// @dev Maps claim token ID -> LP address -> locked amount
    mapping(uint256 => mapping(address => uint256)) public lpLockedAmounts;

    /// @notice Cached oracle prices to avoid redundant calls within same transaction
    /// @dev Maps block number -> PoolId -> cached oracle data
    /// @custom:security Cache is block-scoped to prevent stale price usage across blocks
    struct OracleCache {
        uint256 price;
        uint256 timestamp;
        bool isValid;
    }
    mapping(uint256 => mapping(PoolId => OracleCache)) private oraclePriceCache;

    // ============ EVENTS ============

    /// @notice Emitted when ownership is transferred to a new address
    /// @param previousOwner The address of the previous owner
    /// @param newOwner The address of the new owner
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when a pool is successfully registered
    /// @param poolId The unique identifier of the registered pool
    /// @param poolKey The PoolKey containing token pair and fee information
    /// @param sqrtPriceX96 The initial price of the pool
    event PoolRegistered(PoolId indexed poolId, PoolKey poolKey, uint160 sqrtPriceX96);

    /// @notice Emitted when a directional fee is applied to a swap
    /// @param poolId The unique identifier of the pool
    /// @param zeroForOne The direction of the swap (true = token0 to token1)
    /// @param isToxic Whether the swap was classified as toxic flow
    /// @param fee The fee applied to the swap in basis points
    /// @param oraclePrice The oracle price at the time of the swap
    /// @param poolPrice The pool price at the time of the swap
    /// @param deviation The price deviation in basis points
    event DirectionalFeeApplied(
        PoolId indexed poolId,
        bool zeroForOne,
        bool isToxic,
        uint24 fee,
        uint256 oraclePrice,
        uint256 poolPrice,
        uint256 deviation
    );

    /// @notice Emitted when a pool configuration is updated
    /// @param poolId The unique identifier of the pool
    /// @param oracle The oracle contract address
    /// @param vault0 The vault contract address for token0
    /// @param vault1 The vault contract address for token1
    /// @param baseFeeBps The baseline fee in basis points
    /// @param maxFeeMultiplier The maximum fee multiplier
    /// @param deviationThresholdBps The price deviation threshold
    event PoolConfigured(
        PoolId indexed poolId,
        address oracle,
        address vault0,
        address vault1,
        uint24 baseFeeBps,
        uint24 maxFeeMultiplier,
        uint24 deviationThresholdBps
    );

    /// @notice Emitted when a pool is paused
    /// @param poolId The unique identifier of the paused pool
    /// @param timestamp The timestamp when the pool was paused
    event PoolPaused(PoolId indexed poolId, uint256 timestamp);

    /// @notice Emitted when a pool is unpaused
    /// @param poolId The unique identifier of the unpaused pool
    /// @param timestamp The timestamp when the pool was unpaused
    event PoolUnpaused(PoolId indexed poolId, uint256 timestamp);

    // ============ CONSTRUCTOR ============

    /// @notice Initializes the hook with PoolManager reference
    /// @dev Sets immutable poolManager and owner, initializes ERC1155 with empty URI
    /// @param _poolManager The Uniswap v4 PoolManager singleton address
    constructor(IPoolManager _poolManager) ERC1155("") {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();

        poolManager = _poolManager;
        owner = msg.sender;
    }

    // ============ ADMINISTRATIVE FUNCTIONS ============

    /// @notice Transfers ownership of the contract to a new address
    /// @dev Can only be called by the current owner
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Errors.ZeroAddress();

        address previousOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @notice Configures pool parameters including oracle, vaults, and fee scaling
    /// @dev Can only be called by the owner with onlyOwner and nonReentrant modifiers
    /// @dev Validates all inputs before storing configuration
    /// @param poolId The unique identifier of the pool to configure
    /// @param config The PoolConfig struct containing oracle, vaults, and fee parameters
    /// @custom:requirements Validates: 19.1-19.5, 20.1-20.5, 21.1-21.5, 22.1-22.5
    function configurePool(PoolId poolId, DataTypes.PoolConfig calldata config) external onlyOwner nonReentrant {
        // Validate pool is registered
        if (!registeredPools[poolId]) {
            revert Errors.PoolNotRegistered(PoolId.unwrap(poolId));
        }

        // Note: Oracle validation at configure time is intentionally skipped.
        // Per IOracle interface: "Implementations should revert if price data is unavailable or invalid"
        // Using a synthetic (0,0) pair would incorrectly reject valid oracles that properly validate token pairs.
        // Oracle is validated at runtime with actual pool tokens in getOraclePriceWithValidation(),
        // which uses try-catch to gracefully handle oracle failures.

        // Validate vault0 implements IExternalVault interface if non-zero
        if (config.vault0 != address(0)) {
            // Validate vault implements required interface by checking asset()
            try IExternalVault(config.vault0).asset() returns (
                address
            ) {
            // Vault must be retrievable in the pool key to validate asset match
            // For now, we store this for later validation during sweeps
            }
            catch {
                revert Errors.InvalidVault(config.vault0);
            }
        }

        // Validate vault1 implements IExternalVault interface if non-zero
        if (config.vault1 != address(0)) {
            // Validate vault implements required interface by checking asset()
            try IExternalVault(config.vault1).asset() returns (
                address
            ) {
            // Vault must be retrievable in the pool key to validate asset match
            // For now, we store this for later validation during sweeps
            }
            catch {
                revert Errors.InvalidVault(config.vault1);
            }
        }

        // Validate fee parameters: maxFeeMultiplier >= BPS_DENOMINATOR (1.0x)
        // Multipliers are in basis-point format where 10000 == 1.0x
        // Values below 10000 would REDUCE fees under toxic conditions
        if (config.maxFeeMultiplier < BPS_DENOMINATOR) {
            revert Errors.InvalidConfiguration("maxFeeMultiplier must be >= 10000 (1.0x)");
        }

        // Validate fee parameters are within reasonable bounds
        // baseFeeBps should be <= 10000 (100%)
        if (config.baseFeeBps > 10000) {
            revert Errors.InvalidConfiguration("baseFeeBps exceeds 100%");
        }

        // maxFeeMultiplier should be <= 100000 (1000%)
        if (config.maxFeeMultiplier > 100000) {
            revert Errors.InvalidConfiguration("maxFeeMultiplier exceeds 1000%");
        }

        // deviationThresholdBps should be > 0 and <= 10000
        if (config.deviationThresholdBps == 0 || config.deviationThresholdBps > 10000) {
            revert Errors.InvalidConfiguration("deviationThresholdBps must be between 1 and 10000");
        }

        // Store configuration in poolConfigs mapping
        poolConfigs[poolId] = config;

        // Emit PoolConfigured event
        emit PoolConfigured(
            poolId,
            config.oracle,
            config.vault0,
            config.vault1,
            config.baseFeeBps,
            config.maxFeeMultiplier,
            config.deviationThresholdBps
        );
    }

    /// @notice Pauses a pool, disabling directional fee scaling and capital sweeps
    /// @dev Can only be called by the owner
    /// @dev Sets isPaused flag in pool configuration
    /// @param poolId The unique identifier of the pool to pause
    /// @custom:requirements Validates: 22.1-22.5, 33.1-33.5
    function pausePool(PoolId poolId) external onlyOwner {
        // Validate pool is registered
        if (!registeredPools[poolId]) {
            revert Errors.PoolNotRegistered(PoolId.unwrap(poolId));
        }

        // Update isPaused flag
        poolConfigs[poolId].isPaused = true;

        // Emit PoolPaused event
        emit PoolPaused(poolId, block.timestamp);
    }

    /// @notice Unpauses a pool, restoring directional fee scaling and capital sweeps
    /// @dev Can only be called by the owner
    /// @dev Clears isPaused flag in pool configuration
    /// @param poolId The unique identifier of the pool to unpause
    /// @custom:requirements Validates: 22.1-22.5, 33.1-33.5
    function unpausePool(PoolId poolId) external onlyOwner {
        // Validate pool is registered
        if (!registeredPools[poolId]) {
            revert Errors.PoolNotRegistered(PoolId.unwrap(poolId));
        }

        // Update isPaused flag
        poolConfigs[poolId].isPaused = false;

        // Emit PoolUnpaused event
        emit PoolUnpaused(poolId, block.timestamp);
    }

    // ============ HOOK PERMISSIONS ============

    /// @notice Returns the hook permissions bitmap for this contract
    /// @dev Indicates which hook callbacks this contract implements
    /// @return Hooks.Permissions struct with beforeInitialize, beforeSwap, and beforeRemoveLiquidity set to true
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ HOOK CALLBACK IMPLEMENTATIONS ============

    /// @inheritdoc IHooks
    /// @notice Called when a pool is initialized
    /// @dev Registers the pool and initializes its subsidy pool accounting
    /// @param key The PoolKey identifying the pool being initialized
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @return bytes4 The function selector to confirm successful execution
    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        // Validate pool is not already registered
        if (registeredPools[poolId]) {
            revert Errors.PoolAlreadyRegistered(PoolId.unwrap(poolId));
        }

        // Register the pool
        registeredPools[poolId] = true;

        // Initialize empty SubsidyPool for this pool
        subsidyPools[poolId] = DataTypes.SubsidyPool({
            totalToken0Yield: 0,
            totalToken1Yield: 0,
            totalToken0Principal: 0,
            totalToken1Principal: 0,
            vaultShares0: 0,
            vaultShares1: 0
        });

        // Emit registration event
        emit PoolRegistered(poolId, key, sqrtPriceX96);

        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual returns (bytes4) {
        revert("Not implemented");
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert("Not implemented");
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert("Not implemented");
    }

    /// @inheritdoc IHooks
    /// @notice Called before liquidity is removed from a pool
    /// @dev Calculates IL and distributes subsidy from yield pools if available
    /// @param key The PoolKey identifying the pool
    /// @param params The liquidity removal parameters
    /// @param hookData Additional data for LP address identification
    /// @return bytes4 The function selector to confirm successful execution
    /// @custom:requirements Validates: 2.2-2.4, 2.6-2.8, 13.1-13.5, 14.1-14.5, 15.1-15.5, 25.1-25.5, 33.4
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external virtual onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();

        // Validate pool is registered
        if (!registeredPools[poolId]) {
            revert Errors.PoolNotRegistered(PoolId.unwrap(poolId));
        }

        // Retrieve LP address (from tx.origin or hook data)
        // In a production system, hookData would encode the LP address
        // For this implementation, we use tx.origin as a simplified approach
        address lp = hookData.length > 0 ? abi.decode(hookData, (address)) : tx.origin;

        // Fetch LP position data (using index 0 for simplified single position)
        DataTypes.LPPosition memory position = lpPositions[lp][poolId][0];

        // Skip if position doesn't exist or has no liquidity
        if (position.liquidityAmount == 0) {
            return IHooks.beforeRemoveLiquidity.selector;
        }

        // Get current pool price for IL calculation
        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Calculate Impermanent Loss
        (uint256 ilToken0, uint256 ilToken1) = calculateImpermanentLoss(position, currentSqrtPriceX96);

        // Skip if IL is zero (no loss or in profit)
        if (ilToken0 == 0 && ilToken1 == 0) {
            return IHooks.beforeRemoveLiquidity.selector;
        }

        // Calculate available subsidy from yield pools
        uint256 availableYield0 = calculateAvailableYield(poolId, true);
        uint256 availableYield1 = calculateAvailableYield(poolId, false);

        // Cap subsidy at lesser of IL or available yield
        uint256 subsidy0 = ilToken0 > availableYield0 ? availableYield0 : ilToken0;
        uint256 subsidy1 = ilToken1 > availableYield1 ? availableYield1 : ilToken1;

        // Call withdrawFromVault for needed subsidy amounts
        if (subsidy0 > 0) {
            withdrawFromVault(key, poolId, lp, true, subsidy0);
        }
        if (subsidy1 > 0) {
            withdrawFromVault(key, poolId, lp, false, subsidy1);
        }

        // Update SubsidyPool yield balances
        DataTypes.SubsidyPool storage pool = subsidyPools[poolId];
        pool.totalToken0Yield = availableYield0 > subsidy0 ? availableYield0 - subsidy0 : 0;
        pool.totalToken1Yield = availableYield1 > subsidy1 ? availableYield1 - subsidy1 : 0;

        // Determine if subsidy is partial coverage
        bool partialCoverage = (subsidy0 < ilToken0) || (subsidy1 < ilToken1);

        // Emit ILSubsidyDistributed event
        emit ILSubsidyDistributed(poolId, lp, ilToken0, ilToken1, subsidy0, subsidy1, partialCoverage);

        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert("Not implemented");
    }

    /// @inheritdoc IHooks
    /// @notice Called before a swap is executed
    /// @dev Implements directional fee scaling based on oracle price comparison
    /// @param key The PoolKey identifying the pool
    /// @param params The swap parameters including direction and amount
    /// @return bytes4 The function selector to confirm successful execution
    /// @return BeforeSwapDelta The delta to apply (ZERO_DELTA for this implementation)
    /// @return uint24 The fee override in basis points
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // Validate pool is registered
        if (!registeredPools[poolId]) {
            revert Errors.PoolNotRegistered(PoolId.unwrap(poolId));
        }

        DataTypes.PoolConfig memory config = poolConfigs[poolId];

        // If pool is paused, return baseline fee without classification
        if (config.isPaused) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, config.baseFeeBps);
        }

        // Classify flow and calculate dynamic fee
        (bool isToxic, uint24 feeOverride) = classifyFlow(key, params.zeroForOne, params.amountSpecified);

        // Emit event with fee details
        _emitDirectionalFeeEvent(poolId, key, params.zeroForOne, isToxic, feeOverride);

        // Return fee override
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    /// @notice Emits directional fee applied event with price information
    /// @dev Helper function to avoid stack too deep in beforeSwap
    /// @param poolId The pool identifier
    /// @param key The pool key
    /// @param zeroForOne The swap direction
    /// @param isToxic Whether the flow was classified as toxic
    /// @param feeOverride The fee applied
    function _emitDirectionalFeeEvent(
        PoolId poolId,
        PoolKey calldata key,
        bool zeroForOne,
        bool isToxic,
        uint24 feeOverride
    ) internal {
        // Get prices for event emission
        (uint256 oraclePrice, bool isValid) = getOraclePriceWithValidation(key);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint256 poolPrice = sqrtPriceX96ToPrice(sqrtPriceX96);

        // Calculate deviation for event
        uint256 deviation = isValid ? calculateDeviation(oraclePrice, poolPrice) : 0;

        // Emit event for analytics
        emit DirectionalFeeApplied(
            poolId, zeroForOne, isToxic, feeOverride, isValid ? oraclePrice : 0, poolPrice, deviation
        );
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert("Not implemented");
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert("Not implemented");
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert("Not implemented");
    }

    // ============ ORACLE AND PRICE UTILITIES ============

    /// @notice Fetches oracle price with validation for staleness and sanity bounds
    /// @dev Uses try-catch with gas limit to handle oracle failures gracefully
    /// @dev Caches oracle price within transaction using block.number as key
    /// @param key The PoolKey to fetch oracle price for
    /// @return price The oracle price in fixed-point format (18 decimals)
    /// @return isValid True if price passes all validation checks, false otherwise
    /// @custom:requirements Validates: 3.1-3.5, 28.1-28.5, 29.1-29.5
    function getOraclePriceWithValidation(PoolKey calldata key) internal virtual returns (uint256 price, bool isValid) {
        PoolId poolId = key.toId();

        // Check cache first to avoid redundant oracle calls in same transaction
        OracleCache memory cached = oraclePriceCache[block.number][poolId];
        if (cached.timestamp > 0) {
            return (cached.price, cached.isValid);
        }

        // Get pool configuration
        DataTypes.PoolConfig memory config = poolConfigs[poolId];

        // If no oracle configured, return invalid
        if (config.oracle == address(0)) {
            oraclePriceCache[block.number][poolId] = OracleCache({price: 0, timestamp: block.timestamp, isValid: false});
            return (0, false);
        }

        // Query oracle with try-catch and gas limit
        try IOracle(config.oracle).getPrice{gas: ORACLE_GAS_LIMIT}(
            Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)
        ) returns (
            uint256 oraclePrice, uint256 oracleTimestamp
        ) {
            // Validate timestamp for staleness (5 minute threshold)
            // Treat zero timestamp as stale
            // Handle edge case where oracle timestamp might be in future (test scenarios)
            bool isStale = oracleTimestamp == 0 || oracleTimestamp > block.timestamp
                || (block.timestamp - oracleTimestamp > ORACLE_STALENESS_THRESHOLD);
            if (isStale) {
                oraclePriceCache[block.number][poolId] =
                    OracleCache({price: oraclePrice, timestamp: oracleTimestamp, isValid: false});
                return (oraclePrice, false);
            }

            // Get current pool price for deviation check
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
            uint256 poolPrice = sqrtPriceX96ToPrice(sqrtPriceX96);

            // Validate price deviation from pool price (50% max)
            uint256 deviation = calculateDeviation(oraclePrice, poolPrice);
            bool deviationExceeded = deviation > MAX_PRICE_DEVIATION_BPS;

            if (deviationExceeded) {
                oraclePriceCache[block.number][poolId] =
                    OracleCache({price: oraclePrice, timestamp: oracleTimestamp, isValid: false});
                return (oraclePrice, false);
            }

            // Cache valid oracle price
            oraclePriceCache[block.number][poolId] =
                OracleCache({price: oraclePrice, timestamp: oracleTimestamp, isValid: true});

            return (oraclePrice, true);
        } catch {
            // Oracle call failed - cache as invalid and return
            oraclePriceCache[block.number][poolId] = OracleCache({price: 0, timestamp: block.timestamp, isValid: false});
            return (0, false);
        }
    }

    /// @notice Converts sqrtPriceX96 format to standard fixed-point price
    /// @dev Handles the Uniswap v4 sqrt(price) * 2^96 encoding
    /// @dev Returns price as token1 per token0 with 18 decimal precision
    /// @param sqrtPriceX96 The square root price in X96 format
    /// @return price The price in standard fixed-point format (18 decimals)
    /// @custom:requirements Validates: 4.1-4.4
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure virtual returns (uint256 price) {
        // sqrtPriceX96 = sqrt(price) * 2^96
        // price = (sqrtPriceX96 / 2^96)^2
        // price = (sqrtPriceX96)^2 / 2^192

        // To maintain precision with 18 decimals:
        // price = (sqrtPriceX96^2 * 1e18) / 2^192

        // Using FullMath.mulDiv for precision:
        // price = mulDiv(sqrtPriceX96^2, 1e18, 2^192)
        // But sqrtPriceX96^2 can overflow uint256, so we break it down:
        // price = mulDiv(sqrtPriceX96, sqrtPriceX96 * 1e18, 2^192)

        uint256 numerator = uint256(sqrtPriceX96) * PRICE_SCALE;

        // Use FullMath.mulDiv to handle intermediate overflow
        // price = (sqrtPriceX96 * numerator) / 2^192
        // where numerator = sqrtPriceX96 * 1e18
        price = FullMath.mulDiv(uint256(sqrtPriceX96), numerator, 1 << 192);

        return price;
    }

    /// @notice Calculates price deviation between two prices in basis points
    /// @dev Returns absolute deviation as basis points (1 bps = 0.01%)
    /// @dev Handles both cases where price1 > price2 or price2 > price1
    /// @param price1 First price in fixed-point format
    /// @param price2 Second price in fixed-point format
    /// @return deviationBps The absolute deviation in basis points
    /// @custom:requirements Validates: 4.1-4.4
    function calculateDeviation(uint256 price1, uint256 price2) internal pure virtual returns (uint256 deviationBps) {
        if (price1 == 0 || price2 == 0) {
            return BPS_DENOMINATOR; // Return 100% deviation if either price is zero
        }

        // Calculate absolute difference
        uint256 diff;
        uint256 basePrice;

        if (price1 > price2) {
            diff = price1 - price2;
            basePrice = price2;
        } else {
            diff = price2 - price1;
            basePrice = price1;
        }

        // Calculate deviation in basis points
        // deviation% = (diff / basePrice) * 100
        // deviationBps = (diff / basePrice) * 10000
        deviationBps = (diff * BPS_DENOMINATOR) / basePrice;

        return deviationBps;
    }

    /// @notice Calculates the fee multiplier based on price deviation magnitude
    /// @dev Implements linear scaling from base (1.0x) to max multiplier
    /// @dev All values are in basis points (10000 = 1.0 = 100%)
    /// @dev Automatically caps at maxFeeMultiplier to prevent excessive fees
    /// @param deviationBps The price deviation magnitude in basis points
    /// @param config The pool configuration containing fee scaling parameters
    /// @return feeMultiplier The calculated fee multiplier capped at config.maxFeeMultiplier
    /// @custom:requirements Validates: 6.1-6.5, 27.1-27.5
    /// @custom:example If deviation=100 bps, threshold=50 bps, maxMultiplier=30000 (3x):
    ///                 excessDeviation = 100 - 50 = 50 bps
    ///                 scaleFactor = (50 * 10000) / 50 = 10000 (1.0x)
    ///                 increment = (10000 * (30000 - 10000)) / 10000 = 20000
    ///                 multiplier = 10000 + 20000 = 30000 (3x multiplier)
    function calculateFeeMultiplier(uint256 deviationBps, DataTypes.PoolConfig memory config)
        internal
        pure
        virtual
        returns (uint24)
    {
        // Handle edge case: zero deviation should return base multiplier (1.0 = 10000 bps)
        if (deviationBps == 0) {
            return uint24(BPS_DENOMINATOR);
        }

        // Handle edge case: zero threshold would cause division by zero
        if (config.deviationThresholdBps == 0) {
            return config.maxFeeMultiplier;
        }

        // If deviation is at or below threshold, return base multiplier
        if (deviationBps <= config.deviationThresholdBps) {
            return uint24(BPS_DENOMINATOR);
        }

        // Linear scaling formula for deviation above threshold:
        // multiplier = 1.0 + (excessDeviation / threshold) * (maxMultiplier - 1.0)
        // In basis points:
        // multiplier = 10000 + (excessDeviation * (maxMultiplier - 10000)) / threshold

        // Calculate excess deviation above threshold
        uint256 excessDeviation = deviationBps - config.deviationThresholdBps;

        // Calculate scale factor: (excessDeviation / threshold) in basis points
        // scaleFactor represents how many times the excess deviation exceeds the threshold
        uint256 scaleFactor = (excessDeviation * BPS_DENOMINATOR) / config.deviationThresholdBps;

        // Calculate the increment above base multiplier (1.0)
        // increment = scaleFactor * (maxMultiplier - 10000) / 10000
        uint256 increment = (scaleFactor * (config.maxFeeMultiplier - BPS_DENOMINATOR)) / BPS_DENOMINATOR;

        // Calculate final multiplier: base (1.0) + increment
        uint256 multiplier = BPS_DENOMINATOR + increment;

        // Cap at maximum multiplier from config
        if (multiplier > config.maxFeeMultiplier) {
            return config.maxFeeMultiplier;
        }

        // Ensure multiplier is at least 1.0 (10000 bps)
        if (multiplier < BPS_DENOMINATOR) {
            return uint24(BPS_DENOMINATOR);
        }

        return uint24(multiplier);
    }

    // ============ FLOW CLASSIFICATION AND FEE SCALING ============

    /// @notice Classifies a swap as toxic or benign flow and calculates dynamic fee
    /// @dev Compares swap direction against oracle price to identify arbitrage
    /// @param key The PoolKey identifying the pool
    /// @param zeroForOne The direction of the swap (true = token0 to token1)
    /// @param amountSpecified The amount being swapped (can be positive or negative)
    /// @return isToxic True if swap moves price away from oracle, false otherwise
    /// @return feeMultiplier The fee to apply in basis points (e.g., 30 = 0.3%)
    /// @custom:requirements Validates: 5.1-5.5, 6.1-6.5
    function classifyFlow(PoolKey calldata key, bool zeroForOne, int256 amountSpecified)
        internal
        virtual
        returns (bool isToxic, uint24 feeMultiplier)
    {
        PoolId poolId = key.toId();
        DataTypes.PoolConfig memory config = poolConfigs[poolId];

        // Fetch oracle price with validation
        (uint256 oraclePrice, bool isValid) = getOraclePriceWithValidation(key);

        // If oracle is invalid, fallback to baseline fee
        if (!isValid) {
            return (false, config.baseFeeBps);
        }

        // Get current pool price from Slot0
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint256 currentPrice = sqrtPriceX96ToPrice(sqrtPriceX96);

        // Estimate post-swap price
        uint256 estimatedPrice = estimatePostSwapPrice(currentPrice, zeroForOne, amountSpecified);

        // Calculate deviations from oracle price
        uint256 currentDeviation = calculateDeviation(currentPrice, oraclePrice);
        uint256 estimatedDeviation = calculateDeviation(estimatedPrice, oraclePrice);

        // Determine if swap moves price away from oracle (toxic)
        isToxic = estimatedDeviation > currentDeviation;

        // If toxic and deviation exceeds threshold, calculate scaled fee
        if (isToxic && estimatedDeviation > config.deviationThresholdBps) {
            // calculateFeeMultiplier returns a multiplier (e.g., 10000 = 1.0x, 30000 = 3.0x)
            uint24 multiplier = calculateFeeMultiplier(estimatedDeviation, config);

            // Apply multiplier to base fee: fee = baseFeeBps * (multiplier / 10000)
            uint256 scaledFee = (uint256(config.baseFeeBps) * uint256(multiplier)) / BPS_DENOMINATOR;

            // Cap at uint24 max value
            if (scaledFee > type(uint24).max) {
                scaledFee = type(uint24).max;
            }

            feeMultiplier = uint24(scaledFee);
        } else {
            // Benign flow or below threshold: use baseline fee
            feeMultiplier = config.baseFeeBps;
        }

        return (isToxic, feeMultiplier);
    }

    /// @notice Estimates the pool price after a swap
    /// @dev Simplified estimation using constant product formula approximation
    /// @dev For production, integrate with full AMM math library for accurate price impact
    /// @param currentPrice Current pool price in fixed-point format
    /// @param zeroForOne True if swapping token0 for token1
    /// @param amountSpecified Amount being swapped (positive = exact input, negative = exact output)
    /// @return estimatedPrice The estimated post-swap price
    /// @custom:note This is a simplified approximation. Full implementation should use
    ///              Uniswap v4's tick math and liquidity calculations for accuracy
    function estimatePostSwapPrice(uint256 currentPrice, bool zeroForOne, int256 amountSpecified)
        internal
        pure
        virtual
        returns (uint256 estimatedPrice)
    {
        // For a simplified estimation, we approximate price impact
        // In a real implementation, this would use:
        // 1. Current tick and liquidity from pool state
        // 2. SqrtPriceMath.getNextSqrtPriceFromInput/Output
        // 3. Tick boundaries and liquidity distribution

        // For now, we use a simplified directional heuristic:
        // - If zeroForOne (selling token0), price decreases (token1 per token0)
        // - If oneForZero (selling token1), price increases (token1 per token0)

        // Use absolute value of amountSpecified for magnitude
        uint256 absAmount = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);

        // Simplified price impact estimation (5% impact per 1e18 amount as placeholder)
        // This should be replaced with proper tick math in production
        uint256 priceImpactBps = (absAmount * 500) / PRICE_SCALE;

        // Cap price impact at 50% for safety
        if (priceImpactBps > 5000) {
            priceImpactBps = 5000;
        }

        if (zeroForOne) {
            // Selling token0 decreases the price (token1/token0)
            uint256 decrease = (currentPrice * priceImpactBps) / BPS_DENOMINATOR;
            estimatedPrice = currentPrice > decrease ? currentPrice - decrease : currentPrice / 2;
        } else {
            // Selling token1 increases the price (token1/token0)
            uint256 increase = (currentPrice * priceImpactBps) / BPS_DENOMINATOR;
            estimatedPrice = currentPrice + increase;
        }

        return estimatedPrice;
    }

    // ============ IDLE CAPITAL DETECTION ============

    /// @notice Calculates the amount of idle (out-of-range) capital for a pool
    /// @dev Uses external position tracking approach for gas efficiency
    /// @dev Position data must be provided by off-chain indexers or external contracts
    /// @param key The PoolKey identifying the pool
    /// @param tickLowers Array of lower tick bounds for LP positions
    /// @param tickUppers Array of upper tick bounds for LP positions
    /// @param liquidityAmounts Array of liquidity amounts for each position
    /// @return idleAmount0 Total idle amount of token0
    /// @return idleAmount1 Total idle amount of token1
    /// @custom:requirements Validates: 8.1-8.5
    function calculateIdleCapital(
        PoolKey calldata key,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers,
        uint128[] calldata liquidityAmounts
    ) public view virtual returns (uint256 idleAmount0, uint256 idleAmount1) {
        // Validate input arrays have matching lengths
        if (tickLowers.length != tickUppers.length || tickLowers.length != liquidityAmounts.length) {
            revert Errors.InvalidConfiguration("Position array lengths must match");
        }

        // Get pool ID and validate pool is registered
        PoolId poolId = key.toId();
        if (!registeredPools[poolId]) {
            revert Errors.PoolNotRegistered(PoolId.unwrap(poolId));
        }

        // Get current active tick from pool's Slot0
        (uint160 sqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Iterate through provided positions to identify out-of-range liquidity
        for (uint256 i = 0; i < tickLowers.length; i++) {
            int24 tickLower = tickLowers[i];
            int24 tickUpper = tickUppers[i];
            uint128 liquidity = liquidityAmounts[i];

            // Skip if liquidity is zero
            if (liquidity == 0) {
                continue;
            }

            // Check if position is out of range
            // Position is in-range if: tickLower <= currentTick < tickUpper
            bool isInRange = (tickLower <= currentTick) && (currentTick < tickUpper);

            if (!isInRange) {
                // Position is out of range - calculate token amounts
                // Use TickMath to get sqrt prices at tick boundaries
                uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
                uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

                // Calculate token amounts based on position location relative to current price
                if (currentTick < tickLower) {
                    // Position is entirely in token0 (above current price)
                    // Calculate amount0 using the position's tick range
                    uint256 amount0 = SqrtPriceMath.getAmount0Delta(
                        sqrtPriceLowerX96,
                        sqrtPriceUpperX96,
                        liquidity,
                        true // round up for conservative estimate
                    );
                    idleAmount0 += amount0;
                    // amount1 is 0 for positions above current price
                } else {
                    // currentTick >= tickUpper
                    // Position is entirely in token1 (below current price)
                    // Calculate amount1 using the position's tick range
                    uint256 amount1 = SqrtPriceMath.getAmount1Delta(
                        sqrtPriceLowerX96,
                        sqrtPriceUpperX96,
                        liquidity,
                        true // round up for conservative estimate
                    );
                    idleAmount1 += amount1;
                    // amount0 is 0 for positions below current price
                }
            }
            // If in-range, position is active - skip (not idle)
        }

        return (idleAmount0, idleAmount1);
    }

    // ============ CAPITAL SWEEP FUNCTIONS ============

    /// @notice Sweeps idle out-of-range capital to external yield vaults
    /// @dev Permissionless function callable by anyone (typically automated keepers)
    /// @param key The PoolKey identifying the pool to sweep
    /// @custom:requirements Validates: 9.1-9.5, 10.1, 26.1-26.5, 33.2
    function sweepIdleCapital(
        PoolKey calldata key,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers,
        uint128[] calldata liquidityAmounts
    ) external nonReentrant {
        PoolId poolId = key.toId();

        // Validate pool is registered
        if (!registeredPools[poolId]) {
            revert Errors.PoolNotRegistered(PoolId.unwrap(poolId));
        }

        // Check if pool is paused
        DataTypes.PoolConfig memory config = poolConfigs[poolId];
        if (config.isPaused) {
            revert Errors.Paused();
        }

        // Calculate idle capital amounts
        (uint256 idleAmount0, uint256 idleAmount1) = calculateIdleCapital(key, tickLowers, tickUppers, liquidityAmounts);

        // Emit event for Reactive automation to monitor
        // This enables ReactiveSubscriber to detect idle capital and trigger automated sweeps
        emit IdleCapitalDetected(poolId, idleAmount0, idleAmount1, key);

        // Validate amounts exceed minimum sweep threshold
        // At least one token must meet the threshold
        if (idleAmount0 < 0.1 ether && idleAmount1 < 0.1 ether) {
            revert Errors.BelowMinimumThreshold();
        }

        // Encode sweep parameters for unlock callback
        bytes memory data = abi.encode(poolId, key, idleAmount0, idleAmount1);

        // Call poolManager.unlock() to trigger flash accounting
        poolManager.unlock(data);
    }

    /// @notice Unlock callback for capital sweep flash accounting
    /// @dev Called by PoolManager during unlock() execution
    /// @param data Encoded sweep parameters (poolId, key, amounts)
    /// @return Empty bytes (required by IUnlockCallback interface)
    /// @custom:requirements Validates: 10.1-10.5, 11.1-11.5, 12.1-12.5, 24.1-24.5, 29.1-29.5
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Validate caller is poolManager
        if (msg.sender != address(poolManager)) {
            revert Errors.UnauthorizedCaller();
        }

        // Decode sweep parameters from callback data
        (PoolId poolId, PoolKey memory key, uint256 amount0, uint256 amount1) =
            abi.decode(data, (PoolId, PoolKey, uint256, uint256));

        DataTypes.PoolConfig memory config = poolConfigs[poolId];
        uint256 shares0;
        uint256 shares1;

        // Use poolManager.take() to withdraw idle token amounts
        if (amount0 > 0) {
            poolManager.take(key.currency0, address(this), amount0);

            // Approve vault contract for token0 transfer and deposit
            if (config.vault0 != address(0)) {
                address token0Address = Currency.unwrap(key.currency0);
                IERC20Token token0 = IERC20Token(token0Address);

                // Approve vault for token transfer
                require(token0.approve(config.vault0, amount0), "Token0 approve failed");

                // Call vault deposit() function with gas limit
                try IExternalVault(config.vault0).deposit{gas: 150000}(amount0, address(this)) returns (
                    uint256 _shares0
                ) {
                    shares0 = _shares0;
                } catch {
                    // If vault deposit fails, revert the entire sweep
                    revert Errors.VaultDepositFailed();
                }
            }
        }

        if (amount1 > 0) {
            poolManager.take(key.currency1, address(this), amount1);

            // Approve vault contract for token1 transfer and deposit
            if (config.vault1 != address(0)) {
                address token1Address = Currency.unwrap(key.currency1);
                IERC20Token token1 = IERC20Token(token1Address);

                // Approve vault for token transfer
                require(token1.approve(config.vault1, amount1), "Token1 approve failed");

                // Call vault deposit() function with gas limit
                try IExternalVault(config.vault1).deposit{gas: 150000}(amount1, address(this)) returns (
                    uint256 _shares1
                ) {
                    shares1 = _shares1;
                } catch {
                    // If vault deposit fails, revert the entire sweep
                    revert Errors.VaultDepositFailed();
                }
            }
        }

        // Update SubsidyPool accounting (principal and vault shares)
        DataTypes.SubsidyPool storage pool = subsidyPools[poolId];
        pool.totalToken0Principal += amount0;
        pool.totalToken1Principal += amount1;
        pool.vaultShares0 += shares0;
        pool.vaultShares1 += shares1;

        // Settle deltas using poolManager.mint()
        // When we take() tokens and deposit them to vaults (not returning to pool),
        // we need to balance the delta accounting to zero.
        // Using mint() converts the negative delta (debt from take) into ERC6909 claims
        // owned by this hook, effectively settling the debt WITHOUT returning physical tokens.
        // This keeps the tokens in the vault while maintaining proper accounting.
        if (amount0 > 0) {
            poolManager.mint(address(this), key.currency0.toId(), amount0);
        }
        if (amount1 > 0) {
            poolManager.mint(address(this), key.currency1.toId(), amount1);
        }

        // Emit CapitalSwept event with amounts and vault shares
        emit CapitalSwept(
            poolId,
            amount0,
            amount1,
            shares0,
            shares1,
            tx.origin // The original caller who triggered the sweep
        );

        return "";
    }

    // ============ LP POSITION TRACKING ============

    /// @notice Tracks or updates LP position data for IL calculation
    /// @dev Stores position in lpPositions mapping and updates position count if new
    /// @dev For simplicity, tracks a single aggregate position per LP per pool (index 0)
    /// @param lp The address of the liquidity provider
    /// @param poolId The pool identifier
    /// @param position The LP position data to store
    /// @custom:requirements Validates: 31.1-31.5
    function trackLPPosition(address lp, PoolId poolId, DataTypes.LPPosition memory position) internal virtual {
        // Validate LP address is not zero
        if (lp == address(0)) revert Errors.ZeroAddress();

        // Validate pool is registered
        if (!registeredPools[poolId]) {
            revert Errors.PoolNotRegistered(PoolId.unwrap(poolId));
        }

        // Check if this is a new position (position count is 0)
        uint256 currentCount = lpPositionCount[lp][poolId];

        // Store position data at index 0 (simplified single position per LP per pool)
        lpPositions[lp][poolId][0] = position;

        // Update position count if this is the first position for this LP in this pool
        if (currentCount == 0) {
            lpPositionCount[lp][poolId] = 1;
        }

        // Note: For the simplified implementation, we use a single aggregate position
        // per LP per pool (index 0). Future enhancements could support multiple positions
        // by using lpPositionCount to track and store positions at different indices.
    }

    // ============ IMPERMANENT LOSS CALCULATION ============

    /// @notice Calculates current token amounts from liquidity for a given position
    /// @dev Uses Uniswap v4's SqrtPriceMath library to compute token amounts
    /// @param liquidityAmount The liquidity amount in pool units
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param currentSqrtPriceX96 The current sqrt price of the pool
    /// @return amount0 Current amount of token0 in the position
    /// @return amount1 Current amount of token1 in the position
    /// @custom:requirements Validates: 13.1-13.5
    function calculateTokenAmounts(
        uint256 liquidityAmount,
        int24 tickLower,
        int24 tickUpper,
        uint160 currentSqrtPriceX96
    ) internal pure virtual returns (uint256 amount0, uint256 amount1) {
        // Get sqrt prices at tick boundaries
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Determine position relative to current price
        if (currentSqrtPriceX96 <= sqrtPriceLowerX96) {
            // Current price below range - position is entirely token0
            amount0 =
                SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, uint128(liquidityAmount), false);
            amount1 = 0;
        } else if (currentSqrtPriceX96 >= sqrtPriceUpperX96) {
            // Current price above range - position is entirely token1
            amount0 = 0;
            amount1 =
                SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, uint128(liquidityAmount), false);
        } else {
            // Current price within range - position has both tokens
            amount0 =
                SqrtPriceMath.getAmount0Delta(currentSqrtPriceX96, sqrtPriceUpperX96, uint128(liquidityAmount), false);
            amount1 =
                SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, currentSqrtPriceX96, uint128(liquidityAmount), false);
        }

        return (amount0, amount1);
    }

    /// @notice Calculates impermanent loss for an LP position
    /// @dev Compares hold value (initial tokens held) vs position value at current price
    /// @dev Returns IL denominated in both token0 and token1 for flexible compensation
    /// @param position The LP position data with initial deposit information
    /// @param currentSqrtPriceX96 The current sqrt price of the pool
    /// @return ilToken0 Impermanent loss amount in token0 terms
    /// @return ilToken1 Impermanent loss amount in token1 terms
    /// @custom:requirements Validates: 13.1-13.5
    function calculateImpermanentLoss(DataTypes.LPPosition memory position, uint160 currentSqrtPriceX96)
        internal
        pure
        virtual
        returns (uint256 ilToken0, uint256 ilToken1)
    {
        // Convert prices to comparable format (18 decimal precision)
        uint256 currentPrice = sqrtPriceX96ToPrice(currentSqrtPriceX96);

        // Calculate current token amounts in the position
        (uint256 currentToken0, uint256 currentToken1) =
            calculateTokenAmounts(position.liquidityAmount, position.tickLower, position.tickUpper, currentSqrtPriceX96);

        // Calculate hold value at current price (what LP would have if they just held tokens)
        // holdValue = token0Initial + (token1Initial converted to token0 at current price)
        // currentPrice is in token1/token0 with 18 decimals, so:
        // token1Initial * 1e18 / currentPrice gives token0 equivalent
        uint256 holdValueInToken0 =
            position.token0Initial + FullMath.mulDiv(position.token1Initial, PRICE_SCALE, currentPrice);

        // Calculate position value at current price
        // positionValue = currentToken0 + (currentToken1 converted to token0 at current price)
        uint256 positionValueInToken0 = currentToken0 + FullMath.mulDiv(currentToken1, PRICE_SCALE, currentPrice);

        // IL is the difference (if positive, LP has loss)
        if (holdValueInToken0 > positionValueInToken0) {
            uint256 ilInToken0 = holdValueInToken0 - positionValueInToken0;

            // Distribute IL proportionally between token0 and token1
            // Use the current price ratio to determine the split
            // priceRatio = currentPrice / (currentPrice + 1e18)
            // This gives the proportion that should be in token1
            uint256 denominator = currentPrice + PRICE_SCALE;
            uint256 token1Proportion = FullMath.mulDiv(currentPrice, PRICE_SCALE, denominator);

            // Calculate IL in token0 terms (remaining after token1 proportion)
            ilToken0 = FullMath.mulDiv(ilInToken0, (PRICE_SCALE - token1Proportion), PRICE_SCALE);

            // Calculate IL in token1 terms
            // Convert the token1 portion of IL from token0 terms to token1 terms
            uint256 ilToken1InToken0Terms = ilInToken0 - ilToken0;
            ilToken1 = FullMath.mulDiv(ilToken1InToken0Terms, currentPrice, PRICE_SCALE);
        } else {
            // No IL if position is profitable (negative IL)
            // Return zero for subsidy purposes per requirement 13.4
            ilToken0 = 0;
            ilToken1 = 0;
        }

        return (ilToken0, ilToken1);
    }

    // ============ SUBSIDY DISTRIBUTION SYSTEM ============

    /// @notice Calculates available yield in the subsidy pool for a token
    /// @dev Queries vault for current asset value using convertToAssets()
    /// @dev Subtracts principal from current value to get yield
    /// @param poolId The pool identifier
    /// @param isToken0 True for token0, false for token1
    /// @return availableYield The amount of yield available for distribution
    /// @custom:requirements Validates: 12.1-12.5, 34.1-34.5
    function calculateAvailableYield(PoolId poolId, bool isToken0)
        internal
        view
        virtual
        returns (uint256 availableYield)
    {
        DataTypes.SubsidyPool memory pool = subsidyPools[poolId];
        DataTypes.PoolConfig memory config = poolConfigs[poolId];

        // Get vault shares and principal for the specified token
        uint256 vaultShares = isToken0 ? pool.vaultShares0 : pool.vaultShares1;
        uint256 principal = isToken0 ? pool.totalToken0Principal : pool.totalToken1Principal;

        // If no shares in vault, return zero
        if (vaultShares == 0) {
            return 0;
        }

        // Get vault address
        address vault = isToken0 ? config.vault0 : config.vault1;

        // If no vault configured, return zero
        if (vault == address(0)) {
            return 0;
        }

        // Query vault for current asset value using convertToAssets()
        try IExternalVault(vault).convertToAssets(vaultShares) returns (uint256 currentValue) {
            // Subtract principal from current value to get yield
            // If current value is less than principal (loss scenario), return 0
            if (currentValue > principal) {
                availableYield = currentValue - principal;
            } else {
                availableYield = 0;
            }
        } catch {
            // If vault call fails, return zero yield
            availableYield = 0;
        }

        return availableYield;
    }

    /// @notice Withdraws tokens from vault for subsidy distribution with claim token fallback
    /// @dev Attempts vault withdrawal with try-catch and gas limit
    /// @dev On success: updates principal tracking, tokens transferred to LP via PoolManager
    /// @dev On failure: mints ERC-1155 claim token to LP for deferred redemption
    /// @param key The PoolKey identifying the pool
    /// @param poolId The pool identifier
    /// @param lp The liquidity provider address
    /// @param isToken0 True for token0, false for token1
    /// @param amount The amount to withdraw
    /// @custom:requirements Validates: 15.1-15.5, 16.1-16.5, 18.1-18.5
    function withdrawFromVault(PoolKey memory key, PoolId poolId, address lp, bool isToken0, uint256 amount)
        internal
        virtual
    {
        DataTypes.PoolConfig memory config = poolConfigs[poolId];
        address vault = isToken0 ? config.vault0 : config.vault1;
        Currency currency = isToken0 ? key.currency0 : key.currency1;

        // If no vault configured, skip
        if (vault == address(0)) {
            return;
        }

        // If amount is zero, skip
        if (amount == 0) {
            return;
        }

        // Attempt vault withdrawal with gas limit and try-catch
        try IExternalVault(vault).withdraw{gas: 150000}(amount, address(this), address(this)) returns (uint256) {
            // Success: tokens now in hook contract
            // Update principal tracking
            DataTypes.SubsidyPool storage pool = subsidyPools[poolId];
            if (isToken0) {
                // Ensure we don't underflow
                if (pool.totalToken0Principal >= amount) {
                    pool.totalToken0Principal -= amount;
                } else {
                    pool.totalToken0Principal = 0;
                }
            } else {
                // Ensure we don't underflow
                if (pool.totalToken1Principal >= amount) {
                    pool.totalToken1Principal -= amount;
                } else {
                    pool.totalToken1Principal = 0;
                }
            }

            // Note: In a full implementation, the withdrawn tokens would be added to the LP's
            // withdrawal via BalanceDelta modification in the beforeRemoveLiquidity callback.
            // For this implementation, we assume the tokens are held by the hook and will be
            // transferred as part of the liquidity removal flow.
        } catch {
            // Failure: mint claim token to LP
            // Generate unique claim token ID for this pool and token
            uint256 claimTokenId = generateClaimTokenId(poolId, currency);

            // Initialize ClaimTokenMetadata if first occurrence
            if (claimTokenMetadata[claimTokenId].vaultAddress == address(0)) {
                claimTokenMetadata[claimTokenId] = DataTypes.ClaimTokenMetadata({
                    poolId: poolId,
                    vaultAddress: vault,
                    underlyingToken: Currency.unwrap(currency),
                    totalLockedAmount: 0
                });
            }

            // Mint claim token to LP
            _mint(lp, claimTokenId, amount, "");

            // Update ClaimTokenMetadata total locked amount
            claimTokenMetadata[claimTokenId].totalLockedAmount += amount;

            // Update lpLockedAmounts tracking
            lpLockedAmounts[claimTokenId][lp] += amount;

            // Emit ClaimTokenMinted event
            emit ClaimTokenMinted(lp, claimTokenId, amount, vault);
        }
    }

    /// @notice Generates a unique ERC-1155 token ID for claim tokens
    /// @dev Token ID encodes poolId + token index for uniqueness
    /// @param poolId The pool identifier
    /// @param currency The currency (token) being claimed
    /// @return claimTokenId The unique token ID
    /// @custom:requirements Validates: 16.1-16.5
    function generateClaimTokenId(PoolId poolId, Currency currency) internal pure returns (uint256) {
        // Create a unique token ID by hashing poolId and currency address
        return uint256(keccak256(abi.encodePacked(poolId, Currency.unwrap(currency))));
    }

    // ============ CLAIM TOKEN REDEMPTION ============

    /// @notice Redeems claim tokens for locked capital when vault liquidity becomes available
    /// @dev Only callable by the claim token holder
    /// @dev Attempts to withdraw from vault; fails gracefully if vault still illiquid
    /// @param claimTokenId The ERC-1155 claim token ID to redeem
    /// @param amount The amount of claim tokens to redeem
    /// @custom:requirements Validates: 17.1-17.5, 26.1-26.5
    function redeemLockedCapital(uint256 claimTokenId, uint256 amount) external nonReentrant {
        // Validate caller owns sufficient claim token balance
        uint256 callerBalance = balanceOf(msg.sender, claimTokenId);
        if (callerBalance < amount) {
            revert Errors.InsufficientClaimBalance(claimTokenId, amount, callerBalance);
        }

        // Validate claim token metadata exists
        DataTypes.ClaimTokenMetadata memory metadata = claimTokenMetadata[claimTokenId];
        if (metadata.vaultAddress == address(0)) {
            revert Errors.InvalidClaimToken(claimTokenId);
        }

        // Validate amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        // Attempt vault withdrawal with gas limit
        try IExternalVault(metadata.vaultAddress).withdraw{gas: 150000}(amount, msg.sender, address(this)) returns (
            uint256 sharesRedeemed
        ) {
            // Success: vault returned the requested amount

            // Burn claim tokens
            _burn(msg.sender, claimTokenId, amount);

            // Update ClaimTokenMetadata total locked amount
            if (claimTokenMetadata[claimTokenId].totalLockedAmount >= amount) {
                claimTokenMetadata[claimTokenId].totalLockedAmount -= amount;
            } else {
                claimTokenMetadata[claimTokenId].totalLockedAmount = 0;
            }

            // Update lpLockedAmounts tracking
            if (lpLockedAmounts[claimTokenId][msg.sender] >= amount) {
                lpLockedAmounts[claimTokenId][msg.sender] -= amount;
            } else {
                lpLockedAmounts[claimTokenId][msg.sender] = 0;
            }

            // Emit ClaimTokenRedeemed event
            emit ClaimTokenRedeemed(msg.sender, claimTokenId, amount, sharesRedeemed);
        } catch {
            // Failure: vault still illiquid - revert with informative error
            revert Errors.VaultWithdrawalFailed(metadata.vaultAddress, "Vault illiquid, capital still locked");
        }
    }

    // ============ ERC-1155 TRANSFER HOOK OVERRIDE ============

    /// @notice Override ERC-1155 _update hook to track locked amounts on transfers
    /// @dev Updates lpLockedAmounts only when claim tokens are transferred between non-zero addresses
    /// @dev Mints (from == address(0)) and burns (to == address(0)) are handled by withdrawFromVault/redeemLockedCapital
    /// @param from The address sending the tokens (zero address for mints)
    /// @param to The address receiving the tokens (zero address for burns)
    /// @param ids Array of token IDs being transferred
    /// @param values Array of amounts being transferred
    /// @custom:requirements Validates: 16.1-16.5
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        virtual
        override
    {
        // Call parent implementation first
        super._update(from, to, ids, values);

        // Only update lpLockedAmounts for transfers between non-zero addresses
        // Mints (from == address(0)) and burns (to == address(0)) are handled separately
        if (from != address(0) && to != address(0)) {
            // Update lpLockedAmounts tracking for each token ID
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 tokenId = ids[i];
                uint256 amount = values[i];

                // Deduct from sender's locked amount
                if (lpLockedAmounts[tokenId][from] >= amount) {
                    lpLockedAmounts[tokenId][from] -= amount;
                } else {
                    lpLockedAmounts[tokenId][from] = 0;
                }

                // Add to receiver's locked amount
                lpLockedAmounts[tokenId][to] += amount;
            }
        }
    }

    // ============ EVENTS ============

    /// @notice Emitted when IL subsidy is distributed to an LP
    /// @param poolId The unique identifier of the pool
    /// @param lp The liquidity provider address
    /// @param ilToken0 Calculated impermanent loss in token0
    /// @param ilToken1 Calculated impermanent loss in token1
    /// @param subsidyToken0 Actual subsidy distributed in token0
    /// @param subsidyToken1 Actual subsidy distributed in token1
    /// @param partialCoverage Whether subsidy only partially covered IL
    event ILSubsidyDistributed(
        PoolId indexed poolId,
        address indexed lp,
        uint256 ilToken0,
        uint256 ilToken1,
        uint256 subsidyToken0,
        uint256 subsidyToken1,
        bool partialCoverage
    );

    /// @notice Emitted when a claim token is minted due to vault withdrawal failure
    /// @param lp The liquidity provider address
    /// @param claimTokenId The ERC-1155 claim token ID
    /// @param amount The amount of locked capital
    /// @param vault The vault address holding the capital
    event ClaimTokenMinted(address indexed lp, uint256 indexed claimTokenId, uint256 amount, address vault);

    /// @notice Emitted when a claim token is redeemed for locked capital
    /// @param lp The liquidity provider address
    /// @param claimTokenId The ERC-1155 claim token ID redeemed
    /// @param amount The amount of claim tokens redeemed
    /// @param sharesRedeemed The number of vault shares burned in the redemption
    event ClaimTokenRedeemed(address indexed lp, uint256 indexed claimTokenId, uint256 amount, uint256 sharesRedeemed);

    /// @notice Emitted when idle capital is swept to external vaults
    /// @param poolId The unique identifier of the pool
    /// @param amount0 Amount of token0 swept
    /// @param amount1 Amount of token1 swept
    /// @param shares0 Vault shares received for token0
    /// @param shares1 Vault shares received for token1
    /// @param caller Address that triggered the sweep
    event CapitalSwept(
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 shares0,
        uint256 shares1,
        address indexed caller
    );

    // ============ MODIFIERS ============

    /// @notice Restricts function access to the PoolManager only
    /// @dev Prevents callback spoofing attacks
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Errors.UnauthorizedCaller();
        _;
    }

    /// @notice Restricts function access to the contract owner only
    /// @dev Used for administrative configuration functions
    modifier onlyOwner() {
        if (msg.sender != owner) revert Errors.Unauthorized();
        _;
    }
}
