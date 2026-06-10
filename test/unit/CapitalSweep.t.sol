// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import "../mocks/MockERC4626Vault.sol";
import "../mocks/MockPoolManager.sol";
import "../mocks/MockERC20.sol";
import "../../src/YieldSubsidizedDirectionalHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @title CapitalSweepTest
/// @notice Test suite for idle capital detection and sweep operations (Requirements 8.1-8.8, 9.1-9.12, 10.1-10.8, 11.1-11.9)
contract CapitalSweepTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    MockERC4626Vault vault0;
    MockERC4626Vault vault1;
    MockPoolManager poolManager;
    MockERC20 token0;
    MockERC20 token1;
    YieldSubsidizedDirectionalHook hook;
    PoolKey testPoolKey;
    PoolId testPoolId;

    function setUp() public override {
        super.setUp();
        
        // Deploy mock contracts
        poolManager = new MockPoolManager();
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        vault0 = new MockERC4626Vault(address(token0));
        vault1 = new MockERC4626Vault(address(token1));
        
        // Deploy hook
        hook = new YieldSubsidizedDirectionalHook(IPoolManager(address(poolManager)));
        
        // Create test pool key
        testPoolKey = createPoolKey(
            address(token0),
            address(token1),
            3000, // 0.3% fee
            60,   // tick spacing
            address(hook)
        );
        testPoolId = testPoolKey.toId();
        
        // Initialize pool via hook's beforeInitialize
        vm.prank(address(poolManager));
        hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
        
        // Set initial pool state in mock pool manager
        // Price 1:1, tick 0
        poolManager.setSlot0(testPoolId, SQRT_PRICE_1_1, 0, 0, 0);
    }

    /// @notice Test idle capital detection for out-of-range positions (Req 8.1-8.5)
    function test_IdleCapitalDetection_OutOfRange() public {
        // Setup: Create positions that are out of range
        // Current tick is 0, create positions below (all token1) and above (all token0)
        
        int24[] memory tickLowers = new int24[](2);
        int24[] memory tickUppers = new int24[](2);
        uint128[] memory liquidityAmounts = new uint128[](2);
        
        // Position 1: Below current price (tick -120 to -60)
        // This position is entirely in token1
        tickLowers[0] = -120;
        tickUppers[0] = -60;
        liquidityAmounts[0] = 1000000000000000000; // 1e18
        
        // Position 2: Above current price (tick 60 to 120)
        // This position is entirely in token0
        tickLowers[1] = 60;
        tickUppers[1] = 120;
        liquidityAmounts[1] = 2000000000000000000; // 2e18
        
        // Call calculateIdleCapital
        (uint256 idleAmount0, uint256 idleAmount1) = hook.calculateIdleCapital(
            testPoolKey,
            tickLowers,
            tickUppers,
            liquidityAmounts
        );
        
        // Verify correct idle amounts returned
        // Position above current price should contribute to token0
        assertGt(idleAmount0, 0, "Should have idle token0");
        // Position below current price should contribute to token1
        assertGt(idleAmount1, 0, "Should have idle token1");
    }

    /// @notice Test idle capital detection returns zero for in-range positions (Req 8.3, 8.8)
    function test_IdleCapitalDetection_InRange() public {
        // Setup: Create positions that are in range (include current tick 0)
        
        int24[] memory tickLowers = new int24[](2);
        int24[] memory tickUppers = new int24[](2);
        uint128[] memory liquidityAmounts = new uint128[](2);
        
        // Position 1: Includes current tick (tick -60 to 60)
        tickLowers[0] = -60;
        tickUppers[0] = 60;
        liquidityAmounts[0] = 1000000000000000000; // 1e18
        
        // Position 2: Also includes current tick (tick -120 to 120)
        tickLowers[1] = -120;
        tickUppers[1] = 120;
        liquidityAmounts[1] = 2000000000000000000; // 2e18
        
        // Call calculateIdleCapital
        (uint256 idleAmount0, uint256 idleAmount1) = hook.calculateIdleCapital(
            testPoolKey,
            tickLowers,
            tickUppers,
            liquidityAmounts
        );
        
        // Verify zero idle amounts for in-range positions
        assertEq(idleAmount0, 0, "Should have zero idle token0");
        assertEq(idleAmount1, 0, "Should have zero idle token1");
    }

    /// @notice Test idle capital detection with mixed positions (Req 8.5)
    function test_IdleCapitalDetection_MixedPositions() public {
        // Setup: Create mix of in-range and out-of-range positions
        
        int24[] memory tickLowers = new int24[](3);
        int24[] memory tickUppers = new int24[](3);
        uint128[] memory liquidityAmounts = new uint128[](3);
        
        // Position 1: In-range (tick -60 to 60)
        tickLowers[0] = -60;
        tickUppers[0] = 60;
        liquidityAmounts[0] = 1000000000000000000; // 1e18
        
        // Position 2: Out of range below (tick -180 to -120)
        tickLowers[1] = -180;
        tickUppers[1] = -120;
        liquidityAmounts[1] = 500000000000000000; // 0.5e18
        
        // Position 3: Out of range above (tick 120 to 180)
        tickLowers[2] = 120;
        tickUppers[2] = 180;
        liquidityAmounts[2] = 750000000000000000; // 0.75e18
        
        // Call calculateIdleCapital
        (uint256 idleAmount0, uint256 idleAmount1) = hook.calculateIdleCapital(
            testPoolKey,
            tickLowers,
            tickUppers,
            liquidityAmounts
        );
        
        // Verify only out-of-range positions counted
        // Position above should contribute to token0
        assertGt(idleAmount0, 0, "Should have idle token0 from position above");
        // Position below should contribute to token1
        assertGt(idleAmount1, 0, "Should have idle token1 from position below");
    }
    
    /// @notice Test idle capital detection with zero liquidity positions (edge case)
    function test_IdleCapitalDetection_ZeroLiquidity() public {
        int24[] memory tickLowers = new int24[](2);
        int24[] memory tickUppers = new int24[](2);
        uint128[] memory liquidityAmounts = new uint128[](2);
        
        // Position 1: Out of range but zero liquidity
        tickLowers[0] = 60;
        tickUppers[0] = 120;
        liquidityAmounts[0] = 0;
        
        // Position 2: Out of range with liquidity
        tickLowers[1] = -120;
        tickUppers[1] = -60;
        liquidityAmounts[1] = 1000000000000000000; // 1e18
        
        // Call calculateIdleCapital
        (uint256 idleAmount0, uint256 idleAmount1) = hook.calculateIdleCapital(
            testPoolKey,
            tickLowers,
            tickUppers,
            liquidityAmounts
        );
        
        // Verify zero liquidity position doesn't contribute
        assertEq(idleAmount0, 0, "Zero liquidity position should not contribute to token0");
        assertGt(idleAmount1, 0, "Should have idle token1 from second position");
    }
    
    /// @notice Test revert when array lengths don't match (Req 8.1)
    function test_RevertWhen_ArrayLengthsMismatch() public {
        int24[] memory tickLowers = new int24[](2);
        int24[] memory tickUppers = new int24[](3); // Mismatch!
        uint128[] memory liquidityAmounts = new uint128[](2);
        
        tickLowers[0] = -60;
        tickLowers[1] = 60;
        tickUppers[0] = -30;
        tickUppers[1] = 90;
        tickUppers[2] = 120;
        liquidityAmounts[0] = 1e18;
        liquidityAmounts[1] = 2e18;
        
        // Expect revert with InvalidConfiguration error
        vm.expectRevert(
            abi.encodeWithSignature("InvalidConfiguration(string)", "Position array lengths must match")
        );
        hook.calculateIdleCapital(
            testPoolKey,
            tickLowers,
            tickUppers,
            liquidityAmounts
        );
    }
    
    /// @notice Test revert when pool not registered (Req 8.2)
    function test_RevertWhen_PoolNotRegistered() public {
        // Create unregistered pool key
        PoolKey memory unregisteredPoolKey = createPoolKey(
            address(0x999),
            address(0x888),
            3000,
            60,
            address(hook)
        );
        
        int24[] memory tickLowers = new int24[](1);
        int24[] memory tickUppers = new int24[](1);
        uint128[] memory liquidityAmounts = new uint128[](1);
        
        tickLowers[0] = -60;
        tickUppers[0] = 60;
        liquidityAmounts[0] = 1e18;
        
        // Expect revert with PoolNotRegistered error
        vm.expectRevert();
        hook.calculateIdleCapital(
            unregisteredPoolKey,
            tickLowers,
            tickUppers,
            liquidityAmounts
        );
    }

    /// @notice Test successful capital sweep (Req 9.1-9.3)
    function test_SuccessfulCapitalSweep() public {
        // TODO: Create idle capital
        // TODO: Call sweepIdleCapital
        // TODO: Verify capital moved to vaults
    }

    /// @notice Test capital sweep is permissionless (Req 9.2)
    function test_CapitalSweepIsPermissionless() public {
        // TODO: Call sweepIdleCapital from arbitrary address
        // TODO: Verify success
    }

    /// @notice Test revert when pool not registered (Req 9.3)
    function test_RevertWhen_SweepUnregisteredPool() public {
        // TODO: Attempt sweep on unregistered pool
        // TODO: Expect revert
    }

    /// @notice Test revert when vaults not configured (Req 9.4-9.5)
    function test_RevertWhen_VaultsNotConfigured() public {
        // TODO: Register pool without vault configuration
        // TODO: Attempt sweep
        // TODO: Expect revert
    }

    /// @notice Test revert when no idle capital (Req 9.7)
    function test_RevertWhen_NoIdleCapital() public {
        // TODO: Attempt sweep with all positions in-range
        // TODO: Expect revert
    }

    /// @notice Test revert when below minimum threshold (Req 9.8, 35.1-35.5)
    function test_RevertWhen_BelowMinimumThreshold() public {
        // TODO: Create small amount of idle capital
        // TODO: Attempt sweep
        // TODO: Expect revert
    }

    /// @notice Test flash accounting unlock callback (Req 10.1-10.2)
    function test_FlashAccountingUnlockCallback() public {
        // TODO: Trigger sweep
        // TODO: Verify poolManager.unlock called
        // TODO: Verify lockAcquired callback invoked
    }

    /// @notice Test take operations in flash accounting (Req 10.2-10.3)
    function test_TakeOperationsInFlashAccounting() public {
        // TODO: Trigger sweep
        // TODO: Verify take called for token0 and token1
        // TODO: Verify correct amounts withdrawn
    }

    /// @notice Test vault deposits during sweep (Req 10.4, 11.3, 11.5)
    function test_VaultDepositsInSweep() public {
        // TODO: Trigger sweep
        // TODO: Verify vault.deposit called for both tokens
        // TODO: Verify vault shares received
    }

    /// @notice Test delta accounting settlement (Req 10.4-10.5)
    function test_DeltaAccountingSettlement() public {
        // TODO: Trigger sweep
        // TODO: Verify deltas balanced to zero
        // TODO: Verify settle called
    }

    /// @notice Test revert when delta accounting fails (Req 10.5-10.6)
    function test_RevertWhen_DeltaAccountingFails() public {
        // TODO: Create scenario where delta doesn't balance
        // TODO: Expect revert
    }

    /// @notice Test SubsidyPool accounting updates (Req 9.11-9.12, 11.4, 12.1-12.2)
    function test_SubsidyPoolAccountingUpdates() public {
        // TODO: Trigger sweep
        // TODO: Verify principal amounts updated
        // TODO: Verify vault shares tracked
    }

    /// @notice Test vault share token tracking (Req 11.5, 34.1-34.2)
    function test_VaultShareTokenTracking() public {
        // TODO: Trigger sweep
        // TODO: Verify share balances recorded
        // TODO: Verify shares-to-assets mapping
    }

    /// @notice Test CapitalSwept event emission (Req 24.1-24.5)
    function test_CapitalSweptEventEmission() public {
        // TODO: Trigger sweep
        // TODO: Verify event emitted with all parameters
        // TODO: Verify caller address included
    }

    /// @notice Test vault deposit failure handling (Req 9.10, 11.6)
    function test_VaultDepositFailureHandling() public {
        // TODO: Configure vault to revert on deposit
        // TODO: Attempt sweep
        // TODO: Verify entire transaction reverts
    }

    /// @notice Test paused pool blocks sweep (Req 33.2)
    function test_PausedPoolBlocksSweep() public {
        // TODO: Pause pool
        // TODO: Attempt sweep
        // TODO: Expect revert
    }

    /// @notice Test reentrancy protection on sweep (Req 26.1-26.5)
    function test_ReentrancyProtectionOnSweep() public {
        // TODO: Attempt reentrant call during sweep
        // TODO: Expect revert
    }
}
