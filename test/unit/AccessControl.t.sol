// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import {YieldSubsidizedDirectionalHook} from "../../src/YieldSubsidizedDirectionalHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

/// @title AccessControlTest
/// @notice Test suite for access control mechanisms (Requirements 2.1-2.5, 22.1-22.5)
/// @dev Tests onlyPoolManager and onlyOwner modifiers, and ownership transfer functionality
contract AccessControlTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    
    YieldSubsidizedDirectionalHook public hook;
    MockPoolManager public mockPoolManager;
    PoolKey public testPoolKey;
    
    address public deployer;
    address public attacker;

    function setUp() public override {
        super.setUp();
        
        deployer = address(this);
        attacker = address(0x999);
        
        // Deploy mock PoolManager
        mockPoolManager = new MockPoolManager();
        
        // Deploy hook with mock PoolManager
        hook = new YieldSubsidizedDirectionalHook(IPoolManager(address(mockPoolManager)));
        
        // Create a test PoolKey
        testPoolKey = createPoolKey(
            address(0x1000), // token0
            address(0x2000), // token1
            3000,            // fee
            60,              // tickSpacing
            address(hook)    // hooks
        );
        
        vm.label(deployer, "Deployer");
        vm.label(attacker, "Attacker");
        vm.label(address(hook), "Hook");
        vm.label(address(mockPoolManager), "MockPoolManager");
    }

    // ============================================
    // Hook Callback Access Control Tests
    // ============================================

    /// @notice Test beforeInitialize reverts when called by non-PoolManager (Req 2.2, 2.5)
    function test_RevertWhen_BeforeInitializeCalledByNonPoolManager() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.UnauthorizedCaller.selector);
        hook.beforeInitialize(address(this), testPoolKey, SQRT_PRICE_1_1);
    }

    /// @notice Test beforeSwap reverts when called by non-PoolManager (Req 2.3, 2.5)
    function test_RevertWhen_BeforeSwapCalledByNonPoolManager() public {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        
        vm.prank(attacker);
        vm.expectRevert(Errors.UnauthorizedCaller.selector);
        hook.beforeSwap(address(this), testPoolKey, swapParams, "");
    }

    /// @notice Test beforeRemoveLiquidity reverts when called by non-PoolManager (Req 2.4, 2.5)
    function test_RevertWhen_BeforeRemoveLiquidityCalledByNonPoolManager() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: -1e18,
            salt: bytes32(0)
        });
        
        vm.prank(attacker);
        vm.expectRevert(Errors.UnauthorizedCaller.selector);
        hook.beforeRemoveLiquidity(address(this), testPoolKey, params, "");
    }

    /// @notice Test beforeInitialize succeeds when called by PoolManager (Req 2.2)
    function test_BeforeInitializeSucceedsWhenCalledByPoolManager() public {
        // This test verifies the modifier allows PoolManager through
        // The function should now execute successfully and return the correct selector
        vm.prank(address(mockPoolManager));
        bytes4 selector = hook.beforeInitialize(address(this), testPoolKey, SQRT_PRICE_1_1);
        
        // Verify correct selector is returned
        assertEq(selector, hook.beforeInitialize.selector, "Should return beforeInitialize selector");
    }

    /// @notice Test beforeSwap succeeds when called by PoolManager (Req 2.3)
    function test_BeforeSwapSucceedsWhenCalledByPoolManager() public {
        // First register the pool via beforeInitialize
        vm.prank(address(mockPoolManager));
        hook.beforeInitialize(address(this), testPoolKey, SQRT_PRICE_1_1);
        
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        
        // This test verifies the modifier allows PoolManager through
        // The function should now execute successfully without reverting
        vm.prank(address(mockPoolManager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(address(this), testPoolKey, swapParams, "");
        
        // Verify correct selector is returned
        assertEq(selector, hook.beforeSwap.selector, "Should return beforeSwap selector");
        // Verify ZERO_DELTA is returned
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA), "Should return ZERO_DELTA");
    }

    /// @notice Test beforeSwap reverts when pool is not registered (Req 2.8)
    function test_RevertWhen_BeforeSwapCalledOnUnregisteredPool() public {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        
        // Pool is not registered, should revert
        vm.prank(address(mockPoolManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolNotRegistered.selector, testPoolKey.toId()));
        hook.beforeSwap(address(this), testPoolKey, swapParams, "");
    }

    /// @notice Test beforeRemoveLiquidity succeeds when called by PoolManager (Req 2.4)
    function test_BeforeRemoveLiquiditySucceedsWhenCalledByPoolManager() public {
        // Register the pool first
        vm.prank(address(mockPoolManager));
        hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
        
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: -1e18,
            salt: bytes32(0)
        });
        
        // This test verifies the modifier allows PoolManager through
        // The function should succeed and return the selector (not revert with "Not implemented")
        vm.prank(address(mockPoolManager));
        bytes4 result = hook.beforeRemoveLiquidity(address(this), testPoolKey, params, "");
        
        // Verify it returns the correct selector
        assertEq(result, IHooks.beforeRemoveLiquidity.selector, "Should return correct selector");
    }

    /// @notice Fuzz test: beforeInitialize always reverts for non-PoolManager addresses
    function testFuzz_BeforeInitializeRevertsForNonPoolManager(address caller) public {
        vm.assume(caller != address(mockPoolManager));
        vm.assume(caller != address(0));
        
        vm.prank(caller);
        vm.expectRevert(Errors.UnauthorizedCaller.selector);
        hook.beforeInitialize(address(this), testPoolKey, SQRT_PRICE_1_1);
    }

    /// @notice Fuzz test: beforeSwap always reverts for non-PoolManager addresses
    function testFuzz_BeforeSwapRevertsForNonPoolManager(address caller) public {
        vm.assume(caller != address(mockPoolManager));
        vm.assume(caller != address(0));
        
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        
        vm.prank(caller);
        vm.expectRevert(Errors.UnauthorizedCaller.selector);
        hook.beforeSwap(address(this), testPoolKey, swapParams, "");
    }

    /// @notice Fuzz test: beforeRemoveLiquidity always reverts for non-PoolManager addresses
    function testFuzz_BeforeRemoveLiquidityRevertsForNonPoolManager(address caller) public {
        vm.assume(caller != address(mockPoolManager));
        vm.assume(caller != address(0));
        
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: -1e18,
            salt: bytes32(0)
        });
        
        vm.prank(caller);
        vm.expectRevert(Errors.UnauthorizedCaller.selector);
        hook.beforeRemoveLiquidity(address(this), testPoolKey, params, "");
    }

    // ============================================
    // Ownership and Administrative Access Control Tests
    // ============================================

    /// @notice Test deployer is initial owner (Req 2.1, 22.1)
    function test_DeployerIsInitialOwner() public view {
        assertEq(hook.owner(), deployer, "Deployer should be initial owner");
    }

    /// @notice Test transferOwnership reverts when called by non-owner (Req 22.2, 22.3)
    function test_RevertWhen_TransferOwnershipCalledByNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.Unauthorized.selector);
        hook.transferOwnership(attacker);
    }

    /// @notice Test transferOwnership succeeds when called by owner (Req 22.2, 22.4)
    function test_TransferOwnershipSucceedsWhenCalledByOwner() public {
        address newOwner = address(0x123);
        
        vm.prank(deployer);
        hook.transferOwnership(newOwner);
        
        assertEq(hook.owner(), newOwner, "Owner should be updated to newOwner");
    }

    /// @notice Test transferOwnership emits OwnershipTransferred event (Req 22.5)
    function test_TransferOwnershipEmitsEvent() public {
        address newOwner = address(0x123);
        
        vm.expectEmit(true, true, false, false, address(hook));
        emit YieldSubsidizedDirectionalHook.OwnershipTransferred(deployer, newOwner);
        
        vm.prank(deployer);
        hook.transferOwnership(newOwner);
    }

    /// @notice Test transferOwnership reverts with zero address (Req 22.2)
    function test_RevertWhen_TransferOwnershipToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(Errors.ZeroAddress.selector);
        hook.transferOwnership(address(0));
    }

    /// @notice Test new owner can call administrative functions (Req 22.4)
    function test_NewOwnerCanCallAdministrativeFunctions() public {
        address newOwner = address(0x123);
        address anotherOwner = address(0x456);
        
        // Transfer ownership to newOwner
        vm.prank(deployer);
        hook.transferOwnership(newOwner);
        
        // Old owner should NOT be able to transfer ownership
        vm.prank(deployer);
        vm.expectRevert(Errors.Unauthorized.selector);
        hook.transferOwnership(anotherOwner);
        
        // New owner SHOULD be able to transfer ownership
        vm.prank(newOwner);
        hook.transferOwnership(anotherOwner);
        
        assertEq(hook.owner(), anotherOwner, "Ownership should transfer to anotherOwner");
    }

    /// @notice Fuzz test: only owner can transfer ownership
    function testFuzz_OnlyOwnerCanTransferOwnership(address caller, address newOwner) public {
        vm.assume(caller != deployer);
        vm.assume(caller != address(0));
        vm.assume(newOwner != address(0));
        
        vm.prank(caller);
        vm.expectRevert(Errors.Unauthorized.selector);
        hook.transferOwnership(newOwner);
    }

    /// @notice Test ownership transfer chain (multiple transfers)
    function test_OwnershipTransferChain() public {
        address owner1 = address(0x111);
        address owner2 = address(0x222);
        address owner3 = address(0x333);
        
        // deployer -> owner1
        vm.prank(deployer);
        hook.transferOwnership(owner1);
        assertEq(hook.owner(), owner1);
        
        // owner1 -> owner2
        vm.prank(owner1);
        hook.transferOwnership(owner2);
        assertEq(hook.owner(), owner2);
        
        // owner2 -> owner3
        vm.prank(owner2);
        hook.transferOwnership(owner3);
        assertEq(hook.owner(), owner3);
        
        // Previous owners should no longer have access
        vm.prank(deployer);
        vm.expectRevert(Errors.Unauthorized.selector);
        hook.transferOwnership(deployer);
        
        vm.prank(owner1);
        vm.expectRevert(Errors.Unauthorized.selector);
        hook.transferOwnership(owner1);
        
        vm.prank(owner2);
        vm.expectRevert(Errors.Unauthorized.selector);
        hook.transferOwnership(owner2);
    }

    // ============================================
    // Storage Immutability Tests
    // ============================================

    /// @notice Test poolManager is immutable and correctly set (Req 2.1)
    function test_PoolManagerIsImmutableAndCorrect() public view {
        assertEq(address(hook.poolManager()), address(mockPoolManager), "PoolManager should be set to mock");
    }

    /// @notice Test owner storage is properly initialized (Req 2.1)
    function test_OwnerStorageIsProperlyInitialized() public view {
        address storedOwner = hook.owner();
        assertEq(storedOwner, deployer, "Owner should be deployer");
        assertTrue(storedOwner != address(0), "Owner should not be zero address");
    }

    // ============================================
    // Edge Case Tests
    // ============================================

    /// @notice Test that attacker cannot bypass access control by calling from contract
    function test_AttackerCannotBypassAccessControlViaContract() public {
        // Deploy malicious contract that tries to call hook
        MaliciousContract malicious = new MaliciousContract(hook);
        
        vm.expectRevert(Errors.UnauthorizedCaller.selector);
        malicious.attemptBeforeInitialize(testPoolKey);
    }

    /// @notice Test PoolManager address validation in constructor
    function test_RevertWhen_ConstructorCalledWithZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new YieldSubsidizedDirectionalHook(IPoolManager(address(0)));
    }
}

/// @title MaliciousContract
/// @notice Helper contract for testing access control bypass attempts
contract MaliciousContract {
    YieldSubsidizedDirectionalHook public hook;
    
    constructor(YieldSubsidizedDirectionalHook _hook) {
        hook = _hook;
    }
    
    function attemptBeforeInitialize(PoolKey memory poolKey) external {
        hook.beforeInitialize(address(this), poolKey, 79228162514264337593543950336);
    }
}
