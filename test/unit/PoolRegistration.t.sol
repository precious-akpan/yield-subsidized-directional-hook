// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import {YieldSubsidizedDirectionalHook} from "../../src/YieldSubsidizedDirectionalHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

/// @title PoolRegistrationTest
/// @notice Test suite for pool registration and initialization (Requirements 1.1-1.7, 30.1-30.5)
contract PoolRegistrationTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    YieldSubsidizedDirectionalHook public hook;
    MockPoolManager public mockPoolManager;
    PoolKey public testPoolKey;

    function setUp() public override {
        super.setUp();

        // Deploy mock PoolManager
        mockPoolManager = new MockPoolManager();

        // Deploy hook
        hook = new YieldSubsidizedDirectionalHook(IPoolManager(address(mockPoolManager)));

        // Create a test PoolKey
        testPoolKey = createPoolKey(
            address(0x1000), // token0
            address(0x2000), // token1
            3000, // 0.3% fee
            60, // tick spacing
            address(hook) // hooks contract
        );
    }

    /// @notice Test getHookPermissions returns correct flags (Req 1.1-1.2)
    function test_GetHookPermissions() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        // Verify beforeInitialize, beforeSwap, beforeRemoveLiquidity are true
        assertTrue(permissions.beforeInitialize, "beforeInitialize should be true");
        assertTrue(permissions.beforeSwap, "beforeSwap should be true");
        assertTrue(permissions.beforeRemoveLiquidity, "beforeRemoveLiquidity should be true");

        // Verify all other flags are false
        assertFalse(permissions.afterInitialize, "afterInitialize should be false");
        assertFalse(permissions.beforeAddLiquidity, "beforeAddLiquidity should be false");
        assertFalse(permissions.afterAddLiquidity, "afterAddLiquidity should be false");
        assertFalse(permissions.afterRemoveLiquidity, "afterRemoveLiquidity should be false");
        assertFalse(permissions.afterSwap, "afterSwap should be false");
        assertFalse(permissions.beforeDonate, "beforeDonate should be false");
        assertFalse(permissions.afterDonate, "afterDonate should be false");
        assertFalse(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta should be false");
        assertFalse(permissions.afterSwapReturnDelta, "afterSwapReturnDelta should be false");
        assertFalse(permissions.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be false");
        assertFalse(permissions.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be false");
    }

    /// @notice Test successful pool registration (Req 1.3-1.7)
    function test_SuccessfulPoolRegistration() public {
        PoolId poolId = testPoolKey.toId();

        // Verify pool is not registered initially
        assertFalse(hook.registeredPools(poolId), "Pool should not be registered initially");

        // Call beforeInitialize from PoolManager
        vm.prank(address(mockPoolManager));
        bytes4 selector = hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);

        // Verify correct selector returned
        assertEq(selector, hook.beforeInitialize.selector, "Should return beforeInitialize selector");

        // Verify pool is now registered
        assertTrue(hook.registeredPools(poolId), "Pool should be registered");
    }

    /// @notice Test duplicate pool registration reverts (Req 1.5)
    function test_RevertWhen_DuplicatePoolRegistration() public {
        // Register pool once
        vm.prank(address(mockPoolManager));
        hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);

        // Attempt to register same pool again - should revert
        vm.prank(address(mockPoolManager));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PoolAlreadyRegistered.selector, PoolId.unwrap(testPoolKey.toId()))
        );
        hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
    }

    /// @notice Test subsidy pool initialization (Req 30.1-30.5)
    function test_SubsidyPoolInitialization() public {
        PoolId poolId = testPoolKey.toId();

        // Register pool
        vm.prank(address(mockPoolManager));
        hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);

        // Verify SubsidyPool struct initialized with zeros
        (
            uint256 totalToken0Yield,
            uint256 totalToken1Yield,
            uint256 totalToken0Principal,
            uint256 totalToken1Principal,
            uint256 vaultShares0,
            uint256 vaultShares1
        ) = hook.subsidyPools(poolId);

        assertEq(totalToken0Yield, 0, "totalToken0Yield should be 0");
        assertEq(totalToken1Yield, 0, "totalToken1Yield should be 0");
        assertEq(totalToken0Principal, 0, "totalToken0Principal should be 0");
        assertEq(totalToken1Principal, 0, "totalToken1Principal should be 0");
        assertEq(vaultShares0, 0, "vaultShares0 should be 0");
        assertEq(vaultShares1, 0, "vaultShares1 should be 0");
    }

    /// @notice Test pool registration emits event (Req 30.5)
    function test_PoolRegistrationEmitsEvent() public {
        PoolId poolId = testPoolKey.toId();

        // Expect PoolRegistered event
        vm.expectEmit(true, false, false, true, address(hook));
        emit YieldSubsidizedDirectionalHook.PoolRegistered(poolId, testPoolKey, SQRT_PRICE_1_1);

        // Register pool
        vm.prank(address(mockPoolManager));
        hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
    }

    /// @notice Test beforeInitialize reverts when called by non-PoolManager (Req 1.3-1.4)
    function test_RevertWhen_NonPoolManagerCallsBeforeInitialize() public {
        vm.prank(ALICE);
        vm.expectRevert(Errors.UnauthorizedCaller.selector);
        hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
    }
}
