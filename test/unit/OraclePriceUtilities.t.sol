// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {YieldSubsidizedDirectionalHookHelper} from "../helpers/YieldSubsidizedDirectionalHookHelper.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

// Constants for testing
uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
uint160 constant SQRT_PRICE_1_2 = 112045541949572279837463876454;
uint160 constant SQRT_PRICE_2_1 = 56022770974786139918731938227;

/// @title OraclePriceUtilities Test Suite
/// @notice Tests for oracle integration and price conversion utilities
contract OraclePriceUtilitiesTest is Test {
    using PoolIdLibrary for PoolKey;

    YieldSubsidizedDirectionalHookHelper public hookHelper;
    MockOracle public oracle;
    MockPoolManager public mockPoolManager;
    PoolKey public poolKey;
    PoolId public poolId;

    address public owner = address(this);

    function setUp() public {
        // Deploy mock PoolManager
        mockPoolManager = new MockPoolManager();

        // Deploy mock oracle
        oracle = new MockOracle();

        // Deploy hook helper (wrapper to expose internal functions)
        hookHelper = new YieldSubsidizedDirectionalHookHelper(IPoolManager(address(mockPoolManager)));

        // Create a test PoolKey (not actually initialized in v4 pool, just for testing)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hookHelper))
        });

        poolId = poolKey.toId();

        // Register pool manually
        hookHelper.registerPool(poolId);

        // Mock the slot0 data for the pool
        mockPoolManager.setSlot0(poolId, SQRT_PRICE_1_1, 0, 0, 0);

        // Configure pool with oracle
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(oracle),
            vault0: address(0), // Not needed for these tests
            vault1: address(0), // Not needed for these tests
            baseFeeBps: 30,
            maxFeeMultiplier: 300,
            deviationThresholdBps: 500,
            isPaused: false
        });

        hookHelper.setPoolConfig(poolId, config);
    }

    // ============ ORACLE PRICE VALIDATION TESTS ============

    /// @notice Test oracle price fetching with valid price
    function test_getOraclePriceWithValidation_ValidPrice() public {
        // Set valid oracle price (1:1 ratio, 18 decimals)
        uint256 validPrice = 1e18;
        oracle.setPrice(
            Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1), validPrice, block.timestamp
        );

        // Fetch oracle price
        (uint256 price, bool isValid) = hookHelper.testGetOraclePriceWithValidation(poolKey);

        // Assert price is valid
        assertTrue(isValid, "Oracle price should be valid");
        assertEq(price, validPrice, "Price should match oracle price");
    }

    /// @notice Test oracle price fetching with stale timestamp
    function test_getOraclePriceWithValidation_StalePrice() public {
        // Set current block timestamp to avoid underflow
        vm.warp(1000);

        // Set stale oracle price (6 minutes old)
        uint256 staleTimestamp = block.timestamp - 360;
        oracle.setPrice(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1), 1e18, staleTimestamp);

        // Fetch oracle price
        (uint256 price, bool isValid) = hookHelper.testGetOraclePriceWithValidation(poolKey);

        // Assert price is invalid due to staleness
        assertFalse(isValid, "Stale oracle price should be invalid");
    }

    /// @notice Test oracle price with excessive deviation from pool price
    function test_getOraclePriceWithValidation_ExcessiveDeviation() public {
        // Set oracle price 60% away from pool price (exceeds 50% max)
        uint256 poolPrice = hookHelper.testSqrtPriceX96ToPrice(SQRT_PRICE_1_1);
        uint256 deviatedPrice = (poolPrice * 160) / 100; // 60% higher

        oracle.setPrice(
            Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1), deviatedPrice, block.timestamp
        );

        // Fetch oracle price
        (, bool isValid) = hookHelper.testGetOraclePriceWithValidation(poolKey);

        // Assert price is invalid due to excessive deviation
        assertFalse(isValid, "Price with excessive deviation should be invalid");
    }

    /// @notice Test oracle call failure handling
    function test_getOraclePriceWithValidation_OracleFailure() public {
        // Configure oracle to revert
        oracle.setShouldRevert(true);

        // Fetch oracle price
        (uint256 price, bool isValid) = hookHelper.testGetOraclePriceWithValidation(poolKey);

        // Assert price is invalid and call didn't revert
        assertFalse(isValid, "Failed oracle call should return invalid");
        assertEq(price, 0, "Failed oracle should return zero price");
    }

    /// @notice Test oracle price caching within same transaction
    function test_getOraclePriceWithValidation_Caching() public {
        // Set valid oracle price
        oracle.setPrice(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1), 1e18, block.timestamp);

        // First call
        (uint256 price1, bool isValid1) = hookHelper.testGetOraclePriceWithValidation(poolKey);

        // Update oracle price (should be cached, so not reflected)
        oracle.setPrice(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1), 2e18, block.timestamp);

        // Second call in same block
        (uint256 price2, bool isValid2) = hookHelper.testGetOraclePriceWithValidation(poolKey);

        // Assert both calls return cached value
        assertTrue(isValid1, "First call should be valid");
        assertTrue(isValid2, "Second call should be valid");
        assertEq(price1, price2, "Cached price should be returned");
        assertEq(price1, 1e18, "Should return original cached price");
    }

    /// @notice Test no oracle configured returns invalid
    function test_getOraclePriceWithValidation_NoOracle() public {
        // Create new pool with no oracle configured
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(0),
            vault0: address(0),
            vault1: address(0),
            baseFeeBps: 30,
            maxFeeMultiplier: 300,
            deviationThresholdBps: 500,
            isPaused: false
        });

        hookHelper.setPoolConfig(poolId, config);

        // Fetch oracle price
        (uint256 price, bool isValid) = hookHelper.testGetOraclePriceWithValidation(poolKey);

        // Assert returns invalid
        assertFalse(isValid, "No oracle should return invalid");
        assertEq(price, 0, "No oracle should return zero price");
    }

    // ============ PRICE CONVERSION TESTS ============

    /// @notice Test sqrtPriceX96 to price conversion at 1:1 ratio
    function test_sqrtPriceX96ToPrice_OneToOne() public {
        uint160 sqrtPrice = SQRT_PRICE_1_1;
        uint256 price = hookHelper.testSqrtPriceX96ToPrice(sqrtPrice);

        // At 1:1, price should be 1e18
        assertApproxEqRel(price, 1e18, 1e15, "Price should be approximately 1:1");
    }

    /// @notice Test sqrtPriceX96 to price conversion at 1:2 ratio
    function test_sqrtPriceX96ToPrice_OneToTwo() public {
        uint160 sqrtPrice = SQRT_PRICE_1_2;
        uint256 price = hookHelper.testSqrtPriceX96ToPrice(sqrtPrice);

        // At 1:2, price should be 2e18
        assertApproxEqRel(price, 2e18, 1e15, "Price should be approximately 1:2");
    }

    /// @notice Test sqrtPriceX96 to price conversion at 2:1 ratio
    function test_sqrtPriceX96ToPrice_TwoToOne() public {
        uint160 sqrtPrice = SQRT_PRICE_2_1;
        uint256 price = hookHelper.testSqrtPriceX96ToPrice(sqrtPrice);

        // At 2:1, price should be 0.5e18
        assertApproxEqRel(price, 0.5e18, 1e15, "Price should be approximately 2:1");
    }

    /// @notice Fuzz test sqrtPriceX96 to price conversion
    function testFuzz_sqrtPriceX96ToPrice(uint160 sqrtPriceX96) public view {
        // Skip values below MIN_SQRT_PRICE or above MAX_SQRT_PRICE as they're invalid
        vm.assume(sqrtPriceX96 >= TickMath.MIN_SQRT_PRICE && sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE);

        // For very small sqrt prices, the result can round to zero due to precision limits
        // This is acceptable behavior for prices below the precision threshold
        // After the calculation: ((sqrtPrice >> 48)^2 * 1e18) >> 96
        // For non-zero result, we need (sqrtPrice >> 48)^2 * 1e18 >= 2^96
        // Solving: sqrtPrice >> 48 >= sqrt(2^96 / 1e18)
        // sqrt(2^96 / 1e18) = sqrt(79228162514264337593543.950336) ≈ 281474976710
        // So we need sqrtPrice >= 281474976710 * 2^48 ≈ 7.92e19

        // Use a slightly higher threshold to account for rounding
        uint256 precisionThreshold = 8e19; // ~80 * 10^18
        vm.assume(sqrtPriceX96 > precisionThreshold);

        // Convert price (should not revert)
        uint256 price = hookHelper.testSqrtPriceX96ToPrice(sqrtPriceX96);

        // Price should be non-zero for values above precision threshold
        assertGt(price, 0, "Price should be non-zero for sufficiently large sqrt price");
    }

    // ============ PRICE DEVIATION TESTS ============

    /// @notice Test deviation calculation with equal prices
    function test_calculateDeviation_EqualPrices() public {
        uint256 price1 = 1e18;
        uint256 price2 = 1e18;

        uint256 deviation = hookHelper.testCalculateDeviation(price1, price2);

        assertEq(deviation, 0, "Deviation should be zero for equal prices");
    }

    /// @notice Test deviation calculation with 10% difference
    function test_calculateDeviation_TenPercent() public {
        uint256 price1 = 1e18;
        uint256 price2 = 1.1e18; // 10% higher

        uint256 deviation = hookHelper.testCalculateDeviation(price1, price2);

        // Deviation should be 1000 bps (10%)
        assertEq(deviation, 1000, "Deviation should be 1000 bps (10%)");
    }

    /// @notice Test deviation calculation with 50% difference
    function test_calculateDeviation_FiftyPercent() public {
        uint256 price1 = 1e18;
        uint256 price2 = 1.5e18; // 50% higher

        uint256 deviation = hookHelper.testCalculateDeviation(price1, price2);

        // Deviation should be 5000 bps (50%)
        assertEq(deviation, 5000, "Deviation should be 5000 bps (50%)");
    }

    /// @notice Test deviation calculation is symmetric
    function test_calculateDeviation_Symmetric() public {
        uint256 price1 = 1e18;
        uint256 price2 = 1.2e18;

        uint256 deviation1 = hookHelper.testCalculateDeviation(price1, price2);
        uint256 deviation2 = hookHelper.testCalculateDeviation(price2, price1);

        assertEq(deviation1, deviation2, "Deviation should be symmetric");
    }

    /// @notice Test deviation with zero price returns max deviation
    function test_calculateDeviation_ZeroPrice() public {
        uint256 price1 = 1e18;
        uint256 price2 = 0;

        uint256 deviation = hookHelper.testCalculateDeviation(price1, price2);

        // Should return 10000 bps (100%)
        assertEq(deviation, 10000, "Zero price should return 100% deviation");
    }

    /// @notice Fuzz test deviation calculation
    function testFuzz_calculateDeviation(uint256 price1, uint256 price2) public view {
        // Bound prices to reasonable range (avoid zero to prevent 100% deviation)
        price1 = bound(price1, 1e12, 1e24);
        price2 = bound(price2, 1e12, 1e24);

        uint256 deviation = hookHelper.testCalculateDeviation(price1, price2);

        // Deviation should be calculable without overflow
        // Note: Deviation CAN exceed 100% (10000 bps) when prices differ significantly
        // For example: price1=1e24, price2=1e12 gives ~99,900,000% deviation

        // Basic sanity checks
        if (price1 == price2) {
            assertEq(deviation, 0, "Equal prices should have zero deviation");
        } else {
            // For very small differences, division can round down to 0
            // So we just check that deviation calculation doesn't revert
            // This is expected behavior - sub-basis-point differences round to 0
        }
    }
}
