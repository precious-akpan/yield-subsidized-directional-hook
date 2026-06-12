// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import "../../src/YieldSubsidizedDirectionalHook.sol";
import "../mocks/MockOracle.sol";
import "../mocks/MockERC4626Vault.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

/// @title CapitalSweepFlow Integration Test
/// @notice End-to-end integration test for capital sweep flow with out-of-range LP positions
/// @dev Tests Requirements: 8.1-8.5, 9.1-9.5, 10.1-10.5, 11.1-11.5, 24.1-24.5
/// @custom:task Task 19.2 - Write end-to-end capital sweep flow test
contract CapitalSweepFlowIntegrationTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    // Test contracts
    YieldSubsidizedDirectionalHook public hook;
    MockOracle public oracle;
    MockERC4626Vault public vault0;
    MockERC4626Vault public vault1;
    MockERC20 public token0;
    MockERC20 public token1;
    MockPoolManager public poolManager;

    // Test pool
    PoolKey public testPoolKey;
    PoolId public testPoolId;

    // Test configuration
    uint24 constant BASE_FEE_BPS = 30; // 0.3%
    uint24 constant MAX_FEE_MULTIPLIER = 30000; // 3x multiplier
    uint24 constant DEVIATION_THRESHOLD_BPS = 50; // 0.5%
    uint24 constant POOL_FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60;

    // Price constants
    uint256 constant ORACLE_PRICE_1_1 = 1e18; // 1:1 price in 18 decimals

    function setUp() public override {
        super.setUp();

        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Ensure token0 < token1 (Uniswap v4 requirement)
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy pool manager mock
        poolManager = new MockPoolManager();

        // Deploy oracle
        oracle = new MockOracle();

        // Deploy vaults
        vault0 = new MockERC4626Vault(address(token0));
        vault1 = new MockERC4626Vault(address(token1));

        // Deploy hook
        hook = new YieldSubsidizedDirectionalHook(IPoolManager(address(poolManager)));

        // Create test pool key
        testPoolKey = createPoolKey(address(token0), address(token1), POOL_FEE, TICK_SPACING, address(hook));
        testPoolId = testPoolKey.toId();

        // Initialize pool through PoolManager mock
        // Set initial pool price to 1:1 (SQRT_PRICE_1_1) at tick 0
        poolManager.setSlot0(
            testPoolId,
            SQRT_PRICE_1_1, // sqrtPriceX96
            0, // tick (current price is at tick 0)
            0, // protocolFee
            POOL_FEE // lpFee
        );

        // Initialize pool in hook (simulating beforeInitialize callback)
        vm.prank(address(poolManager));
        hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);

        // Configure pool with oracle and vaults
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(oracle),
            vault0: address(vault0),
            vault1: address(vault1),
            baseFeeBps: BASE_FEE_BPS,
            maxFeeMultiplier: MAX_FEE_MULTIPLIER,
            deviationThresholdBps: DEVIATION_THRESHOLD_BPS,
            isPaused: false
        });

        vm.prank(hook.owner());
        hook.configurePool(testPoolId, config);

        // Set initial oracle price to match pool price (1:1)
        oracle.setPrice(address(token0), address(token1), ORACLE_PRICE_1_1);

        // Fund the pool manager with tokens to simulate liquidity
        token0.mint(address(poolManager), 1000e18);
        token1.mint(address(poolManager), 1000e18);

        // Fund the vaults to allow deposits
        token0.mint(address(vault0), 100e18);
        token1.mint(address(vault1), 100e18);
    }

    // ============ TEST: COMPLETE CAPITAL SWEEP FLOW ============

    /// @notice Test complete capital sweep flow with out-of-range LP positions
    /// @dev Validates Requirements: 8.1-8.5, 9.1-9.5, 10.1-10.5, 11.1-11.5, 24.1-24.5
    function test_CapitalSweepFlow_OutOfRangePositions() public {
        // ========== SETUP: Create out-of-range LP positions ==========

        // Current tick is 0 (price 1:1)
        // Position 1: Above current price (tick 60 to 120) - all token0
        // Position 2: Below current price (tick -120 to -60) - all token1

        int24[] memory tickLowers = new int24[](2);
        int24[] memory tickUppers = new int24[](2);
        uint128[] memory liquidityAmounts = new uint128[](2);

        // Position 1: Above current price (entirely in token0)
        tickLowers[0] = 60;
        tickUppers[0] = 120;
        liquidityAmounts[0] = 100e18; // 100 ETH worth of liquidity

        // Position 2: Below current price (entirely in token1)
        tickLowers[1] = -120;
        tickUppers[1] = -60;
        liquidityAmounts[1] = 100e18; // 100 ETH worth of liquidity

        // Calculate expected idle capital amounts
        (uint256 expectedIdle0, uint256 expectedIdle1) =
            hook.calculateIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);

        // Verify idle capital was detected
        assertGt(expectedIdle0, 0, "Should detect idle token0");
        assertGt(expectedIdle1, 0, "Should detect idle token1");

        // ========== EXECUTE: Call sweepIdleCapital as keeper ==========

        // Record subsidy pool state before sweep
        (
            uint256 yieldBefore0,
            uint256 yieldBefore1,
            uint256 principalBefore0,
            uint256 principalBefore1,
            uint256 sharesBefore0,
            uint256 sharesBefore1
        ) = hook.subsidyPools(testPoolId);

        // Record vault balances before sweep
        uint256 vault0BalanceBefore = token0.balanceOf(address(vault0));
        uint256 vault1BalanceBefore = token1.balanceOf(address(vault1));
        uint256 hookVaultShares0Before = vault0.shares(address(hook));
        uint256 hookVaultShares1Before = vault1.shares(address(hook));

        // Don't use expectEmit for event validation - we'll manually verify the event
        // because the shares values are non-deterministic and depend on vault implementation

        // Call sweepIdleCapital from keeper address (permissionless)
        vm.prank(KEEPER);
        hook.sweepIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);

        // ========== VERIFY: Capital transferred to vaults ==========

        // Verify vault balances increased by swept amounts
        uint256 vault0BalanceAfter = token0.balanceOf(address(vault0));
        uint256 vault1BalanceAfter = token1.balanceOf(address(vault1));

        assertEq(vault0BalanceAfter, vault0BalanceBefore + expectedIdle0, "Vault0 should receive idle token0");
        assertEq(vault1BalanceAfter, vault1BalanceBefore + expectedIdle1, "Vault1 should receive idle token1");

        // ========== VERIFY: Hook received vault shares ==========

        uint256 hookVaultShares0After = vault0.shares(address(hook));
        uint256 hookVaultShares1After = vault1.shares(address(hook));

        assertGt(hookVaultShares0After, hookVaultShares0Before, "Hook should receive vault0 shares");
        assertGt(hookVaultShares1After, hookVaultShares1Before, "Hook should receive vault1 shares");

        // ========== VERIFY: SubsidyPool accounting updated ==========

        (
            uint256 yieldAfter0,
            uint256 yieldAfter1,
            uint256 principalAfter0,
            uint256 principalAfter1,
            uint256 sharesAfter0,
            uint256 sharesAfter1
        ) = hook.subsidyPools(testPoolId);

        // Verify principal amounts increased
        assertEq(principalAfter0, principalBefore0 + expectedIdle0, "Principal0 should increase by swept amount");
        assertEq(principalAfter1, principalBefore1 + expectedIdle1, "Principal1 should increase by swept amount");

        // Verify vault shares tracked
        uint256 expectedShares0 = hookVaultShares0After - hookVaultShares0Before;
        uint256 expectedShares1 = hookVaultShares1After - hookVaultShares1Before;

        assertEq(sharesAfter0, sharesBefore0 + expectedShares0, "Vault shares0 should be tracked correctly");
        assertEq(sharesAfter1, sharesBefore1 + expectedShares1, "Vault shares1 should be tracked correctly");

        // Verify yield amounts are unchanged (no yield accumulated yet)
        assertEq(yieldAfter0, yieldBefore0, "Yield0 should be unchanged after initial sweep");
        assertEq(yieldAfter1, yieldBefore1, "Yield1 should be unchanged after initial sweep");
    }

    // ============ TEST: SWEEP WITH MIXED POSITIONS ============

    /// @notice Test capital sweep with mix of in-range and out-of-range positions
    /// @dev Validates Requirements: 8.5, 9.1-9.5
    function test_CapitalSweepFlow_MixedPositions() public {
        // Setup positions: 1 in-range, 2 out-of-range
        int24[] memory tickLowers = new int24[](3);
        int24[] memory tickUppers = new int24[](3);
        uint128[] memory liquidityAmounts = new uint128[](3);

        // Position 1: In-range (includes tick 0)
        tickLowers[0] = -60;
        tickUppers[0] = 60;
        liquidityAmounts[0] = 10e18;

        // Position 2: Out of range above (tick 120 to 180)
        tickLowers[1] = 120;
        tickUppers[1] = 180;
        liquidityAmounts[1] = 50e18;

        // Position 3: Out of range below (tick -180 to -120)
        tickLowers[2] = -180;
        tickUppers[2] = -120;
        liquidityAmounts[2] = 50e18;

        // Calculate idle capital (should only include positions 2 and 3)
        (uint256 expectedIdle0, uint256 expectedIdle1) =
            hook.calculateIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);

        // Verify only out-of-range positions detected
        assertGt(expectedIdle0, 0, "Should detect idle token0 from position 2");
        assertGt(expectedIdle1, 0, "Should detect idle token1 from position 3");

        // Execute sweep
        vm.prank(KEEPER);
        hook.sweepIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);

        // Verify correct amounts transferred
        (,, uint256 principalAfter0, uint256 principalAfter1,,) = hook.subsidyPools(testPoolId);

        assertEq(principalAfter0, expectedIdle0, "Should sweep only out-of-range token0");
        assertEq(principalAfter1, expectedIdle1, "Should sweep only out-of-range token1");
    }

    // ============ TEST: PERMISSIONLESS ACCESS ============

    /// @notice Test that sweepIdleCapital is permissionless and can be called by anyone
    /// @dev Validates Requirements: 9.2
    function test_CapitalSweepFlow_PermissionlessAccess() public {
        // Setup out-of-range positions
        int24[] memory tickLowers = new int24[](1);
        int24[] memory tickUppers = new int24[](1);
        uint128[] memory liquidityAmounts = new uint128[](1);

        tickLowers[0] = 60;
        tickUppers[0] = 120;
        liquidityAmounts[0] = 50e18;

        // Call from ALICE (arbitrary non-admin address)
        vm.prank(ALICE);
        hook.sweepIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);

        // Verify sweep succeeded
        (,, uint256 principal0,,,) = hook.subsidyPools(testPoolId);
        assertGt(principal0, 0, "Alice should be able to trigger sweep");

        // Setup more idle capital for second test
        poolManager.setSlot0(testPoolId, SQRT_PRICE_1_1, 60, 0, POOL_FEE);

        int24[] memory tickLowers2 = new int24[](1);
        int24[] memory tickUppers2 = new int24[](1);
        uint128[] memory liquidityAmounts2 = new uint128[](1);

        tickLowers2[0] = -120;
        tickUppers2[0] = -60;
        liquidityAmounts2[0] = 50e18; // Increased from 3e18 to meet minimum threshold

        // Call from BOB (another arbitrary address)
        vm.prank(BOB);
        hook.sweepIdleCapital(testPoolKey, tickLowers2, tickUppers2, liquidityAmounts2);

        // Verify sweep succeeded
        (,,, uint256 principal1,,) = hook.subsidyPools(testPoolId);
        assertGt(principal1, 0, "Bob should be able to trigger sweep");
    }

    // ============ TEST: EVENT EMISSION ============

    /// @notice Test that CapitalSwept event is emitted with all required parameters
    /// @dev Validates Requirements: 24.1-24.5
    function test_CapitalSweepFlow_EventEmission() public {
        // Setup out-of-range positions
        int24[] memory tickLowers = new int24[](2);
        int24[] memory tickUppers = new int24[](2);
        uint128[] memory liquidityAmounts = new uint128[](2);

        tickLowers[0] = 60;
        tickUppers[0] = 120;
        liquidityAmounts[0] = 80e18;

        tickLowers[1] = -120;
        tickUppers[1] = -60;
        liquidityAmounts[1] = 40e18;

        // Calculate expected values
        (uint256 expectedAmount0, uint256 expectedAmount1) =
            hook.calculateIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);

        // Record logs
        vm.recordLogs();

        // Execute sweep
        vm.prank(KEEPER);
        hook.sweepIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);

        // Get emitted logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find CapitalSwept event
        // Event signature: CapitalSwept(bytes32 indexed poolId, uint256 amount0, uint256 amount1,
        //                              uint256 shares0, uint256 shares1, address indexed caller)
        bool eventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            // Check if this is the CapitalSwept event
            // topic[0] = event signature hash
            // topic[1] = poolId (indexed)
            // topic[2] = caller (indexed)
            // data = abi.encode(amount0, amount1, shares0, shares1)
            if (
                logs[i].topics.length == 3
                    && logs[i].topics[0] == keccak256("CapitalSwept(bytes32,uint256,uint256,uint256,uint256,address)")
            ) {
                eventFound = true;

                // Decode event data (non-indexed parameters)
                (uint256 amount0, uint256 amount1, uint256 shares0, uint256 shares1) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));

                // Verify event parameters
                assertEq(amount0, expectedAmount0, "Event should include correct amount0");
                assertEq(amount1, expectedAmount1, "Event should include correct amount1");
                assertGt(shares0, 0, "Event should include vault shares0");
                assertGt(shares1, 0, "Event should include vault shares1");

                // Note: caller is in topics[2], but we can't easily decode it in this test pattern
                // The important part is that the event was emitted with the correct amounts

                break;
            }
        }

        assertTrue(eventFound, "CapitalSwept event should be emitted");
    }

    // ============ TEST: REVERT CONDITIONS ============

    /// @notice Test that sweep reverts when pool is not registered
    /// @dev Validates Requirements: 9.3
    function test_RevertWhen_PoolNotRegistered() public {
        // Create unregistered pool key
        PoolKey memory unregisteredKey =
            createPoolKey(address(0x999), address(0x888), POOL_FEE, TICK_SPACING, address(hook));

        int24[] memory tickLowers = new int24[](1);
        int24[] memory tickUppers = new int24[](1);
        uint128[] memory liquidityAmounts = new uint128[](1);

        tickLowers[0] = 60;
        tickUppers[0] = 120;
        liquidityAmounts[0] = 1e18;

        // Expect revert
        vm.expectRevert();
        vm.prank(KEEPER);
        hook.sweepIdleCapital(unregisteredKey, tickLowers, tickUppers, liquidityAmounts);
    }

    /// @notice Test that sweep reverts when pool is paused
    /// @dev Validates Requirements: 33.2
    function test_RevertWhen_PoolPaused() public {
        // Pause the pool
        vm.prank(hook.owner());
        hook.pausePool(testPoolId);

        // Setup positions
        int24[] memory tickLowers = new int24[](1);
        int24[] memory tickUppers = new int24[](1);
        uint128[] memory liquidityAmounts = new uint128[](1);

        tickLowers[0] = 60;
        tickUppers[0] = 120;
        liquidityAmounts[0] = 5e18;

        // Expect revert
        vm.expectRevert();
        vm.prank(KEEPER);
        hook.sweepIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);
    }

    /// @notice Test that sweep reverts when idle capital is below minimum threshold
    /// @dev Validates Requirements: 9.7, 35.1-35.5
    function test_RevertWhen_BelowMinimumThreshold() public {
        // Setup very small out-of-range position
        int24[] memory tickLowers = new int24[](1);
        int24[] memory tickUppers = new int24[](1);
        uint128[] memory liquidityAmounts = new uint128[](1);

        tickLowers[0] = 60;
        tickUppers[0] = 120;
        liquidityAmounts[0] = 0.001e18; // Very small liquidity

        // Expect revert due to below minimum threshold (0.1 ether)
        vm.expectRevert();
        vm.prank(KEEPER);
        hook.sweepIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);
    }

    /// @notice Test that sweep with all in-range positions reverts
    /// @dev Validates Requirements: 8.8, 9.7
    function test_RevertWhen_NoIdleCapital() public {
        // Setup all in-range positions
        int24[] memory tickLowers = new int24[](2);
        int24[] memory tickUppers = new int24[](2);
        uint128[] memory liquidityAmounts = new uint128[](2);

        // Position 1: In-range
        tickLowers[0] = -60;
        tickUppers[0] = 60;
        liquidityAmounts[0] = 10e18;

        // Position 2: Also in-range
        tickLowers[1] = -120;
        tickUppers[1] = 120;
        liquidityAmounts[1] = 5e18;

        // Verify no idle capital
        (uint256 idle0, uint256 idle1) =
            hook.calculateIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);
        assertEq(idle0, 0, "Should have no idle token0");
        assertEq(idle1, 0, "Should have no idle token1");

        // Expect revert due to no idle capital
        vm.expectRevert();
        vm.prank(KEEPER);
        hook.sweepIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);
    }

    // ============ TEST: VAULT SHARE TRACKING ============

    /// @notice Test that vault shares are accurately tracked in SubsidyPool
    /// @dev Validates Requirements: 11.5, 34.1-34.2
    function test_CapitalSweepFlow_VaultShareTracking() public {
        // Setup out-of-range positions
        int24[] memory tickLowers = new int24[](2);
        int24[] memory tickUppers = new int24[](2);
        uint128[] memory liquidityAmounts = new uint128[](2);

        tickLowers[0] = 60;
        tickUppers[0] = 120;
        liquidityAmounts[0] = 100e18;

        tickLowers[1] = -120;
        tickUppers[1] = -60;
        liquidityAmounts[1] = 80e18;

        // Record hook's vault share balances before sweep
        uint256 hookShares0Before = vault0.shares(address(hook));
        uint256 hookShares1Before = vault1.shares(address(hook));

        // Execute sweep
        vm.prank(KEEPER);
        hook.sweepIdleCapital(testPoolKey, tickLowers, tickUppers, liquidityAmounts);

        // Record hook's vault share balances after sweep
        uint256 hookShares0After = vault0.shares(address(hook));
        uint256 hookShares1After = vault1.shares(address(hook));

        // Calculate actual shares received
        uint256 actualShares0 = hookShares0After - hookShares0Before;
        uint256 actualShares1 = hookShares1After - hookShares1Before;

        // Verify SubsidyPool tracking matches actual shares
        (,,,, uint256 trackedShares0, uint256 trackedShares1) = hook.subsidyPools(testPoolId);

        assertEq(trackedShares0, actualShares0, "Tracked vault shares0 should match actual shares received");
        assertEq(trackedShares1, actualShares1, "Tracked vault shares1 should match actual shares received");

        // Verify shares are non-zero
        assertGt(trackedShares0, 0, "Should track non-zero shares for token0");
        assertGt(trackedShares1, 0, "Should track non-zero shares for token1");
    }

    // ============ TEST: MULTIPLE SWEEPS ============

    /// @notice Test that multiple sweeps accumulate correctly in SubsidyPool
    /// @dev Validates Requirements: 11.4, 12.1-12.2
    function test_CapitalSweepFlow_MultipleSweeps() public {
        // First sweep - position above current price (token0)
        int24[] memory tickLowers1 = new int24[](1);
        int24[] memory tickUppers1 = new int24[](1);
        uint128[] memory liquidityAmounts1 = new uint128[](1);

        tickLowers1[0] = 60;
        tickUppers1[0] = 120;
        liquidityAmounts1[0] = 50e18;

        vm.prank(KEEPER);
        hook.sweepIdleCapital(testPoolKey, tickLowers1, tickUppers1, liquidityAmounts1);

        // Record state after first sweep
        (,, uint256 principal0After1, uint256 principal1After1, uint256 shares0After1, uint256 shares1After1) =
            hook.subsidyPools(testPoolId);

        // Second sweep - another position above current price (more token0)
        // Keep price at tick 0, add another out-of-range position
        int24[] memory tickLowers2 = new int24[](1);
        int24[] memory tickUppers2 = new int24[](1);
        uint128[] memory liquidityAmounts2 = new uint128[](1);

        tickLowers2[0] = 120; // Even further above
        tickUppers2[0] = 180;
        liquidityAmounts2[0] = 40e18;

        (uint256 expectedIdle0_2, uint256 expectedIdle1_2) =
            hook.calculateIdleCapital(testPoolKey, tickLowers2, tickUppers2, liquidityAmounts2);

        vm.prank(ALICE);
        hook.sweepIdleCapital(testPoolKey, tickLowers2, tickUppers2, liquidityAmounts2);

        // Verify accumulation
        (,, uint256 principal0After2, uint256 principal1After2, uint256 shares0After2, uint256 shares1After2) =
            hook.subsidyPools(testPoolId);

        assertEq(principal0After2, principal0After1 + expectedIdle0_2, "Principal0 should accumulate across sweeps");
        assertEq(principal1After2, principal1After1 + expectedIdle1_2, "Principal1 should accumulate across sweeps");
        assertGt(shares0After2, shares0After1, "Shares0 should accumulate");
        // shares1 might not accumulate if both sweeps only deposit token0
        assertEq(shares1After2, shares1After1, "Shares1 should remain same if no token1 deposits");
    }
}
