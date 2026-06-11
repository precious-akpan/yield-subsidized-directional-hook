// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import "../mocks/MockPoolManager.sol";
import {YieldSubsidizedDirectionalHook} from "../../src/YieldSubsidizedDirectionalHook.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @title ILCalculation Test Suite
/// @notice Tests for impermanent loss calculation functionality
/// @dev Tests calculateImpermanentLoss and calculateTokenAmounts functions
contract ILCalculationTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    ILCalculationHelper public hookHelper;
    MockPoolManager public poolManager;

    function setUp() public override {
        super.setUp();
        poolManager = new MockPoolManager();
        hookHelper = new ILCalculationHelper(IPoolManager(address(poolManager)));
    }

    // ============ calculateTokenAmounts Tests ============

    /// @notice Test token amounts calculation when price is within range
    function test_CalculateTokenAmounts_PriceInRange() public view {
        // Setup position: tick range -1000 to 1000
        int24 tickLower = -1000;
        int24 tickUpper = 1000;
        uint256 liquidity = 1e18;

        // Current price at tick 0 (1:1 ratio, within range)
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        (uint256 amount0, uint256 amount1) =
            hookHelper.testCalculateTokenAmounts(liquidity, tickLower, tickUpper, sqrtPriceX96);

        // When price is in range, should have both tokens
        assertTrue(amount0 > 0, "Should have token0");
        assertTrue(amount1 > 0, "Should have token1");
    }

    /// @notice Test token amounts when price is below range (all token0)
    function test_CalculateTokenAmounts_PriceBelowRange() public view {
        // Setup position: tick range 1000 to 2000
        int24 tickLower = 1000;
        int24 tickUpper = 2000;
        uint256 liquidity = 1e18;

        // Current price at tick 0 (below range)
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        (uint256 amount0, uint256 amount1) =
            hookHelper.testCalculateTokenAmounts(liquidity, tickLower, tickUpper, sqrtPriceX96);

        // When price is below range, should have only token0
        assertTrue(amount0 > 0, "Should have token0");
        assertEq(amount1, 0, "Should have no token1");
    }

    /// @notice Test token amounts when price is above range (all token1)
    function test_CalculateTokenAmounts_PriceAboveRange() public view {
        // Setup position: tick range -2000 to -1000
        int24 tickLower = -2000;
        int24 tickUpper = -1000;
        uint256 liquidity = 1e18;

        // Current price at tick 0 (above range)
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        (uint256 amount0, uint256 amount1) =
            hookHelper.testCalculateTokenAmounts(liquidity, tickLower, tickUpper, sqrtPriceX96);

        // When price is above range, should have only token1
        assertEq(amount0, 0, "Should have no token0");
        assertTrue(amount1 > 0, "Should have token1");
    }

    // ============ calculateImpermanentLoss Tests ============

    /// @notice Test IL when LP is at a loss (price moved away from initial)
    function test_CalculateImpermanentLoss_WithLoss() public view {
        // Create position with initial 1:1 price ratio
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        DataTypes.LPPosition memory position = DataTypes.LPPosition({
            token0Initial: 1e18,
            token1Initial: 1e18,
            sqrtPriceX96Initial: initialSqrtPriceX96,
            tickLower: -1000,
            tickUpper: 1000,
            liquidityAmount: 1e18,
            lastUpdateTimestamp: block.timestamp
        });

        // Price moves to 2:1 (token1 becomes more valuable)
        // This is tick ~6932 (log_1.0001(2) * 10000 ≈ 6931.47)
        uint160 currentSqrtPriceX96 = TickMath.getSqrtPriceAtTick(6931);

        (uint256 ilToken0, uint256 ilToken1) = hookHelper.testCalculateImpermanentLoss(position, currentSqrtPriceX96);

        // Should have some IL when price moves significantly
        assertTrue(ilToken0 > 0 || ilToken1 > 0, "Should have impermanent loss");
    }

    /// @notice Test IL when LP is profitable (position value > hold value)
    function test_CalculateImpermanentLoss_NoLoss_Profitable() public view {
        // Create position with initial price
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        // Artificially set initial tokens higher than what position would yield
        // This simulates a scenario where the position is profitable
        DataTypes.LPPosition memory position = DataTypes.LPPosition({
            token0Initial: 1e17, // Small initial deposit
            token1Initial: 1e17,
            sqrtPriceX96Initial: initialSqrtPriceX96,
            tickLower: -1000,
            tickUpper: 1000,
            liquidityAmount: 1e19, // Large liquidity (simulating value increase)
            lastUpdateTimestamp: block.timestamp
        });

        // Current price same as initial
        uint160 currentSqrtPriceX96 = initialSqrtPriceX96;

        (uint256 ilToken0, uint256 ilToken1) = hookHelper.testCalculateImpermanentLoss(position, currentSqrtPriceX96);

        // IL should be zero when profitable (per requirement 13.4)
        assertEq(ilToken0, 0, "IL token0 should be zero");
        assertEq(ilToken1, 0, "IL token1 should be zero");
    }

    /// @notice Test IL calculation with no price change
    function test_CalculateImpermanentLoss_NoPriceChange() public view {
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        // Calculate what the actual token amounts would be for this liquidity
        uint256 liquidity = 1e18;
        int24 tickLower = -1000;
        int24 tickUpper = 1000;

        (uint256 token0Initial, uint256 token1Initial) =
            hookHelper.testCalculateTokenAmounts(liquidity, tickLower, tickUpper, initialSqrtPriceX96);

        DataTypes.LPPosition memory position = DataTypes.LPPosition({
            token0Initial: token0Initial,
            token1Initial: token1Initial,
            sqrtPriceX96Initial: initialSqrtPriceX96,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityAmount: liquidity,
            lastUpdateTimestamp: block.timestamp
        });

        // Current price same as initial
        uint160 currentSqrtPriceX96 = initialSqrtPriceX96;

        (uint256 ilToken0, uint256 ilToken1) = hookHelper.testCalculateImpermanentLoss(position, currentSqrtPriceX96);

        // With no price change and consistent initial amounts, IL should be zero
        assertEq(ilToken0, 0, "IL token0 should be zero");
        assertEq(ilToken1, 0, "IL token1 should be zero");
    }

    /// @notice Test IL calculation with position out of range
    function test_CalculateImpermanentLoss_OutOfRange() public view {
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        DataTypes.LPPosition memory position = DataTypes.LPPosition({
            token0Initial: 1e18,
            token1Initial: 1e18,
            sqrtPriceX96Initial: initialSqrtPriceX96,
            tickLower: 1000, // Position range above current price
            tickUpper: 2000,
            liquidityAmount: 1e18,
            lastUpdateTimestamp: block.timestamp
        });

        // Price stays at tick 0 (out of range)
        uint160 currentSqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        (uint256 ilToken0, uint256 ilToken1) = hookHelper.testCalculateImpermanentLoss(position, currentSqrtPriceX96);

        // Out of range positions should still calculate IL correctly
        // The position is all in token0, while initial had both tokens
        assertTrue(ilToken0 > 0 || ilToken1 > 0, "Should calculate IL for out-of-range position");
    }

    /// @notice Test IL calculation with significant price increase
    function test_CalculateImpermanentLoss_LargePriceIncrease() public view {
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        DataTypes.LPPosition memory position = DataTypes.LPPosition({
            token0Initial: 1e18,
            token1Initial: 1e18,
            sqrtPriceX96Initial: initialSqrtPriceX96,
            tickLower: -5000,
            tickUpper: 5000,
            liquidityAmount: 1e18,
            lastUpdateTimestamp: block.timestamp
        });

        // Large price increase to ~4:1 ratio
        uint160 currentSqrtPriceX96 = TickMath.getSqrtPriceAtTick(13862);

        (uint256 ilToken0, uint256 ilToken1) = hookHelper.testCalculateImpermanentLoss(position, currentSqrtPriceX96);

        // Should have significant IL with large price move
        assertTrue(ilToken0 > 0 || ilToken1 > 0, "Should have impermanent loss");
    }
}

/// @title ILCalculation Helper Contract
/// @notice Helper contract to expose internal functions for testing
contract ILCalculationHelper is YieldSubsidizedDirectionalHook {
    constructor(IPoolManager _poolManager) YieldSubsidizedDirectionalHook(_poolManager) {}

    function testCalculateTokenAmounts(
        uint256 liquidityAmount,
        int24 tickLower,
        int24 tickUpper,
        uint160 currentSqrtPriceX96
    ) external pure returns (uint256 amount0, uint256 amount1) {
        return calculateTokenAmounts(liquidityAmount, tickLower, tickUpper, currentSqrtPriceX96);
    }

    function testCalculateImpermanentLoss(DataTypes.LPPosition memory position, uint160 currentSqrtPriceX96)
        external
        pure
        returns (uint256 ilToken0, uint256 ilToken1)
    {
        return calculateImpermanentLoss(position, currentSqrtPriceX96);
    }
}
