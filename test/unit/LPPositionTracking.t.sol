// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import {YieldSubsidizedDirectionalHookHelper} from "../helpers/YieldSubsidizedDirectionalHookHelper.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

/// @title LPPositionTrackingTest
/// @notice Test suite for LP position tracking functionality (Requirements 31.1-31.5)
contract LPPositionTrackingTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    YieldSubsidizedDirectionalHookHelper public hook;
    MockPoolManager public mockPoolManager;
    PoolKey public testPoolKey;
    PoolId public testPoolId;

    address public testLP = address(0xABCD);

    function setUp() public override {
        super.setUp();
        
        // Deploy mock PoolManager
        mockPoolManager = new MockPoolManager();
        
        // Deploy hook helper (exposes internal functions)
        hook = new YieldSubsidizedDirectionalHookHelper(IPoolManager(address(mockPoolManager)));
        
        // Create a test PoolKey
        testPoolKey = createPoolKey(
            address(0x1000), // token0
            address(0x2000), // token1
            3000,            // 0.3% fee
            60,              // tick spacing
            address(hook)    // hooks contract
        );
        
        testPoolId = testPoolKey.toId();
        
        // Register the pool
        hook.registerPool(testPoolId);
    }

    /// @notice Test tracking a new LP position (Req 31.1-31.5)
    function test_TrackNewLPPosition() public {
        // Create a test position
        DataTypes.LPPosition memory position = DataTypes.LPPosition({
            token0Initial: 1000 ether,
            token1Initial: 2000 ether,
            sqrtPriceX96Initial: SQRT_PRICE_1_1,
            tickLower: -60,
            tickUpper: 60,
            liquidityAmount: 1500 ether,
            lastUpdateTimestamp: block.timestamp
        });
        
        // Track the position
        hook.testTrackLPPosition(testLP, testPoolId, position);
        
        // Verify position was stored correctly
        (
            uint256 token0Initial,
            uint256 token1Initial,
            uint160 sqrtPriceX96Initial,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidityAmount,
            uint256 lastUpdateTimestamp
        ) = hook.lpPositions(testLP, testPoolId, 0);
        
        assertEq(token0Initial, 1000 ether, "token0Initial should match");
        assertEq(token1Initial, 2000 ether, "token1Initial should match");
        assertEq(sqrtPriceX96Initial, SQRT_PRICE_1_1, "sqrtPriceX96Initial should match");
        assertEq(tickLower, -60, "tickLower should match");
        assertEq(tickUpper, 60, "tickUpper should match");
        assertEq(liquidityAmount, 1500 ether, "liquidityAmount should match");
        assertEq(lastUpdateTimestamp, block.timestamp, "lastUpdateTimestamp should match");
        
        // Verify position count was updated
        assertEq(hook.lpPositionCount(testLP, testPoolId), 1, "Position count should be 1");
    }

    /// @notice Test updating an existing LP position (Req 31.5)
    function test_UpdateExistingLPPosition() public {
        // Create initial position
        DataTypes.LPPosition memory initialPosition = DataTypes.LPPosition({
            token0Initial: 1000 ether,
            token1Initial: 2000 ether,
            sqrtPriceX96Initial: SQRT_PRICE_1_1,
            tickLower: -60,
            tickUpper: 60,
            liquidityAmount: 1500 ether,
            lastUpdateTimestamp: block.timestamp
        });
        
        // Track initial position
        hook.testTrackLPPosition(testLP, testPoolId, initialPosition);
        
        // Verify initial position count
        assertEq(hook.lpPositionCount(testLP, testPoolId), 1, "Initial position count should be 1");
        
        // Move time forward
        vm.warp(block.timestamp + 3600);
        
        // Create updated position (e.g., after adding more liquidity)
        DataTypes.LPPosition memory updatedPosition = DataTypes.LPPosition({
            token0Initial: 1500 ether,
            token1Initial: 3000 ether,
            sqrtPriceX96Initial: SQRT_PRICE_1_1,
            tickLower: -60,
            tickUpper: 60,
            liquidityAmount: 2250 ether,
            lastUpdateTimestamp: block.timestamp
        });
        
        // Update the position
        hook.testTrackLPPosition(testLP, testPoolId, updatedPosition);
        
        // Verify position was updated
        (
            uint256 token0Initial,
            uint256 token1Initial,
            ,
            ,
            ,
            uint256 liquidityAmount,
            uint256 lastUpdateTimestamp
        ) = hook.lpPositions(testLP, testPoolId, 0);
        
        assertEq(token0Initial, 1500 ether, "token0Initial should be updated");
        assertEq(token1Initial, 3000 ether, "token1Initial should be updated");
        assertEq(liquidityAmount, 2250 ether, "liquidityAmount should be updated");
        assertEq(lastUpdateTimestamp, block.timestamp, "lastUpdateTimestamp should be updated");
        
        // Verify position count remains 1 (not incremented for updates)
        assertEq(hook.lpPositionCount(testLP, testPoolId), 1, "Position count should still be 1");
    }

    /// @notice Test tracking positions for different LPs in same pool (Req 31.4)
    function test_TrackMultipleLPsInSamePool() public {
        address lp1 = address(0xABC1);
        address lp2 = address(0xABC2);
        
        // Create positions for two different LPs
        DataTypes.LPPosition memory position1 = DataTypes.LPPosition({
            token0Initial: 1000 ether,
            token1Initial: 2000 ether,
            sqrtPriceX96Initial: SQRT_PRICE_1_1,
            tickLower: -60,
            tickUpper: 60,
            liquidityAmount: 1500 ether,
            lastUpdateTimestamp: block.timestamp
        });
        
        DataTypes.LPPosition memory position2 = DataTypes.LPPosition({
            token0Initial: 500 ether,
            token1Initial: 1000 ether,
            sqrtPriceX96Initial: SQRT_PRICE_1_1,
            tickLower: -120,
            tickUpper: 120,
            liquidityAmount: 750 ether,
            lastUpdateTimestamp: block.timestamp
        });
        
        // Track positions for both LPs
        hook.testTrackLPPosition(lp1, testPoolId, position1);
        hook.testTrackLPPosition(lp2, testPoolId, position2);
        
        // Verify both positions were stored independently
        (uint256 lp1Token0, uint256 lp1Token1,,,,,) = hook.lpPositions(lp1, testPoolId, 0);
        (uint256 lp2Token0, uint256 lp2Token1,,,,,) = hook.lpPositions(lp2, testPoolId, 0);
        
        assertEq(lp1Token0, 1000 ether, "LP1 token0Initial should match");
        assertEq(lp1Token1, 2000 ether, "LP1 token1Initial should match");
        assertEq(lp2Token0, 500 ether, "LP2 token0Initial should match");
        assertEq(lp2Token1, 1000 ether, "LP2 token1Initial should match");
        
        // Verify position counts
        assertEq(hook.lpPositionCount(lp1, testPoolId), 1, "LP1 position count should be 1");
        assertEq(hook.lpPositionCount(lp2, testPoolId), 1, "LP2 position count should be 1");
    }

    /// @notice Test tracking positions for same LP across different pools
    function test_TrackSameLPAcrossDifferentPools() public {
        // Create a second pool
        PoolKey memory testPoolKey2 = createPoolKey(
            address(0x3000), // token0
            address(0x4000), // token1
            500,             // 0.05% fee
            10,              // tick spacing
            address(hook)    // hooks contract
        );
        PoolId testPoolId2 = testPoolKey2.toId();
        hook.registerPool(testPoolId2);
        
        // Create positions for same LP in different pools
        DataTypes.LPPosition memory positionPool1 = DataTypes.LPPosition({
            token0Initial: 1000 ether,
            token1Initial: 2000 ether,
            sqrtPriceX96Initial: SQRT_PRICE_1_1,
            tickLower: -60,
            tickUpper: 60,
            liquidityAmount: 1500 ether,
            lastUpdateTimestamp: block.timestamp
        });
        
        DataTypes.LPPosition memory positionPool2 = DataTypes.LPPosition({
            token0Initial: 3000 ether,
            token1Initial: 4000 ether,
            sqrtPriceX96Initial: SQRT_PRICE_1_1,
            tickLower: -10,
            tickUpper: 10,
            liquidityAmount: 3500 ether,
            lastUpdateTimestamp: block.timestamp
        });
        
        // Track positions in both pools
        hook.testTrackLPPosition(testLP, testPoolId, positionPool1);
        hook.testTrackLPPosition(testLP, testPoolId2, positionPool2);
        
        // Verify both positions were stored independently
        (uint256 pool1Token0, uint256 pool1Token1,,,,,) = hook.lpPositions(testLP, testPoolId, 0);
        (uint256 pool2Token0, uint256 pool2Token1,,,,,) = hook.lpPositions(testLP, testPoolId2, 0);
        
        assertEq(pool1Token0, 1000 ether, "Pool1 token0Initial should match");
        assertEq(pool1Token1, 2000 ether, "Pool1 token1Initial should match");
        assertEq(pool2Token0, 3000 ether, "Pool2 token0Initial should match");
        assertEq(pool2Token1, 4000 ether, "Pool2 token1Initial should match");
        
        // Verify position counts for each pool
        assertEq(hook.lpPositionCount(testLP, testPoolId), 1, "Pool1 position count should be 1");
        assertEq(hook.lpPositionCount(testLP, testPoolId2), 1, "Pool2 position count should be 1");
    }

    /// @notice Test revert when tracking position with zero address LP
    function test_RevertWhen_ZeroAddressLP() public {
        DataTypes.LPPosition memory position = DataTypes.LPPosition({
            token0Initial: 1000 ether,
            token1Initial: 2000 ether,
            sqrtPriceX96Initial: SQRT_PRICE_1_1,
            tickLower: -60,
            tickUpper: 60,
            liquidityAmount: 1500 ether,
            lastUpdateTimestamp: block.timestamp
        });
        
        // Attempt to track position with zero address LP
        vm.expectRevert(Errors.ZeroAddress.selector);
        hook.testTrackLPPosition(address(0), testPoolId, position);
    }

    /// @notice Test revert when tracking position for unregistered pool
    function test_RevertWhen_UnregisteredPool() public {
        // Create an unregistered pool
        PoolKey memory unregisteredPoolKey = createPoolKey(
            address(0x5000), // token0
            address(0x6000), // token1
            3000,            // 0.3% fee
            60,              // tick spacing
            address(hook)    // hooks contract
        );
        PoolId unregisteredPoolId = unregisteredPoolKey.toId();
        
        DataTypes.LPPosition memory position = DataTypes.LPPosition({
            token0Initial: 1000 ether,
            token1Initial: 2000 ether,
            sqrtPriceX96Initial: SQRT_PRICE_1_1,
            tickLower: -60,
            tickUpper: 60,
            liquidityAmount: 1500 ether,
            lastUpdateTimestamp: block.timestamp
        });
        
        // Attempt to track position in unregistered pool
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolNotRegistered.selector, PoolId.unwrap(unregisteredPoolId)));
        hook.testTrackLPPosition(testLP, unregisteredPoolId, position);
    }

    /// @notice Fuzz test: Track positions with various parameters
    function testFuzz_TrackLPPositionWithVariousParameters(
        uint256 token0Initial,
        uint256 token1Initial,
        uint160 sqrtPriceX96Initial,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityAmount
    ) public {
        // Bound inputs to reasonable ranges
        token0Initial = bound(token0Initial, 1, type(uint128).max);
        token1Initial = bound(token1Initial, 1, type(uint128).max);
        sqrtPriceX96Initial = uint160(bound(sqrtPriceX96Initial, 1, type(uint160).max));
        tickLower = int24(bound(int256(tickLower), -887272, 887272));
        tickUpper = int24(bound(int256(tickUpper), tickLower + 1, 887272));
        liquidityAmount = bound(liquidityAmount, 1, type(uint128).max);
        
        DataTypes.LPPosition memory position = DataTypes.LPPosition({
            token0Initial: token0Initial,
            token1Initial: token1Initial,
            sqrtPriceX96Initial: sqrtPriceX96Initial,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityAmount: liquidityAmount,
            lastUpdateTimestamp: block.timestamp
        });
        
        // Track position
        hook.testTrackLPPosition(testLP, testPoolId, position);
        
        // Verify position was stored
        (
            uint256 storedToken0,
            uint256 storedToken1,
            uint160 storedSqrtPrice,
            int24 storedTickLower,
            int24 storedTickUpper,
            uint256 storedLiquidity,
            uint256 storedTimestamp
        ) = hook.lpPositions(testLP, testPoolId, 0);
        
        assertEq(storedToken0, token0Initial, "Fuzz: token0Initial should match");
        assertEq(storedToken1, token1Initial, "Fuzz: token1Initial should match");
        assertEq(storedSqrtPrice, sqrtPriceX96Initial, "Fuzz: sqrtPriceX96Initial should match");
        assertEq(storedTickLower, tickLower, "Fuzz: tickLower should match");
        assertEq(storedTickUpper, tickUpper, "Fuzz: tickUpper should match");
        assertEq(storedLiquidity, liquidityAmount, "Fuzz: liquidityAmount should match");
        assertEq(storedTimestamp, block.timestamp, "Fuzz: lastUpdateTimestamp should match");
    }
}
