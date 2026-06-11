// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.sol";
import {ReactiveKeeperCallback} from "../../src/automation/ReactiveKeeperCallback.sol";
import {ReactiveSubscriber} from "../../src/automation/ReactiveSubscriber.sol";
import {IYieldSubsidizedDirectionalHook} from "../../src/interfaces/IYieldSubsidizedDirectionalHook.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @title ReactiveAutomation.t.sol
/// @notice Comprehensive tests for Reactive Network automation contracts
/// @dev Tests ReactiveKeeperCallback, ReactiveSubscriber, and their integration
/// **Validates: Requirements 42.1-42.5, 43.1-43.5, 44.1-44.5, 45.1-45.5, 46.1-46.5**
contract ReactiveAutomationTests is BaseTest {
    using PoolIdLibrary for PoolKey;

    // Test contracts
    ReactiveKeeperCallback private keeperCallback;
    ReactiveSubscriber private subscriber;
    MockHook private mockHook;

    // Test addresses
    address private hookAddress;
    address private keeper = address(0x100);
    address private newAdmin = address(0x101);

    // Test values
    uint256 private constant DEFAULT_THRESHOLD = 1e18; // 1 token
    uint256 private constant DEFAULT_INTERVAL = 7 days; // 7 days
    uint256 private constant IDLE_AMOUNT_0 = 5e18; // 5 tokens
    uint256 private constant IDLE_AMOUNT_1 = 10e18; // 10 tokens

    // Test pool data
    PoolKey private testPoolKey;
    PoolId private testPoolId;

    // ========== SETUP ==========

    function setUp() public override {
        super.setUp();

        // Deploy mock hook
        mockHook = new MockHook();
        hookAddress = address(mockHook);

        // Deploy ReactiveKeeperCallback
        keeperCallback = new ReactiveKeeperCallback(hookAddress, DEFAULT_THRESHOLD, DEFAULT_INTERVAL);

        // Deploy ReactiveSubscriber
        subscriber = new ReactiveSubscriber(hookAddress, payable(address(keeperCallback)));

        // Create test pool
        testPoolKey = createPoolKey(ALICE, BOB, 3000, 60, hookAddress);
        testPoolId = testPoolKey.toId();

        // Label addresses
        vm.label(address(keeperCallback), "ReactiveKeeperCallback");
        vm.label(address(subscriber), "ReactiveSubscriber");
        vm.label(hookAddress, "MockHook");
    }

    // ========== TESTS: INITIALIZATION ==========

    /// @notice Test ReactiveKeeperCallback initialization
    /// @dev Validates: Requirements 42.1-42.5
    function test_ReactiveKeeperCallback_Initialization() public view {
        assertEq(keeperCallback.hookAddress(), hookAddress);
        assertEq(keeperCallback.sweepThreshold(), DEFAULT_THRESHOLD);
        assertEq(keeperCallback.minSweepInterval(), DEFAULT_INTERVAL);
        assertEq(keeperCallback.admin(), address(this));
    }

    /// @notice Test ReactiveSubscriber initialization
    /// @dev Validates: Requirements 45.1-45.5
    function test_ReactiveSubscriber_Initialization() public view {
        assertEq(subscriber.hookAddress(), hookAddress);
        assertEq(subscriber.callbackContract(), address(keeperCallback));
        assertEq(subscriber.admin(), address(this));
    }

    // ========== TESTS: SWEEP THRESHOLD CONFIGURATION ==========

    /// @notice Test setting sweep threshold successfully
    /// @dev Validates: Requirements 43.1-43.5
    function test_SetSweepThreshold_Success() public {
        uint256 newThreshold = 2e18;

        vm.expectEmit(true, true, true, true);
        emit ReactiveKeeperCallback.ThresholdUpdated(DEFAULT_THRESHOLD, newThreshold);

        keeperCallback.setSweepThreshold(newThreshold);

        assertEq(keeperCallback.sweepThreshold(), newThreshold);
    }

    /// @notice Test setting sweep threshold with zero value reverts
    /// @dev Validates: Requirements 43.1-43.5
    function test_SetSweepThreshold_RevertsWithZero() public {
        vm.expectRevert("Invalid threshold");
        keeperCallback.setSweepThreshold(0);
    }

    /// @notice Test only admin can set sweep threshold
    /// @dev Validates: Requirements 43.1-43.5
    function test_SetSweepThreshold_OnlyAdmin() public {
        vm.prank(ALICE);
        vm.expectRevert(ReactiveKeeperCallback.Unauthorized.selector);
        keeperCallback.setSweepThreshold(2e18);
    }

    /// @notice Test sweep threshold update emits correct event
    /// @dev Validates: Requirements 43.1-43.5
    function test_SetSweepThreshold_EmitEvent() public {
        uint256 newThreshold = 3e18;

        vm.expectEmit(true, true, true, true);
        emit ReactiveKeeperCallback.ThresholdUpdated(DEFAULT_THRESHOLD, newThreshold);

        keeperCallback.setSweepThreshold(newThreshold);
    }

    // ========== TESTS: SWEEP INTERVAL CONFIGURATION ==========

    /// @notice Test setting min sweep interval successfully
    /// @dev Validates: Requirements 44.1-44.5
    function test_SetMinSweepInterval_Success() public {
        uint256 newInterval = 1 days;

        vm.expectEmit(true, true, true, true);
        emit ReactiveKeeperCallback.IntervalUpdated(DEFAULT_INTERVAL, newInterval);

        keeperCallback.setMinSweepInterval(newInterval);

        assertEq(keeperCallback.minSweepInterval(), newInterval);
    }

    /// @notice Test setting min sweep interval to zero
    /// @dev Validates: Requirements 44.1-44.5
    function test_SetMinSweepInterval_AllowZero() public {
        keeperCallback.setMinSweepInterval(0);
        assertEq(keeperCallback.minSweepInterval(), 0);
    }

    /// @notice Test only admin can set min sweep interval
    /// @dev Validates: Requirements 44.1-44.5
    function test_SetMinSweepInterval_OnlyAdmin() public {
        vm.prank(ALICE);
        vm.expectRevert(ReactiveKeeperCallback.Unauthorized.selector);
        keeperCallback.setMinSweepInterval(1 days);
    }

    /// @notice Test sweep interval update emits correct event
    /// @dev Validates: Requirements 44.1-44.5
    function test_SetMinSweepInterval_EmitEvent() public {
        uint256 newInterval = 3 days;

        vm.expectEmit(true, true, true, true);
        emit ReactiveKeeperCallback.IntervalUpdated(DEFAULT_INTERVAL, newInterval);

        keeperCallback.setMinSweepInterval(newInterval);
    }

    // ========== TESTS: ADMIN TRANSFER ==========

    /// @notice Test transferring admin rights successfully
    /// @dev Validates: Requirements 46.1-46.5
    function test_TransferAdmin_Success() public {
        vm.expectEmit(true, true, true, true);
        emit ReactiveKeeperCallback.AdminTransferred(address(this), newAdmin);

        keeperCallback.transferAdmin(newAdmin);

        assertEq(keeperCallback.admin(), newAdmin);
    }

    /// @notice Test only admin can transfer admin rights
    /// @dev Validates: Requirements 46.1-46.5
    function test_TransferAdmin_OnlyAdmin() public {
        vm.prank(ALICE);
        vm.expectRevert(ReactiveKeeperCallback.Unauthorized.selector);
        keeperCallback.transferAdmin(newAdmin);
    }

    /// @notice Test transferring admin to zero address reverts
    /// @dev Validates: Requirements 46.1-46.5
    function test_TransferAdmin_RevertsWithZeroAddress() public {
        vm.expectRevert("Invalid address");
        keeperCallback.transferAdmin(address(0));
    }

    /// @notice Test admin can still access functions after transfer
    /// @dev Validates: Requirements 46.1-46.5
    function test_TransferAdmin_NewAdminCanConfigure() public {
        keeperCallback.transferAdmin(newAdmin);

        vm.prank(newAdmin);
        keeperCallback.setSweepThreshold(2e18);

        assertEq(keeperCallback.sweepThreshold(), 2e18);
    }

    // ========== TESTS: SWEEP READINESS ==========

    /// @notice Test canSweep returns true when interval has passed
    /// @dev Validates: Requirements 50.1-50.5
    function test_CanSweep_ReturnsTrue_WhenIntervalPassed() public {
        // Initially can sweep (never swept before)
        assertTrue(keeperCallback.canSweep(testPoolId));

        // Mark as swept now
        _triggerSweep(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1, testPoolKey);

        // Cannot sweep immediately
        assertFalse(keeperCallback.canSweep(testPoolId));

        // Warp past interval
        vm.warp(block.timestamp + DEFAULT_INTERVAL + 1);

        // Can sweep again
        assertTrue(keeperCallback.canSweep(testPoolId));
    }

    /// @notice Test canSweep returns true before first sweep
    /// @dev Validates: Requirements 50.1-50.5
    function test_CanSweep_ReturnsTrue_BeforeFirstSweep() public {
        assertTrue(keeperCallback.canSweep(testPoolId));
    }

    /// @notice Test getLastSweepTime returns correct timestamp
    /// @dev Validates: Requirements 50.1-50.5
    function test_GetLastSweepTime_ReturnsCorrectTimestamp() public {
        assertEq(keeperCallback.getLastSweepTime(testPoolId), 0);

        _triggerSweep(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1, testPoolKey);

        assertEq(keeperCallback.getLastSweepTime(testPoolId), block.timestamp);
    }

    /// @notice Test getSweepConfig returns current configuration
    /// @dev Validates: Requirements 50.1-50.5
    function test_GetSweepConfig_ReturnsCurrentConfig() public {
        (uint256 threshold, uint256 interval) = keeperCallback.getSweepConfig();

        assertEq(threshold, DEFAULT_THRESHOLD);
        assertEq(interval, DEFAULT_INTERVAL);

        keeperCallback.setSweepThreshold(2e18);
        keeperCallback.setMinSweepInterval(1 days);

        (threshold, interval) = keeperCallback.getSweepConfig();

        assertEq(threshold, 2e18);
        assertEq(interval, 1 days);
    }

    // ========== TESTS: SWEEP TRIGGERING (REACT) ==========

    /// @notice Test react function triggers sweep when conditions are met
    /// @dev Validates: Requirements 42.1-42.5
    function test_React_TriggersSweep_WhenConditionsMet() public {
        _triggerSweep(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1, testPoolKey);

        // Verify sweep was triggered by checking that last sweep time was updated
        assertGt(keeperCallback.getLastSweepTime(testPoolId), 0);
    }

    /// @notice Test react function reverts when sweep interval not passed
    /// @dev Validates: Requirements 42.1-42.5, 44.1-44.5
    function test_React_RevertsWhen_IntervalNotPassed() public {
        _triggerSweep(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1, testPoolKey);

        // Try to sweep again immediately
        IReactive.LogRecord memory log = _createLogRecord(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1);

        vm.expectRevert(ReactiveKeeperCallback.SweepTooSoon.selector);
        keeperCallback.react(log);
    }

    /// @notice Test react function skips sweep when idle amount below threshold
    /// @dev Validates: Requirements 42.1-42.5, 43.1-43.5
    function test_React_SkipsSweep_WhenBelowThreshold() public {
        IReactive.LogRecord memory log = _createLogRecord(testPoolId, 0.1e18, 0.1e18);

        // Should not call hook
        keeperCallback.react(log);

        // lastSweepTime should not be updated
        assertEq(keeperCallback.getLastSweepTime(testPoolId), 0);
    }

    /// @notice Test react function emits SweepTriggered event
    /// @dev Validates: Requirements 42.1-42.5
    function test_React_EmitsSweepTriggeredEvent() public {
        IReactive.LogRecord memory log = _createLogRecord(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1);

        vm.expectEmit(true, true, true, true);
        emit ReactiveKeeperCallback.SweepTriggered(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1, block.timestamp);

        keeperCallback.react(log);
    }

    /// @notice Test react function handles sweeps with different idle amounts
    /// @dev Validates: Requirements 43.1-43.5
    function test_React_TriggersSweep_WithLargeIdleAmounts() public {
        uint256 largeAmount = 1000e18;
        _triggerSweep(testPoolId, largeAmount, largeAmount, testPoolKey);

        assertEq(keeperCallback.getLastSweepTime(testPoolId), block.timestamp);
    }

    // ========== TESTS: REACTIVE SUBSCRIBER ==========

    /// @notice Test ReactiveSubscriber forwards events to callback
    /// @dev Validates: Requirements 45.1-45.5
    function test_ReactiveSubscriber_ForwardsEvent() public {
        IReactive.LogRecord memory log = _createLogRecord(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1);

        bytes32 poolIdAsBytes32 = bytes32(PoolId.unwrap(testPoolId));

        vm.expectEmit(true, true, true, true, address(subscriber));
        emit ReactiveSubscriber.EventForwarded(poolIdAsBytes32, IDLE_AMOUNT_0, IDLE_AMOUNT_1);

        subscriber.react(log);
    }

    /// @notice Test ReactiveSubscriber only accepts events from monitored hook
    /// @dev Validates: Requirements 45.1-45.5
    function test_ReactiveSubscriber_RevertsWhen_EventNotFromHook() public {
        IReactive.LogRecord memory log = _createLogRecord(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1);
        log._contract = address(0x999); // Wrong contract

        vm.expectRevert("Event not from hook");
        subscriber.react(log);
    }

    /// @notice Test ReactiveSubscriber validates event signature
    /// @dev Validates: Requirements 45.1-45.5
    function test_ReactiveSubscriber_ValidatesEventSignature() public {
        IReactive.LogRecord memory log = _createLogRecord(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1);
        log.topic_0 = uint256(bytes32(0x0)); // Wrong signature

        vm.expectRevert("Invalid event signature");
        subscriber.react(log);
    }

    /// @notice Test setting callback contract
    /// @dev Validates: Requirements 47.1-47.5
    function test_ReactiveSubscriber_SetCallbackContract() public {
        address newCallback = address(0x999);

        vm.expectEmit(true, true, true, true);
        emit ReactiveSubscriber.CallbackContractUpdated(address(keeperCallback), newCallback);

        subscriber.setCallbackContract(payable(newCallback));

        assertEq(subscriber.callbackContract(), newCallback);
    }

    /// @notice Test setting callback contract with zero address reverts
    /// @dev Validates: Requirements 47.1-47.5
    function test_ReactiveSubscriber_SetCallbackContract_RevertsWithZero() public {
        vm.expectRevert("Invalid address");
        subscriber.setCallbackContract(payable(address(0)));
    }

    /// @notice Test only admin can set callback contract
    /// @dev Validates: Requirements 47.1-47.5
    function test_ReactiveSubscriber_SetCallbackContract_OnlyAdmin() public {
        vm.prank(ALICE);
        vm.expectRevert(ReactiveSubscriber.Unauthorized.selector);
        subscriber.setCallbackContract(payable(address(0x999)));
    }

    /// @notice Test transferring admin in ReactiveSubscriber
    /// @dev Validates: Requirements 47.1-47.5
    function test_ReactiveSubscriber_TransferAdmin() public {
        vm.expectEmit(true, true, true, true);
        emit ReactiveSubscriber.AdminTransferred(address(this), newAdmin);

        subscriber.transferAdmin(newAdmin);

        assertEq(subscriber.admin(), newAdmin);
    }

    /// @notice Test only admin can transfer admin in ReactiveSubscriber
    /// @dev Validates: Requirements 47.1-47.5
    function test_ReactiveSubscriber_TransferAdmin_OnlyAdmin() public {
        vm.prank(ALICE);
        vm.expectRevert(ReactiveSubscriber.Unauthorized.selector);
        subscriber.transferAdmin(newAdmin);
    }

    /// @notice Test transferring admin to zero address reverts in ReactiveSubscriber
    /// @dev Validates: Requirements 47.1-47.5
    function test_ReactiveSubscriber_TransferAdmin_RevertsWithZero() public {
        vm.expectRevert("Invalid address");
        subscriber.transferAdmin(address(0));
    }

    // ========== TESTS: INTEGRATION SCENARIOS ==========

    /// @notice Test end-to-end integration: event detected -> sweep triggered
    /// @dev Validates: Requirements 42.1-42.5, 45.1-45.5
    function test_Integration_EventToSweep() public {
        // 1. Subscriber receives event and forwards it
        IReactive.LogRecord memory log = _createLogRecord(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1);

        subscriber.react(log);

        // 2. Keeper callback processes event and triggers sweep
        // The sweep should have been triggered above via the forward
        assertTrue(keeperCallback.getLastSweepTime(testPoolId) > 0);
    }

    /// @notice Test multiple sweeps with interval enforcement
    /// @dev Validates: Requirements 44.1-44.5
    function test_Integration_MultipleSweepsWithIntervalEnforcement() public {
        // First sweep
        _triggerSweep(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1, testPoolKey);
        uint256 firstSweepTime = block.timestamp;

        // Try to sweep again immediately - should fail
        IReactive.LogRecord memory log = _createLogRecord(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1);
        vm.expectRevert(ReactiveKeeperCallback.SweepTooSoon.selector);
        keeperCallback.react(log);

        // Warp time by less than interval - should still fail
        vm.warp(block.timestamp + DEFAULT_INTERVAL / 2);
        vm.expectRevert(ReactiveKeeperCallback.SweepTooSoon.selector);
        keeperCallback.react(log);

        // Warp time to exactly the interval - should succeed
        vm.warp(firstSweepTime + DEFAULT_INTERVAL + 1);

        // Now sweep should succeed
        _triggerSweep(testPoolId, IDLE_AMOUNT_0, IDLE_AMOUNT_1, testPoolKey);
        uint256 secondSweepTime = block.timestamp;

        assertGt(secondSweepTime, firstSweepTime + DEFAULT_INTERVAL);
    }

    /// @notice Test configuration changes take effect immediately
    /// @dev Validates: Requirements 43.1-43.5, 44.1-44.5
    function test_Integration_ConfigurationChanges() public {
        // Lower threshold
        keeperCallback.setSweepThreshold(0.5e18);

        // Lower interval
        keeperCallback.setMinSweepInterval(1 days);

        // Sweep with low idle amount should succeed
        _triggerSweep(testPoolId, 0.6e18, 0.1e18, testPoolKey);

        uint256 firstSweepTime = block.timestamp;

        // Warp 1 day
        vm.warp(block.timestamp + 1 days + 1);

        // Sweep should be allowed
        assertTrue(keeperCallback.canSweep(testPoolId));
    }

    // ========== HELPER FUNCTIONS ==========

    /// @notice Creates a LogRecord for testing
    function _createLogRecord(PoolId poolId, uint256 idleAmount0, uint256 idleAmount1)
        private
        view
        returns (IReactive.LogRecord memory)
    {
        bytes32 topicHash = subscriber.IDLE_CAPITAL_DETECTED_TOPIC();
        return IReactive.LogRecord({
            chain_id: block.chainid,
            _contract: hookAddress,
            topic_0: uint256(topicHash),
            topic_1: uint256(PoolId.unwrap(poolId)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(idleAmount0, idleAmount1, testPoolKey),
            block_number: block.number,
            op_code: 0,
            block_hash: uint256(blockhash(block.number - 1)),
            tx_hash: 0,
            log_index: 0
        });
    }

    /// @notice Triggers a sweep via the keeper callback
    function _triggerSweep(PoolId poolId, uint256 idleAmount0, uint256 idleAmount1, PoolKey memory poolKey) private {
        IReactive.LogRecord memory log = _createLogRecord(poolId, idleAmount0, idleAmount1);
        keeperCallback.react(log);
    }
}

// ========== MOCK CONTRACTS ==========

/// @title MockHook
/// @notice Mock hook contract for testing sweep triggering
contract MockHook {
    PoolKey public lastCalledPoolKey;

    function sweepIdleCapital(PoolKey calldata key) external {
        lastCalledPoolKey = key;
    }
}
