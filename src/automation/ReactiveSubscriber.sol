// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {IYieldSubsidizedDirectionalHook} from "../interfaces/IYieldSubsidizedDirectionalHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title ReactiveSubscriber
/// @notice Contract that subscribes to hook events and forwards them to the ReactiveKeeperCallback
/// @dev Deployed on the origin chain to monitor hook events and relay them to Reactive Network for automated keeper operations.
/// This contract:
/// - Monitors IdleCapitalDetected events emitted by the hook
/// - Forwards these events to the Reactive Network service
/// - Allows the ReactiveKeeperCallback on Reactive Network to process them
/// - Maintains subscriptions and allows admin configuration
///
/// **Validates: Requirements 45.1-45.5, 47.1-47.5**
contract ReactiveSubscriber is IReactive {
    // ========== CONSTANTS ==========

    /// @notice Event signature for IdleCapitalDetected
    /// @dev keccak256("IdleCapitalDetected(bytes32,uint256,uint256,(address,address,uint24,int24,address))")
    /// This is the event we subscribe to for automated sweep triggering
    bytes32 private constant IDLE_CAPITAL_DETECTED =
        keccak256(abi.encodePacked("IdleCapitalDetected(bytes32,uint256,uint256,(address,address,uint24,int24,address))"));

    // ========== STATE VARIABLES ==========

    /// @notice Address of the hook contract being monitored
    /// @dev All events must originate from this address to be processed
    address public immutable hookAddress;

    /// @notice Address of the ReactiveKeeperCallback contract on Reactive Network
    /// @dev Used to forward IdleCapitalDetected events for processing
    address payable public callbackContract;

    /// @notice Administrator address for configuration functions
    /// @dev Controls setCallbackContract and transferAdmin
    address public admin;

    /// @notice Whether this contract is actively subscribed to hook events
    /// @dev Used to prevent duplicate subscriptions
    bool public isSubscribed;

    // ========== EVENTS ==========

    /// @notice Emitted when subscription is successfully created
    /// @dev Fired during constructor or when subscribing to new event topics
    /// @param eventTopic The event signature hash being subscribed to
    /// @param hookAddress The hook contract address being monitored
    event SubscriptionCreated(bytes32 indexed eventTopic, address indexed hookAddress);

    /// @notice Emitted when the callback contract address is updated
    /// @dev Fired by setCallbackContract function
    /// @param oldCallback Previous callback contract address
    /// @param newCallback New callback contract address
    event CallbackContractUpdated(address indexed oldCallback, address indexed newCallback);

    /// @notice Emitted when admin rights are transferred
    /// @dev Fired by transferAdmin function
    /// @param oldAdmin Previous admin address
    /// @param newAdmin New admin address
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted when an event is successfully forwarded to Reactive Network
    /// @dev Fired after react() processes a monitored event
    /// @param poolId Pool identifier from the event
    /// @param idleAmount0 Idle token0 amount
    /// @param idleAmount1 Idle token1 amount
    event EventForwarded(bytes32 indexed poolId, uint256 idleAmount0, uint256 idleAmount1);

    // ========== ERRORS ==========

    /// @notice Caller is not authorized for this operation
    error Unauthorized();

    /// @notice Address parameter is invalid (e.g., address(0))
    error InvalidAddress();

    /// @notice Event signature does not match expected topic
    error InvalidEventSignature();

    // ========== CONSTRUCTOR ==========

    /// @notice Constructs the ReactiveSubscriber contract
    /// @dev Called once during deployment on the origin chain
    /// @param _hookAddress The hook contract address to monitor
    /// @param _callbackContract The Reactive Network callback contract to forward events to
    constructor(address _hookAddress, address _callbackContract) {
        require(_hookAddress != address(0), "Invalid hook address");
        require(_callbackContract != address(0), "Invalid callback address");

        hookAddress = _hookAddress;
        callbackContract = payable(_callbackContract);
        admin = msg.sender;
        isSubscribed = false;
    }

    // ========== IPAYER IMPLEMENTATION ==========

    /// @notice Pays a specified amount (required by IReactive interface)
    /// @dev This is a no-op for subscribers, as Reactive Network handles payment
    function pay(uint256 amount) external override {}

    /// @notice Receives payments (required by IReactive interface)
    /// @dev This is a no-op for subscribers
    receive() external payable override {}

    // ========== MODIFIERS ==========

    /// @notice Restricts function to admin address only
    /// @dev Used by configuration functions
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    // ========== REACTIVE CALLBACK ==========

    /// @notice Reactive Network callback triggered when subscribed events occur on origin chain
    /// @dev Called by the Reactive Network service when IdleCapitalDetected events are detected
    /// This contract receives the event and forwards it to the callback contract.
    ///
    /// Processing flow:
    /// 1. Validates that the event originated from the monitored hook (via log._contract)
    /// 2. Validates that the event signature matches IdleCapitalDetected (via log.topic_0)
    /// 3. Forwards the complete event data to the callback contract
    /// 4. Emits EventForwarded for monitoring
    ///
    /// Reverts if:
    /// - Event is not from the monitored hook contract (prevents processing unrelated events)
    /// - Event signature doesn't match IdleCapitalDetected (prevents processing wrong events)
    ///
    /// **Validates: Requirements 45.1-45.5, 47.1-47.5**
    ///
    /// @param log LogRecord struct containing the event data from Reactive Network
    /// - log._contract: The hook contract address (must match hookAddress)
    /// - log.topic_0: Event signature hash (must be IdleCapitalDetected)
    /// - log.topic_1: poolId (indexed parameter)
    /// - log.data: ABI-encoded (uint256 idleAmount0, uint256 idleAmount1, PoolKey poolKey)
    function react(IReactive.LogRecord calldata log) external {
        // 1. Verify event is from the monitored hook
        require(log._contract == hookAddress, "Event not from hook");

        // 2. Verify event signature matches IdleCapitalDetected
        require(log.topic_0 == uint256(IDLE_CAPITAL_DETECTED), "Invalid event signature");

        // Extract pool ID from indexed parameter
        bytes32 poolId = bytes32(log.topic_1);

        // Decode idle amounts and PoolKey from event data
        (uint256 idleAmount0, uint256 idleAmount1,) = abi.decode(log.data, (uint256, uint256, PoolKey));

        // 3. Forward event to callback contract on Reactive Network
        IReactive(callbackContract).react(log);

        // 4. Emit event for monitoring
        emit EventForwarded(poolId, idleAmount0, idleAmount1);
    }

    // ========== ADMIN CONFIGURATION FUNCTIONS ==========

    /// @notice Updates the callback contract address
    /// @dev Only admin can call this function
    /// New callbacks can subscribe to different events or implement different logic
    ///
    /// **Validates: Requirements 47.1-47.5**
    ///
    /// @param _newCallback New callback contract address on Reactive Network
    function setCallbackContract(address _newCallback) external onlyAdmin {
        require(_newCallback != address(0), "Invalid address");
        address oldCallback = address(callbackContract);
        callbackContract = payable(_newCallback);
        emit CallbackContractUpdated(oldCallback, address(_newCallback));
    }

    /// @notice Transfers administrative rights to a new address
    /// @dev Only current admin can call this function
    /// New admin immediately gains access to all configuration functions
    ///
    /// @param _newAdmin New admin address
    function transferAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "Invalid address");
        address oldAdmin = admin;
        admin = _newAdmin;
        emit AdminTransferred(oldAdmin, _newAdmin);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Returns the hook address being monitored
    /// @return The immutable hook contract address
    function getHookAddress() external view returns (address) {
        return hookAddress;
    }

    /// @notice Returns the current callback contract address
    /// @return The callback contract address
    function getCallbackContract() external view returns (address) {
        return address(callbackContract);
    }

    /// @notice Returns the current admin address
    /// @return The admin address
    function getAdmin() external view returns (address) {
        return admin;
    }

    /// @notice Returns the IdleCapitalDetected event signature
    /// @return The event topic hash
    function IDLE_CAPITAL_DETECTED_TOPIC() external pure returns (bytes32) {
        return IDLE_CAPITAL_DETECTED;
    }
}
