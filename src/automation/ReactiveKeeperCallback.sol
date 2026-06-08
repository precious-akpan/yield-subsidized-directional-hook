// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/AbstractReactive.sol";
import {IYieldSubsidizedDirectionalHook} from "../interfaces/IYieldSubsidizedDirectionalHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title ReactiveKeeperCallback
/// @notice Reactive Network callback contract for automated capital sweeps
/// @dev Subscribes to pool events and triggers sweepIdleCapital when conditions are met
contract ReactiveKeeperCallback is AbstractReactive {
    // ========== STATE VARIABLES ==========

    /// @notice The hook contract to interact with
    IYieldSubsidizedDirectionalHook public immutable hook;

    /// @notice Minimum idle capital threshold to trigger sweep (in wei)
    uint256 public sweepThreshold;

    /// @notice Minimum time between sweeps per pool (seconds)
    uint256 public minSweepInterval;

    /// @notice Last sweep timestamp per pool
    mapping(bytes32 => uint256) public lastSweepTime;

    /// @notice Admin address for configuration
    address public admin;

    // ========== EVENTS ==========

    event SweepTriggered(bytes32 indexed poolId, uint256 idleAmount0, uint256 idleAmount1);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event IntervalUpdated(uint256 oldInterval, uint256 newInterval);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ========== ERRORS ==========

    error Unauthorized();
    error SweepTooSoon();
    error InvalidThreshold();

    // ========== CONSTRUCTOR ==========

    /// @notice Constructs the reactive keeper callback
    /// @param _service The Reactive Network service address
    /// @param _hook The hook contract address
    /// @param _sweepThreshold Minimum idle capital to trigger sweep
    /// @param _minSweepInterval Minimum seconds between sweeps
    constructor(
        address _service,
        address _hook,
        uint256 _sweepThreshold,
        uint256 _minSweepInterval
    ) AbstractReactive(_service) {
        hook = IYieldSubsidizedDirectionalHook(_hook);
        sweepThreshold = _sweepThreshold;
        minSweepInterval = _minSweepInterval;
        admin = msg.sender;
    }

    // ========== MODIFIERS ==========

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    // ========== REACTIVE CALLBACK ==========

    /// @notice Reactive Network callback triggered by subscribed events
    /// @dev Called by Reactive Network when monitored events occur
    /// @param _topics Event topics (topic[0] = event signature, topic[1] = poolId)
    /// @param _data Event data (idle amounts, etc.)
    /// @param /*_origin*/ Origin chain information (unused)
    /// @param /*_sender*/ Original event emitter (unused)
    function react(
        uint256[] calldata _topics,
        bytes calldata _data,
        uint256 /*_origin*/,
        address /*_sender*/
    ) external override {
        // Ensure call is from Reactive Network service
        if (msg.sender != service) revert Unauthorized();

        // Extract poolId from topics
        bytes32 poolId = bytes32(_topics[1]);

        // Check sweep interval
        if (block.timestamp < lastSweepTime[poolId] + minSweepInterval) {
            revert SweepTooSoon();
        }

        // Decode event data to get idle amounts
        (uint256 idleAmount0, uint256 idleAmount1, PoolKey memory poolKey) = 
            abi.decode(_data, (uint256, uint256, PoolKey));

        // Check if idle capital exceeds threshold
        if (idleAmount0 >= sweepThreshold || idleAmount1 >= sweepThreshold) {
            // Update last sweep time
            lastSweepTime[poolId] = block.timestamp;

            // Trigger capital sweep
            hook.sweepIdleCapital(poolKey);

            emit SweepTriggered(poolId, idleAmount0, idleAmount1);
        }
    }

    // ========== ADMIN FUNCTIONS ==========

    /// @notice Updates the sweep threshold
    /// @param _newThreshold New minimum idle capital threshold
    function setSweepThreshold(uint256 _newThreshold) external onlyAdmin {
        if (_newThreshold == 0) revert InvalidThreshold();
        uint256 oldThreshold = sweepThreshold;
        sweepThreshold = _newThreshold;
        emit ThresholdUpdated(oldThreshold, _newThreshold);
    }

    /// @notice Updates the minimum sweep interval
    /// @param _newInterval New minimum seconds between sweeps
    function setMinSweepInterval(uint256 _newInterval) external onlyAdmin {
        uint256 oldInterval = minSweepInterval;
        minSweepInterval = _newInterval;
        emit IntervalUpdated(oldInterval, _newInterval);
    }

    /// @notice Transfers admin rights
    /// @param _newAdmin New admin address
    function transferAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "Invalid address");
        address oldAdmin = admin;
        admin = _newAdmin;
        emit AdminTransferred(oldAdmin, _newAdmin);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Checks if a pool is ready for sweep
    /// @param poolId The pool identifier
    /// @return ready True if enough time has passed since last sweep
    function canSweep(bytes32 poolId) external view returns (bool ready) {
        ready = block.timestamp >= lastSweepTime[poolId] + minSweepInterval;
    }
}
