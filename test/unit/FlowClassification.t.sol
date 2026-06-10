// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldSubsidizedDirectionalHook} from "../../src/YieldSubsidizedDirectionalHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @title FlowClassification Unit Tests
/// @notice Tests for classifyFlow, estimatePostSwapPrice, and calculateFeeMultiplier functions
contract FlowClassificationTest is Test {
    using PoolIdLibrary for PoolKey;

    // Test contracts
    YieldSubsidizedDirectionalHookHarness public hook;
    MockPoolManager public poolManager;
    MockOracle public oracle;

    // Test addresses
    address public constant ALICE = address(0x1);
    address public constant TOKEN0 = address(0x100);
    address public constant TOKEN1 = address(0x200);

    // Test price values (18 decimals)
    uint256 public constant PRICE_1_TO_1 = 1e18;
    uint256 public constant PRICE_1_TO_2 = 2e18;
    uint256 public constant PRICE_1_TO_05 = 5e17;

    // Standard pool configuration
    uint24 public constant BASE_FEE_BPS = 30; // 0.3%
    uint24 public constant MAX_FEE_MULTIPLIER = 30000; // 3x multiplier
    uint24 public constant DEVIATION_THRESHOLD_BPS = 50; // 0.5%

    // Standard sqrt price (1:1)
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolKey public testPool;
    PoolId public testPoolId;

    function setUp() public {
        // Deploy mocks
        poolManager = new MockPoolManager();
        oracle = new MockOracle();

        // Deploy hook
        hook = new YieldSubsidizedDirectionalHookHarness(IPoolManager(address(poolManager)));

        // Create test pool
        testPool = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        testPoolId = testPool.toId();

        // Initialize pool in hook
        vm.prank(address(poolManager));
        hook.beforeInitialize(address(0), testPool, SQRT_PRICE_1_1);

        // Configure pool
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(oracle),
            vault0: address(0), // Not needed for flow classification tests
            vault1: address(0),
            baseFeeBps: BASE_FEE_BPS,
            maxFeeMultiplier: MAX_FEE_MULTIPLIER,
            deviationThresholdBps: DEVIATION_THRESHOLD_BPS,
            isPaused: false
        });
        hook.setPoolConfig(testPoolId, config);

        // Set up pool manager with initial price
        poolManager.setSlot0(testPoolId, SQRT_PRICE_1_1, 0, 0, 0);

        // Set up oracle with valid price
        oracle.setPrice(TOKEN0, TOKEN1, PRICE_1_TO_1);
    }

    // ============ classifyFlow Tests ============

    function test_classifyFlow_ToxicFlow_MovingAwayFromOracle() public {
        // Setup: Pool at 1:1, Oracle at 1:1, Swap will move price to 1.5:1 (away from oracle)
        oracle.setPrice(TOKEN0, TOKEN1, PRICE_1_TO_1);
        poolManager.setSlot0(testPoolId, SQRT_PRICE_1_1, 0, 0, 0);

        // Execute: Swap that moves price away
        (bool isToxic, uint24 feeMultiplier) = hook.exposed_classifyFlow(
            testPool,
            false, // oneForZero (buying token0, price increases)
            1e18 // amount
        );

        // Verify: Classified as toxic
        assertTrue(isToxic, "Swap should be classified as toxic");
        assertGt(feeMultiplier, BASE_FEE_BPS, "Fee should be higher than baseline");
    }

    function test_classifyFlow_BenignFlow_MovingTowardOracle() public {
        // Setup: Pool at 1:2, Oracle at 1:1, Swap will move price toward 1:1
        oracle.setPrice(TOKEN0, TOKEN1, PRICE_1_TO_1);
        // Set pool price higher than oracle (sqrtPrice for 2:1)
        poolManager.setSlot0(testPoolId, uint160(SQRT_PRICE_1_1 * 141 / 100), 0, 0, 0); // ~2:1

        // Execute: Swap that moves price toward oracle
        (bool isToxic, uint24 feeMultiplier) = hook.exposed_classifyFlow(
            testPool,
            true, // zeroForOne (selling token0, price decreases toward oracle)
            1e18
        );

        // Verify: Classified as benign
        assertFalse(isToxic, "Swap should be classified as benign");
        assertEq(feeMultiplier, BASE_FEE_BPS, "Fee should be baseline for benign flow");
    }

    function test_classifyFlow_InvalidOracle_FallbackToBaseFee() public {
        // Setup: Oracle returns stale price
        oracle.setStalePrice(TOKEN0, TOKEN1, PRICE_1_TO_1, 600); // 10 minutes old

        // Execute: Classification with invalid oracle
        (bool isToxic, uint24 feeMultiplier) = hook.exposed_classifyFlow(
            testPool,
            false,
            1e18
        );

        // Verify: Falls back to baseline fee
        assertFalse(isToxic, "Should not be toxic when oracle invalid");
        assertEq(feeMultiplier, BASE_FEE_BPS, "Should use baseline fee");
    }

    function test_classifyFlow_DeviationBelowThreshold_UseBaseFee() public {
        // Setup: Swap will cause small deviation below threshold
        oracle.setPrice(TOKEN0, TOKEN1, PRICE_1_TO_1);
        poolManager.setSlot0(testPoolId, SQRT_PRICE_1_1, 0, 0, 0);

        // Execute: Very small swap (low price impact)
        (bool isToxic, uint24 feeMultiplier) = hook.exposed_classifyFlow(
            testPool,
            false,
            1e15 // 0.001 tokens (very small amount)
        );

        // Verify: Even if toxic direction, small deviation uses base fee
        assertEq(feeMultiplier, BASE_FEE_BPS, "Small deviation should use base fee");
    }

    function test_classifyFlow_ZeroForOne_DecreasesPrice() public {
        // Setup
        oracle.setPrice(TOKEN0, TOKEN1, PRICE_1_TO_1);
        poolManager.setSlot0(testPoolId, SQRT_PRICE_1_1, 0, 0, 0);

        // Execute: zeroForOne swap (selling token0 for token1)
        (bool isToxic, uint24 feeMultiplier) = hook.exposed_classifyFlow(
            testPool,
            true, // zeroForOne
            1e18
        );

        // Verify: Price should move down, creating deviation
        // Since oracle is at 1:1 and we're moving down, it's toxic
        assertTrue(isToxic, "Moving down from 1:1 should be toxic");
    }

    function test_classifyFlow_OneForZero_IncreasesPrice() public {
        // Setup
        oracle.setPrice(TOKEN0, TOKEN1, PRICE_1_TO_1);
        poolManager.setSlot0(testPoolId, SQRT_PRICE_1_1, 0, 0, 0);

        // Execute: oneForZero swap (selling token1 for token0)
        (bool isToxic, uint24 feeMultiplier) = hook.exposed_classifyFlow(
            testPool,
            false, // oneForZero
            1e18
        );

        // Verify: Price should move up, creating deviation
        assertTrue(isToxic, "Moving up from 1:1 should be toxic");
    }

    // ============ estimatePostSwapPrice Tests ============

    function test_estimatePostSwapPrice_ZeroForOne_DecreasesPrice() public {
        uint256 currentPrice = PRICE_1_TO_1;
        bool zeroForOne = true;
        int256 amount = 1e18;

        uint256 estimatedPrice = hook.exposed_estimatePostSwapPrice(
            currentPrice,
            zeroForOne,
            amount
        );

        assertLt(estimatedPrice, currentPrice, "Price should decrease for zeroForOne swap");
    }

    function test_estimatePostSwapPrice_OneForZero_IncreasesPrice() public {
        uint256 currentPrice = PRICE_1_TO_1;
        bool zeroForOne = false;
        int256 amount = 1e18;

        uint256 estimatedPrice = hook.exposed_estimatePostSwapPrice(
            currentPrice,
            zeroForOne,
            amount
        );

        assertGt(estimatedPrice, currentPrice, "Price should increase for oneForZero swap");
    }

    function test_estimatePostSwapPrice_LargerAmount_LargerImpact() public {
        uint256 currentPrice = PRICE_1_TO_1;
        bool zeroForOne = true;

        uint256 estimatedPrice1 = hook.exposed_estimatePostSwapPrice(
            currentPrice,
            zeroForOne,
            1e18
        );

        uint256 estimatedPrice2 = hook.exposed_estimatePostSwapPrice(
            currentPrice,
            zeroForOne,
            10e18
        );

        assertLt(estimatedPrice2, estimatedPrice1, "Larger swap should have larger price impact");
    }

    function test_estimatePostSwapPrice_NegativeAmount_SameImpact() public {
        uint256 currentPrice = PRICE_1_TO_1;
        bool zeroForOne = true;

        uint256 estimatedPrice1 = hook.exposed_estimatePostSwapPrice(
            currentPrice,
            zeroForOne,
            1e18
        );

        uint256 estimatedPrice2 = hook.exposed_estimatePostSwapPrice(
            currentPrice,
            zeroForOne,
            -1e18
        );

        assertEq(estimatedPrice1, estimatedPrice2, "Absolute value should be used for amount");
    }

    function test_estimatePostSwapPrice_CappedAt50Percent() public {
        uint256 currentPrice = PRICE_1_TO_1;
        bool zeroForOne = true;
        int256 hugeAmount = 1000e18; // Very large swap

        uint256 estimatedPrice = hook.exposed_estimatePostSwapPrice(
            currentPrice,
            zeroForOne,
            hugeAmount
        );

        // Price impact should be capped at 50%
        uint256 minExpectedPrice = currentPrice / 2;
        assertGe(estimatedPrice, minExpectedPrice, "Price impact should be capped at 50%");
    }

    // ============ calculateFeeMultiplier Tests ============

    function test_calculateFeeMultiplier_ZeroDeviation_BaseMultiplier() public {
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(oracle),
            vault0: address(0),
            vault1: address(0),
            baseFeeBps: BASE_FEE_BPS,
            maxFeeMultiplier: MAX_FEE_MULTIPLIER,
            deviationThresholdBps: DEVIATION_THRESHOLD_BPS,
            isPaused: false
        });

        uint24 multiplier = hook.exposed_calculateFeeMultiplier(0, config);

        assertEq(multiplier, 10000, "Zero deviation should return 1.0x multiplier");
    }

    function test_calculateFeeMultiplier_AtThreshold_BaseMultiplier() public {
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(oracle),
            vault0: address(0),
            vault1: address(0),
            baseFeeBps: BASE_FEE_BPS,
            maxFeeMultiplier: MAX_FEE_MULTIPLIER,
            deviationThresholdBps: DEVIATION_THRESHOLD_BPS,
            isPaused: false
        });

        uint24 multiplier = hook.exposed_calculateFeeMultiplier(DEVIATION_THRESHOLD_BPS, config);

        // At threshold, multiplier should still be at base (1.0x = 10000)
        // The existing implementation treats threshold as the starting point
        assertGe(multiplier, 10000, "At threshold should be at least 1.0x");
        assertLe(multiplier, MAX_FEE_MULTIPLIER, "Should not exceed max");
    }

    function test_calculateFeeMultiplier_DoubleThreshold_HigherMultiplier() public {
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(oracle),
            vault0: address(0),
            vault1: address(0),
            baseFeeBps: BASE_FEE_BPS,
            maxFeeMultiplier: MAX_FEE_MULTIPLIER,
            deviationThresholdBps: DEVIATION_THRESHOLD_BPS,
            isPaused: false
        });

        uint24 multiplier = hook.exposed_calculateFeeMultiplier(DEVIATION_THRESHOLD_BPS * 2, config);

        assertGt(multiplier, 10000, "Double threshold should return multiplier > 1.0x");
        assertLe(multiplier, MAX_FEE_MULTIPLIER, "Should not exceed max multiplier");
    }

    function test_calculateFeeMultiplier_ExtremeDeviation_CappedAtMax() public {
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(oracle),
            vault0: address(0),
            vault1: address(0),
            baseFeeBps: BASE_FEE_BPS,
            maxFeeMultiplier: MAX_FEE_MULTIPLIER,
            deviationThresholdBps: DEVIATION_THRESHOLD_BPS,
            isPaused: false
        });

        uint24 multiplier = hook.exposed_calculateFeeMultiplier(10000, config); // 100% deviation

        assertEq(multiplier, MAX_FEE_MULTIPLIER, "Extreme deviation should be capped at max");
    }

    function test_calculateFeeMultiplier_LinearScaling() public {
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(oracle),
            vault0: address(0),
            vault1: address(0),
            baseFeeBps: BASE_FEE_BPS,
            maxFeeMultiplier: MAX_FEE_MULTIPLIER,
            deviationThresholdBps: DEVIATION_THRESHOLD_BPS,
            isPaused: false
        });

        // Test at 1x, 2x, and 3x threshold
        uint24 multiplier1x = hook.exposed_calculateFeeMultiplier(DEVIATION_THRESHOLD_BPS, config);
        uint24 multiplier2x = hook.exposed_calculateFeeMultiplier(DEVIATION_THRESHOLD_BPS * 2, config);
        uint24 multiplier3x = hook.exposed_calculateFeeMultiplier(DEVIATION_THRESHOLD_BPS * 3, config);

        // Verify scaling behavior
        // At threshold (1x), multiplier should be at base (1.0x = 10000)
        assertEq(multiplier1x, 10000, "At threshold should return base multiplier");
        
        // Above threshold should scale up, both should hit the cap at 30000 (3x)
        // because the formula scales quickly with 2x multiplier = 30000
        assertEq(multiplier2x, MAX_FEE_MULTIPLIER, "2x threshold should hit max multiplier");
        assertEq(multiplier3x, MAX_FEE_MULTIPLIER, "3x threshold should hit max multiplier");
    }
}

/// @notice Test harness to expose internal functions for testing
contract YieldSubsidizedDirectionalHookHarness is YieldSubsidizedDirectionalHook {
    constructor(IPoolManager _poolManager) YieldSubsidizedDirectionalHook(_poolManager) {}

    function exposed_classifyFlow(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified
    ) external returns (bool isToxic, uint24 feeMultiplier) {
        return classifyFlow(key, zeroForOne, amountSpecified);
    }

    function exposed_estimatePostSwapPrice(
        uint256 currentPrice,
        bool zeroForOne,
        int256 amountSpecified
    ) external pure returns (uint256) {
        return estimatePostSwapPrice(currentPrice, zeroForOne, amountSpecified);
    }

    function exposed_calculateFeeMultiplier(
        uint256 deviationBps,
        DataTypes.PoolConfig memory config
    ) external pure returns (uint24) {
        return calculateFeeMultiplier(deviationBps, config);
    }

    // Helper function to set pool config for testing
    function setPoolConfig(PoolId poolId, DataTypes.PoolConfig memory config) external {
        poolConfigs[poolId] = config;
    }
}
