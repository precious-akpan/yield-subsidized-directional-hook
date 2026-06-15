// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import "../../src/automation/ReactiveKeeperCallback.sol";
import "../../src/automation/ReactiveSubscriber.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import "../mocks/MockERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @title AutomatedSweeps Integration Test
/// @notice End-to-end integration tests for automated capital sweeps via Reactive Network
/// @dev Tests the complete automation workflow: hook event emission → subscriber forwarding → keeper callback execution
/// 
/// **DESIGN NOTE**: The current implementation has a limitation where `sweepIdleCapital` requires
/// LP position arrays (tickLowers, tickUppers, liquidityAmounts) that are not available in the 
/// IdleCapitalDetected event. To make automated sweeps work, one of these solutions is needed:
/// 1. Modify sweepIdleCapital to internally query LP positions from PoolManager
/// 2. Include position data in the IdleCapitalDetected event (may be expensive)
/// 3. Have the hook maintain an internal registry of LP positions
/// 
/// For these tests, we simulate the automation workflow using a MockHook that has the simplified
/// interface expected by ReactiveKeeperCallback.
/// 
/// @custom:task Task 24 - Create integration tests for automated sweeps
/// **Validates: Requirements 41.1-41.5, 42.1-42.5, 43.1-43.5, 44.1-44.5, 50.1-50.5**
contract AutomatedSweepsIntegrationTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    // ========== TEST CONTRACTS ==========
    MockAutomatedSweepHook public hook;
    ReactiveKeeperCallback public keeperCallback;
    ReactiveSubscriber public subscriber;
    MockERC20 public token0;
    MockERC20 public token1;

    // ========== TEST POOLS ==========
    PoolKey public testPoolKey;
    PoolId public testPoolId;

    PoolKey public secondPoolKey;
    PoolId public secondPoolId;

    // ========== TEST CONFIGURATION ==========
    uint24 constant BASE_FEE_BPS = 30; // 0.3%
    uint24 constant MAX_FEE_MULTIPLIER = 30000; // 3x
    uint24 constant DEVIATION_THRESHOLD_BPS = 50; // 0.5%
    uint24 constant POOL_FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60;

    // Automation configuration
    uint256 constant SWEEP_THRESHOLD = 1e18; // 1 token minimum
    uint256 constant MIN_SWEEP_INTERVAL = 7 days; // 1 week

    // Price constants
    uint256 constant ORACLE_PRICE_1_1 = 1e18; // 1:1 price

    // ========== SETUP ==========

    function setUp() public override {
        super.setUp();

        // Deploy tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy mock hook with simplified interface
        hook = new MockAutomatedSweepHook();

        // Deploy automation contracts
        keeperCallback = new ReactiveKeeperCallback(address(hook), SWEEP_THRESHOLD, MIN_SWEEP_INTERVAL);
        subscriber = new ReactiveSubscriber(address(hook), address(keeperCallback));

        // Setup first pool
        testPoolKey = createPoolKey(address(token0), address(token1), POOL_FEE, TICK_SPACING, address(hook));
        testPoolId = testPoolKey.toId();

        // Label addresses
        vm.label(address(hook), "MockAutomatedSweepHook");
        vm.label(address(keeperCallback), "ReactiveKeeperCallback");
        vm.label(address(subscriber), "ReactiveSubscriber");
    }

    // ========== TASK 24.1: END-TO-END AUTOMATED SWEEP TEST ==========

    /// @notice Test complete end-to-end automated sweep workflow
    /// @dev Validates Requirements: 41.1-41.5, 42.1-42.5, 43.1-43.5, 44.1-44.5, 50.1-50.5
    /// @custom:subtask 24.1 - Write end-to-end automated sweep test
    function test_AutomatedSweep_EndToEnd() public {
        // ========== SETUP: Define idle capital amounts ==========
        uint256 idleAmount0 = 100e18;
        uint256 idleAmount1 = 80e18;

        // ========== STEP 1: Create the log record (simulating IdleCapitalDetected event) ==========
        IReactive.LogRecord memory log = _createLogRecord(testPoolId, idleAmount0, idleAmount1, testPoolKey);

        // Record state before sweep
        uint256 sweepCountBefore = hook.sweepCount(testPoolId);
        assertEq(sweepCountBefore, 0, "Should start with no sweeps");

        // ========== STEP 2: Trigger automated sweep via ReactiveKeeperCallback ==========

        vm.expectEmit(true, true, true, true, address(keeperCallback));
        emit ReactiveKeeperCallback.SweepTriggered(testPoolId, idleAmount0, idleAmount1, block.timestamp);

        keeperCallback.react(log);

        // ========== VERIFY: sweepIdleCapital executed successfully ==========

        uint256 sweepCountAfter = hook.sweepCount(testPoolId);
        assertEq(sweepCountAfter, 1, "Sweep should have been executed once");

        // ========== VERIFY: lastSweepTime updated ==========

        uint256 lastSweepTime = keeperCallback.getLastSweepTime(testPoolId);
        assertEq(lastSweepTime, block.timestamp, "lastSweepTime should be current block timestamp");
        assertFalse(keeperCallback.canSweep(testPoolId), "Should not be able to sweep again immediately");
    }

    // ========== TASK 24.2: THRESHOLD FILTERING TEST ==========

    /// @notice Test that sweeps are filtered based on threshold configuration
    /// @dev Validates Requirements: 43.1-43.5
    /// @custom:subtask 24.2 - Write threshold filtering test
    function test_AutomatedSweep_ThresholdFiltering() public {
        // ========== TEST 1: Emit IdleCapitalDetected with amount below threshold ==========

        uint256 belowThreshold = SWEEP_THRESHOLD / 2; // 0.5 tokens (below 1 token threshold)

        IReactive.LogRecord memory logBelowThreshold =
            _createLogRecord(testPoolId, belowThreshold, belowThreshold, testPoolKey);

        uint256 sweepCountBefore = hook.sweepCount(testPoolId);

        // Trigger callback - should NOT execute sweep
        keeperCallback.react(logBelowThreshold);

        // ========== VERIFY: Sweep NOT triggered ==========

        uint256 sweepCountAfter = hook.sweepCount(testPoolId);
        assertEq(sweepCountAfter, sweepCountBefore, "Sweep count should not change when below threshold");

        uint256 lastSweepTime = keeperCallback.getLastSweepTime(testPoolId);
        assertEq(lastSweepTime, 0, "lastSweepTime should not be set when below threshold");

        // ========== TEST 2: Emit IdleCapitalDetected with amount above threshold ==========

        uint256 aboveThreshold = SWEEP_THRESHOLD * 2; // 2 tokens (above 1 token threshold)

        IReactive.LogRecord memory logAboveThreshold =
            _createLogRecord(testPoolId, aboveThreshold, aboveThreshold, testPoolKey);

        vm.expectEmit(true, true, true, true, address(keeperCallback));
        emit ReactiveKeeperCallback.SweepTriggered(testPoolId, aboveThreshold, aboveThreshold, block.timestamp);

        // Trigger callback - should execute sweep
        keeperCallback.react(logAboveThreshold);

        // ========== VERIFY: Sweep IS triggered ==========

        uint256 sweepCountAfterSweep = hook.sweepCount(testPoolId);
        assertEq(sweepCountAfterSweep, 1, "Sweep should be executed when above threshold");

        uint256 lastSweepTimeAfterSweep = keeperCallback.getLastSweepTime(testPoolId);
        assertGt(lastSweepTimeAfterSweep, 0, "lastSweepTime should update when above threshold");
    }

    /// @notice Test threshold filtering with one token above and one below
    /// @dev Validates Requirements: 43.1-43.5
    function test_AutomatedSweep_ThresholdFiltering_MixedAmounts() public {
        // One token above threshold, one below
        uint256 aboveThreshold = SWEEP_THRESHOLD * 2;
        uint256 belowThreshold = SWEEP_THRESHOLD / 2;

        IReactive.LogRecord memory log =
            _createLogRecord(testPoolId, aboveThreshold, belowThreshold, testPoolKey);

        vm.expectEmit(true, true, true, true, address(keeperCallback));
        emit ReactiveKeeperCallback.SweepTriggered(testPoolId, aboveThreshold, belowThreshold, block.timestamp);

        // Should trigger because at least one token is above threshold
        keeperCallback.react(log);

        uint256 lastSweepTime = keeperCallback.getLastSweepTime(testPoolId);
        assertGt(lastSweepTime, 0, "Should trigger sweep when any token is above threshold");
    }

    // ========== TASK 24.3: INTERVAL ENFORCEMENT TEST ==========

    /// @notice Test that sweep interval is enforced between consecutive sweeps
    /// @dev Validates Requirements: 44.1-44.5
    /// @custom:subtask 24.3 - Write interval enforcement test
    function test_AutomatedSweep_IntervalEnforcement() public {
        uint256 idleAmount = SWEEP_THRESHOLD * 2;

        // ========== STEP 1: Trigger first automated sweep successfully ==========

        IReactive.LogRecord memory log = _createLogRecord(testPoolId, idleAmount, idleAmount, testPoolKey);

        vm.expectEmit(true, true, true, true, address(keeperCallback));
        emit ReactiveKeeperCallback.SweepTriggered(testPoolId, idleAmount, idleAmount, block.timestamp);

        keeperCallback.react(log);

        uint256 firstSweepTime = keeperCallback.getLastSweepTime(testPoolId);
        assertGt(firstSweepTime, 0, "First sweep should succeed");

        // ========== STEP 2: Immediately trigger second sweep attempt ==========

        IReactive.LogRecord memory log2 = _createLogRecord(testPoolId, idleAmount, idleAmount, testPoolKey);

        // ========== VERIFY: SweepTooSoon revert ==========

        vm.expectRevert(ReactiveKeeperCallback.SweepTooSoon.selector);
        keeperCallback.react(log2);

        // Verify canSweep returns false
        assertFalse(keeperCallback.canSweep(testPoolId), "canSweep should return false within interval");

        // ========== STEP 3: Fast-forward time beyond interval ==========

        vm.warp(block.timestamp + MIN_SWEEP_INTERVAL + 1);

        // Verify canSweep returns true
        assertTrue(keeperCallback.canSweep(testPoolId), "canSweep should return true after interval");

        // ========== VERIFY: Second sweep succeeds ==========

        IReactive.LogRecord memory log3 = _createLogRecord(testPoolId, idleAmount, idleAmount, testPoolKey);

        vm.expectEmit(true, true, true, true, address(keeperCallback));
        emit ReactiveKeeperCallback.SweepTriggered(testPoolId, idleAmount, idleAmount, block.timestamp);

        keeperCallback.react(log3);

        uint256 secondSweepTime = keeperCallback.getLastSweepTime(testPoolId);
        assertGt(secondSweepTime, firstSweepTime, "Second sweep should succeed after interval");
        assertEq(
            secondSweepTime,
            firstSweepTime + MIN_SWEEP_INTERVAL + 1,
            "Second sweep time should be interval after first"
        );
    }

    /// @notice Test interval enforcement with partial time passage
    /// @dev Validates Requirements: 44.1-44.5
    function test_AutomatedSweep_IntervalEnforcement_PartialInterval() public {
        uint256 idleAmount = SWEEP_THRESHOLD * 2;

        // First sweep
        IReactive.LogRecord memory log = _createLogRecord(testPoolId, idleAmount, idleAmount, testPoolKey);
        keeperCallback.react(log);

        // Warp halfway through interval
        vm.warp(block.timestamp + MIN_SWEEP_INTERVAL / 2);

        // Should still revert
        IReactive.LogRecord memory log2 = _createLogRecord(testPoolId, idleAmount, idleAmount, testPoolKey);
        vm.expectRevert(ReactiveKeeperCallback.SweepTooSoon.selector);
        keeperCallback.react(log2);

        assertFalse(keeperCallback.canSweep(testPoolId), "Should not be able to sweep at half interval");
    }

    // ========== TASK 24.4: MULTI-POOL AUTOMATION TEST ==========

    /// @notice Test automated sweeps work independently across multiple pools
    /// @dev Validates Requirements: 50.1-50.5
    /// @custom:subtask 24.4 - Write multi-pool automation test
    function test_AutomatedSweep_MultiPool() public {
        // ========== SETUP: Set up second pool ==========

        // Create second pool with different tokens
        MockERC20 token2 = new MockERC20("Token2", "TK2", 18);
        MockERC20 token3 = new MockERC20("Token3", "TK3", 18);

        if (address(token2) > address(token3)) {
            (token2, token3) = (token3, token2);
        }

        secondPoolKey = createPoolKey(address(token2), address(token3), POOL_FEE, TICK_SPACING, address(hook));
        secondPoolId = secondPoolKey.toId();

        uint256 idleAmount = SWEEP_THRESHOLD * 2;

        // ========== TEST: Trigger sweeps for both pools ==========

        // Sweep pool 1
        IReactive.LogRecord memory log1 = _createLogRecord(testPoolId, idleAmount, idleAmount, testPoolKey);

        vm.expectEmit(true, true, true, true, address(keeperCallback));
        emit ReactiveKeeperCallback.SweepTriggered(testPoolId, idleAmount, idleAmount, block.timestamp);

        keeperCallback.react(log1);

        uint256 pool1SweepTime = keeperCallback.getLastSweepTime(testPoolId);

        // Sweep pool 2 immediately after pool 1
        IReactive.LogRecord memory log2 = _createLogRecord(secondPoolId, idleAmount, idleAmount, secondPoolKey);

        vm.expectEmit(true, true, true, true, address(keeperCallback));
        emit ReactiveKeeperCallback.SweepTriggered(secondPoolId, idleAmount, idleAmount, block.timestamp);

        keeperCallback.react(log2);

        uint256 pool2SweepTime = keeperCallback.getLastSweepTime(secondPoolId);

        // ========== VERIFY: Independent interval tracking ==========

        assertEq(pool1SweepTime, pool2SweepTime, "Both pools should be swept at same time");
        assertGt(pool1SweepTime, 0, "Pool 1 should have sweep time");
        assertGt(pool2SweepTime, 0, "Pool 2 should have sweep time");

        // Try to sweep pool 1 again immediately - should fail
        IReactive.LogRecord memory log3 = _createLogRecord(testPoolId, idleAmount, idleAmount, testPoolKey);
        vm.expectRevert(ReactiveKeeperCallback.SweepTooSoon.selector);
        keeperCallback.react(log3);

        // Try to sweep pool 2 again immediately - should also fail
        IReactive.LogRecord memory log4 = _createLogRecord(secondPoolId, idleAmount, idleAmount, secondPoolKey);
        vm.expectRevert(ReactiveKeeperCallback.SweepTooSoon.selector);
        keeperCallback.react(log4);

        // ========== VERIFY: Independent threshold checking ==========

        // Fast-forward time for both pools
        vm.warp(block.timestamp + MIN_SWEEP_INTERVAL + 1);

        // Both pools should now be sweepable
        assertTrue(keeperCallback.canSweep(testPoolId), "Pool 1 should be sweepable after interval");
        assertTrue(keeperCallback.canSweep(secondPoolId), "Pool 2 should be sweepable after interval");

        // Sweep pool 1 again
        IReactive.LogRecord memory log5 = _createLogRecord(testPoolId, idleAmount, idleAmount, testPoolKey);
        keeperCallback.react(log5);

        uint256 pool1SecondSweep = keeperCallback.getLastSweepTime(testPoolId);
        uint256 pool2StillFirst = keeperCallback.getLastSweepTime(secondPoolId);

        // ========== VERIFY: Isolated lastSweepTime per pool ==========

        assertGt(pool1SecondSweep, pool1SweepTime, "Pool 1 should have new sweep time");
        assertEq(pool2StillFirst, pool2SweepTime, "Pool 2 sweep time should be unchanged");

        // Pool 2 should still be sweepable
        assertTrue(keeperCallback.canSweep(secondPoolId), "Pool 2 should still be sweepable");

        // Pool 1 should not be sweepable immediately
        assertFalse(keeperCallback.canSweep(testPoolId), "Pool 1 should not be sweepable immediately after sweep");

        // Verify sweep counts
        assertEq(hook.sweepCount(testPoolId), 2, "Pool 1 should have 2 sweeps");
        assertEq(hook.sweepCount(secondPoolId), 1, "Pool 2 should have 1 sweep");
    }

    /// @notice Test multi-pool with different idle amounts
    /// @dev Validates Requirements: 50.1-50.5
    function test_AutomatedSweep_MultiPool_DifferentAmounts() public {
        // Setup second pool
        MockERC20 token2 = new MockERC20("Token2", "TK2", 18);
        MockERC20 token3 = new MockERC20("Token3", "TK3", 18);

        if (address(token2) > address(token3)) {
            (token2, token3) = (token3, token2);
        }

        secondPoolKey = createPoolKey(address(token2), address(token3), POOL_FEE, TICK_SPACING, address(hook));
        secondPoolId = secondPoolKey.toId();

        // Pool 1: Large idle amount
        uint256 pool1Idle = SWEEP_THRESHOLD * 10;
        IReactive.LogRecord memory log1 = _createLogRecord(testPoolId, pool1Idle, pool1Idle, testPoolKey);
        keeperCallback.react(log1);

        // Pool 2: Small idle amount (just above threshold)
        uint256 pool2Idle = SWEEP_THRESHOLD + 0.1e18;
        IReactive.LogRecord memory log2 = _createLogRecord(secondPoolId, pool2Idle, pool2Idle, secondPoolKey);
        keeperCallback.react(log2);

        // Verify both sweeps succeeded despite different amounts
        assertGt(keeperCallback.getLastSweepTime(testPoolId), 0, "Pool 1 should be swept");
        assertGt(keeperCallback.getLastSweepTime(secondPoolId), 0, "Pool 2 should be swept");

        // Verify correct sweep counts
        assertEq(hook.sweepCount(testPoolId), 1, "Pool 1 should have 1 sweep");
        assertEq(hook.sweepCount(secondPoolId), 1, "Pool 2 should have 1 sweep");
    }

    // ========== HELPER FUNCTIONS ==========

    /// @notice Creates a LogRecord for testing Reactive Network callbacks
    function _createLogRecord(PoolId poolId, uint256 idleAmount0, uint256 idleAmount1, PoolKey memory poolKey)
        private
        view
        returns (IReactive.LogRecord memory)
    {
        bytes32 topicHash = keeperCallback.IDLE_CAPITAL_DETECTED_TOPIC();
        return IReactive.LogRecord({
            chain_id: block.chainid,
            _contract: address(hook),
            topic_0: uint256(topicHash),
            topic_1: uint256(PoolId.unwrap(poolId)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(idleAmount0, idleAmount1, poolKey),
            block_number: block.number,
            op_code: 0,
            block_hash: uint256(blockhash(block.number - 1)),
            tx_hash: 0,
            log_index: 0
        });
    }
}

// ========== MOCK CONTRACTS ==========

/// @title MockAutomatedSweepHook
/// @notice Mock hook for testing automated sweeps with simplified interface
/// @dev Implements the IYieldSubsidizedDirectionalHook.sweepIdleCapital interface expected by ReactiveKeeperCallback
contract MockAutomatedSweepHook {
    // Track sweeps per pool
    mapping(PoolId => uint256) public sweepCount;

    /// @notice Simplified sweepIdleCapital that matches the IYieldSubsidizedDirectionalHook interface
    function sweepIdleCapital(PoolKey calldata key) external {
        PoolId poolId = PoolIdLibrary.toId(key);
        sweepCount[poolId]++;
    }
}
