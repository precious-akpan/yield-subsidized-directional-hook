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
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        virtual
        returns (bytes4)
    {
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
    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        onlyPoolManager
        returns (bytes4)
    {
        revert("Not implemented");
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
            poolId,
            zeroForOne,
            isToxic,
            feeOverride,
            isValid ? oraclePrice : 0,
            poolPrice,
            deviation
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
    function getOraclePriceWithValidation(PoolKey calldata key) 
        internal 
        virtual
        returns (uint256 price, bool isValid) 
    {
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
            oraclePriceCache[block.number][poolId] = OracleCache({
                price: 0,
                timestamp: block.timestamp,
                isValid: false
            });
            return (0, false);
        }
        
        // Query oracle with try-catch and gas limit
        try IOracle(config.oracle).getPrice{gas: ORACLE_GAS_LIMIT}(
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1)
        ) returns (uint256 oraclePrice, uint256 oracleTimestamp) {
            
            // Validate timestamp for staleness (5 minute threshold)
            // Treat zero timestamp as stale
            // Handle edge case where oracle timestamp might be in future (test scenarios)
            bool isStale = oracleTimestamp == 0 ||
                          oracleTimestamp > block.timestamp || 
                          (block.timestamp - oracleTimestamp > ORACLE_STALENESS_THRESHOLD);
            if (isStale) {
                oraclePriceCache[block.number][poolId] = OracleCache({
                    price: oraclePrice,
                    timestamp: oracleTimestamp,
                    isValid: false
                });
                return (oraclePrice, false);
            }
            
            // Get current pool price for deviation check
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
            uint256 poolPrice = sqrtPriceX96ToPrice(sqrtPriceX96);
            
            // Validate price deviation from pool price (50% max)
            uint256 deviation = calculateDeviation(oraclePrice, poolPrice);
            bool deviationExceeded = deviation > MAX_PRICE_DEVIATION_BPS;
            
            if (deviationExceeded) {
                oraclePriceCache[block.number][poolId] = OracleCache({
                    price: oraclePrice,
                    timestamp: oracleTimestamp,
                    isValid: false
                });
                return (oraclePrice, false);
            }
            
            // Cache valid oracle price
            oraclePriceCache[block.number][poolId] = OracleCache({
                price: oraclePrice,
                timestamp: oracleTimestamp,
                isValid: true
            });
            
            return (oraclePrice, true);
            
        } catch {
            // Oracle call failed - cache as invalid and return
            oraclePriceCache[block.number][poolId] = OracleCache({
                price: 0,
                timestamp: block.timestamp,
                isValid: false
            });
            return (0, false);
        }
    }

    /// @notice Converts sqrtPriceX96 format to standard fixed-point price
    /// @dev Handles the Uniswap v4 sqrt(price) * 2^96 encoding
    /// @dev Returns price as token1 per token0 with 18 decimal precision
    /// @param sqrtPriceX96 The square root price in X96 format
    /// @return price The price in standard fixed-point format (18 decimals)
    /// @custom:requirements Validates: 4.1-4.4
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) 
        internal 
        pure 
        virtual
        returns (uint256 price) 
    {
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
    function calculateDeviation(uint256 price1, uint256 price2) 
        internal 
        pure 
        virtual
        returns (uint256 deviationBps) 
    {
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
    function calculateFeeMultiplier(
        uint256 deviationBps,
        DataTypes.PoolConfig memory config
    ) internal pure virtual returns (uint24) {
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
    function classifyFlow(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified
    ) internal virtual returns (bool isToxic, uint24 feeMultiplier) {
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
        uint256 estimatedPrice = estimatePostSwapPrice(
            currentPrice,
            zeroForOne,
            amountSpecified
        );
        
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
    function estimatePostSwapPrice(
        uint256 currentPrice,
        bool zeroForOne,
        int256 amountSpecified
    ) internal pure virtual returns (uint256 estimatedPrice) {
        // For a simplified estimation, we approximate price impact
        // In a real implementation, this would use:
        // 1. Current tick and liquidity from pool state
        // 2. SqrtPriceMath.getNextSqrtPriceFromInput/Output
        // 3. Tick boundaries and liquidity distribution
        
        // For now, we use a simplified directional heuristic:
        // - If zeroForOne (selling token0), price decreases (token1 per token0)
        // - If oneForZero (selling token1), price increases (token1 per token0)
        
        // Use absolute value of amountSpecified for magnitude
        uint256 absAmount = amountSpecified < 0 
            ? uint256(-amountSpecified) 
            : uint256(amountSpecified);
        
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
