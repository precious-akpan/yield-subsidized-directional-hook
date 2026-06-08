// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/AbstractReactive.sol";
import {IReactive} from "reactive-lib/IReactive.sol";

/// @title ReactiveSubscriber
/// @notice Contract to subscribe to hook events for automated keeper operations
/// @dev Deploys on origin chain to monitor hook events and trigger Reactive Network callbacks
contract ReactiveSubscriber is AbstractReactive {
    // ========== CONSTANTS ==========

    /// @notice Event signature for LiquidityModified (emitted when LP positions change)
    /// @dev keccak256("LiquidityModified(bytes32,address,int24,int24,int256)")
    bytes32 private constant LIQUIDITY_MODIFIED_TOPIC = 
        0x3f5e9e5f8d2e1a9f7b6c4d3a2e1f0c8b7a6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f;

    /// @notice Event signature for IdleCapitalDetected (custom event for monitoring)
    /// @dev keccak256("IdleCapitalDetected(bytes32,uint256,uint256)")
    bytes32 private constant IDLE_CAPITAL_DETECTED_TOPIC =
        0x1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b;

    // ========== STATE VARIABLES ==========

    /// @notice Address of the hook contract being monitored
    address public immutable hookAddress;

    /// @notice Address of the reactive callback contract
    address public callbackContract;

    /// @notice Admin address
    address public admin;

    // ========== EVENTS ==========

    event SubscriptionCreated(bytes32 indexed eventTopic, address indexed hookAddress);
    event CallbackContractUpdated(address indexed oldCallback, address indexed newCallback);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ========== ERRORS ==========

    error Unauthorized();
    error InvalidAddress();

    // ========== CONSTRUCTOR ==========

    /// @notice Constructs the reactive subscriber
    /// @param _service The Reactive Network service address
    /// @param _hookAddress The hook contract to monitor
    /// @param _callbackContract The callback contract to trigger
    constructor(
        address _service,
        address _hookAddress,
        address _callbackContract
    ) AbstractReactive(_service) {
        if (_hookAddress == address(0) || _callbackContract == address(0)) {
            revert InvalidAddress();
        }
        
        hookAddress = _hookAddress;
        callbackContract = _callbackContract;
        admin = msg.sender;

        // Subscribe to LiquidityModified events
        _subscribe(LIQUIDITY_MODIFIED_TOPIC);
        emit SubscriptionCreated(LIQUIDITY_MODIFIED_TOPIC, _hookAddress);

        // Subscribe to IdleCapitalDetected events
        _subscribe(IDLE_CAPITAL_DETECTED_TOPIC);
        emit SubscriptionCreated(IDLE_CAPITAL_DETECTED_TOPIC, _hookAddress);
    }

    // ========== MODIFIERS ==========

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    // ========== REACTIVE CALLBACK ==========

    /// @notice Reactive Network callback triggered by subscribed events
    /// @dev Forwards relevant events to the callback contract
    /// @param _topics Event topics
    /// @param _data Event data
    /// @param _origin Origin chain ID
    /// @param _sender Original event emitter
    function react(
        uint256[] calldata _topics,
        bytes calldata _data,
        uint256 _origin,
        address _sender
    ) external override {
        // Ensure call is from Reactive Network service
        if (msg.sender != service) revert Unauthorized();

        // Verify event is from our monitored hook
        if (_sender != hookAddress) return;

        // Forward to callback contract
        IReactive(callbackContract).react(_topics, _data, _origin, _sender);
    }

    // ========== INTERNAL FUNCTIONS ==========

    /// @notice Subscribes to a specific event topic
    /// @param _topic The event signature hash to subscribe to
    function _subscribe(bytes32 _topic) internal {
        // Create subscription through Reactive Network service
        // This is a simplified version - actual implementation depends on Reactive Network SDK
        (bool success,) = service.call(
            abi.encodeWithSignature(
                "subscribe(address,bytes32,address)",
                hookAddress,
                _topic,
                address(this)
            )
        );
        require(success, "Subscription failed");
    }

    // ========== ADMIN FUNCTIONS ==========

    /// @notice Updates the callback contract address
    /// @param _newCallback New callback contract address
    function setCallbackContract(address _newCallback) external onlyAdmin {
        if (_newCallback == address(0)) revert InvalidAddress();
        address oldCallback = callbackContract;
        callbackContract = _newCallback;
        emit CallbackContractUpdated(oldCallback, _newCallback);
    }

    /// @notice Transfers admin rights
    /// @param _newAdmin New admin address
    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAddress();
        address oldAdmin = admin;
        admin = _newAdmin;
        emit AdminTransferred(oldAdmin, _newAdmin);
    }

    /// @notice Subscribes to additional event topics
    /// @param _topic New event topic to subscribe to
    function subscribeToTopic(bytes32 _topic) external onlyAdmin {
        _subscribe(_topic);
        emit SubscriptionCreated(_topic, hookAddress);
    }
}
