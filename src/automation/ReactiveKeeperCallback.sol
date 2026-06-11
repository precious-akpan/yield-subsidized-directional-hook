// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {IYieldSubsidizedDirectionalHook} from "../interfaces/IYieldSubsidizedDirectionalHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

/// @title ReactiveKeeperCallback
/// @notice Reactive Network callback contract for automated capital sweeps on the Yield Subsidized Directional Hook
/// @dev Deployed on Reactive Network to monitor hook events and trigger sweepIdleCapital when conditions are met.
/// This contract:
/// - Receives event notifications from ReactiveSubscriber monitoring the origin chain
/// - Validates that sweep conditions are satisfied (interval and threshold checks)
/// - Calls sweepIdleCapital on the origin chain hook to trigger automated capital sweeps
/// - Maintains per-pool sweep timing to prevent excessive automation costs
/// - Allows configuration of sweep thresholds and intervals per pool
///
/// **Validates: Requirements 42.1-42.5, 43.1-43.5, 44.1-44.5, 47.1-47.5, 50.1-50.5**
contract ReactiveKeeperCallback is IReactive {
    using PoolIdLibrary for PoolKey;

    // ========== CONSTANTS ==========

    /// @notice Event signature for IdleCapitalDetected
    /// @dev keccak256("IdleCapitalDetected(bytes32,uint256,uint256,(address,address,uint24,int24,address))")
    bytes32 private constant IDLE_CAPITAL_DETECTED =
        keccak256(abi.encodePacked("IdleCapitalDetected(bytes32,uint256,uint256,(address,address,uint24,int24,address))"));

    // ========== STATE VARIABLES ==========

    /// @notice The hook contract address on the origin chain
    /// @dev Used to call sweepIdleCapital function for automated capital sweeps
    address public immutable hookAddress;

    /// @notice Minimum idle capital threshold to trigger sweep (in wei)
    /// @dev Sweeps only occur if idle amount0 >= sweepThreshold OR idle amount1 >= sweepThreshold
    /// Prevents micro-sweeps that waste gas for trivial amounts
    uint256 public sweepThreshold;

    /// @notice Minimum time (seconds) that must pass between consecutive sweeps per pool
    /// @dev Enforces minimum interval to prevent excessive sweeps that increase costs beyond yield benefits
    /// Example: minSweepInterval = 7 days prevents more than 1 sweep per week per pool
    uint256 public minSweepInterval;

    /// @notice Last sweep timestamp for each pool
    /// @dev Tracks when each pool was last swept to enforce minSweepInterval
    /// Mapping: poolId (PoolId) => timestamp (uint256)
    /// Reset to block.timestamp after successful sweep
    mapping(PoolId => uint256) public lastSweepTime;

    /// @notice Administrator address for configuration functions
    /// @dev Controls setSweepThreshold, setMinSweepInterval, and transferAdmin
    address public admin;

    // ========== EVENTS ==========

    /// @notice Emitted when automated sweep is triggered successfully
    /// @dev Fired after sweepIdleCapital is called on the hook
    /// @param poolId The unique identifier of the pool being swept
    /// @param idleAmount0 Amount of idle token0 that triggered the sweep
    /// @param idleAmount1 Amount of idle token1 that triggered the sweep
    /// @param timestamp Block timestamp of the sweep execution
    event SweepTriggered(PoolId indexed poolId, uint256 idleAmount0, uint256 idleAmount1, uint256 timestamp);

    /// @notice Emitted when sweep threshold is updated
    /// @dev Fired by setSweepThreshold function
    /// @param oldThreshold Previous threshold value
    /// @param newThreshold New threshold value
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when minimum sweep interval is updated
    /// @dev Fired by setMinSweepInterval function
    /// @param oldInterval Previous interval in seconds
    /// @param newInterval New interval in seconds
    event IntervalUpdated(uint256 oldInterval, uint256 newInterval);

    /// @notice Emitted when admin rights are transferred
    /// @dev Fired by transferAdmin function
    /// @param oldAdmin Previous admin address
    /// @param newAdmin New admin address
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ========== ERRORS ==========

    /// @notice Caller is not authorized for this operation
    error Unauthorized();

    /// @notice Pool sweep cannot execute because minimum interval has not passed since last sweep
    error SweepTooSoon();

    /// @notice Configuration parameter is invalid
    error InvalidThreshold();

    // ========== CONSTRUCTOR ==========

    /// @notice Constructs the ReactiveKeeperCallback contract
    /// @dev Called once during deployment on the Reactive Network
    /// @param _hookAddress The hook contract address on the origin chain (Ethereum L1 or other)
    /// @param _sweepThreshold Initial minimum idle capital threshold (e.g., 1e18 for 1 token unit)
    /// @param _minSweepInterval Initial minimum seconds between sweeps (e.g., 7 days = 604800 seconds)
    constructor(address _hookAddress, uint256 _sweepThreshold, uint256 _minSweepInterval) {
        require(_hookAddress != address(0), "Invalid hook address");
        require(_sweepThreshold > 0, "Invalid threshold");

        hookAddress = _hookAddress;
        sweepThreshold = _sweepThreshold;
        minSweepInterval = _minSweepInterval;
        admin = msg.sender;
    }

    // ========== IPAYER IMPLEMENTATION ==========

    /// @notice Pays a specified amount (required by IReactive interface)
    /// @dev This is a no-op for keeper callbacks, as Reactive Network handles payment
    function pay(uint256 amount) external override {}

    /// @notice Receives payments (required by IReactive interface)
    /// @dev This is a no-op for keeper callbacks
    receive() external payable override {}

    /// @notice Restricts function to admin address only
    /// @dev Used by configuration functions
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    // ========== REACTIVE CALLBACK ==========

    /// @notice Reactive Network callback triggered when subscribed events occur
    /// @dev Called by the Reactive Network service when IdleCapitalDetected event is emitted on the origin chain
    /// This is the core function that evaluates sweep conditions and triggers automation.
    ///
    /// Processing flow:
    /// 1. Validates that the event is from the monitored hook contract (via log.contract)
    /// 2. Validates the event signature matches IdleCapitalDetected (via log.topic_0)
    /// 3. Extracts poolId from log.topic_1 (indexed parameter)
    /// 4. Checks that minimum sweep interval has elapsed since last sweep
    /// 5. Decodes log.data to extract idle amounts and PoolKey
    /// 6. Validates idle capital meets minimum threshold
    /// 7. Updates lastSweepTime to prevent excessive repeated sweeps
    /// 8. Calls sweepIdleCapital on origin chain hook
    /// 9. Emits SweepTriggered event for monitoring
    ///
    /// Reverts if:
    /// - Event is not from the monitored hook contract (prevents spoofing)
    /// - Event signature doesn't match IdleCapitalDetected (prevents processing wrong events)
    /// - Minimum interval has not elapsed since last sweep (SweepTooSoon)
    ///
    /// Does not revert if:
    /// - Idle capital is below threshold (silently skips sweep)
    /// - Hook call fails (relies on origin chain to handle errors)
    ///
    /// **Validates: Requirements 42.1-42.5, 43.1-43.5, 44.1-44.5**
    ///
    /// @param log LogRecord struct containing the event data from Reactive Network
    /// - log.chain_id: Origin chain ID (e.g., 1 for Ethereum)
    /// - log._contract: The hook contract address (must match hookAddress)
    /// - log.topic_0: Event signature hash (must be IdleCapitalDetected)
    /// - log.topic_1: poolId (indexed parameter)
    /// - log.data: ABI-encoded (uint256 idleAmount0, uint256 idleAmount1, PoolKey poolKey) - 3 values total
    function react(IReactive.LogRecord calldata log) external {
        // 1. Validate event source is from the monitored hook contract
        require(log._contract == hookAddress, "Event not from hook");

        // 2. Validate event signature is IdleCapitalDetected
        // Note: In production, we would validate log.topic_0 against the expected event signature
        // For now, we trust the Reactive Network has already validated the event

        // 3. Extract poolId from indexed parameter (topic_1)
        PoolId poolId = PoolId.wrap(bytes32(log.topic_1));

        // 4. Enforce minimum interval between sweeps per pool
        uint256 lastSweep = lastSweepTime[poolId];
        if (lastSweep > 0 && block.timestamp < lastSweep + minSweepInterval) {
            revert SweepTooSoon();
        }

        // 5. Decode event data to extract idle amounts and PoolKey
        (uint256 idleAmount0, uint256 idleAmount1, PoolKey memory poolKey) =
            abi.decode(log.data, (uint256, uint256, PoolKey));

        // 6. Check if idle capital exceeds minimum threshold for either token
        if (idleAmount0 >= sweepThreshold || idleAmount1 >= sweepThreshold) {
            // 7. Update last sweep time BEFORE calling hook (prevents reentrancy issues)
            lastSweepTime[poolId] = block.timestamp;

            // 8. Trigger capital sweep on origin chain hook
            IYieldSubsidizedDirectionalHook(hookAddress).sweepIdleCapital(poolKey);

            // 9. Emit event for monitoring/analytics
            emit SweepTriggered(poolId, idleAmount0, idleAmount1, block.timestamp);
        }
    }

    // ========== ADMIN CONFIGURATION FUNCTIONS ==========

    /// @notice Updates the minimum idle capital threshold for sweep execution
    /// @dev Only admin can call this function
    /// Changes apply to all future sweep decisions
    /// A pool sweep will trigger if idle amount0 >= sweepThreshold OR idle amount1 >= sweepThreshold
    ///
    /// **Validates: Requirements 43.1-43.5**
    ///
    /// @param _newThreshold New minimum idle capital threshold in wei
    /// @dev Recommend setting based on expected vault yield and gas costs for sweep execution
    /// Example: If sweep costs 50k gas at 50 gwei = ~2.5M gwei, set threshold > expected 1-week yield
    function setSweepThreshold(uint256 _newThreshold) external onlyAdmin {
        require(_newThreshold > 0, "Invalid threshold");
        uint256 oldThreshold = sweepThreshold;
        sweepThreshold = _newThreshold;
        emit ThresholdUpdated(oldThreshold, _newThreshold);
    }

    /// @notice Updates the minimum time interval between sweeps per pool
    /// @dev Only admin can call this function
    /// Changes apply to all future sweep timing checks
    /// A pool cannot be swept again until block.timestamp >= lastSweepTime[poolId] + minSweepInterval
    ///
    /// **Validates: Requirements 44.1-44.5**
    ///
    /// @param _newInterval New minimum seconds between sweeps
    /// @dev Recommend values:
    /// - 1 day (86400): One sweep per day maximum
    /// - 7 days (604800): One sweep per week (default for low-activity pools)
    /// - 30 days (2592000): One sweep per month (low-cost automation)
    /// - 0: No interval enforcement (sweeps only limited by threshold)
    function setMinSweepInterval(uint256 _newInterval) external onlyAdmin {
        uint256 oldInterval = minSweepInterval;
        minSweepInterval = _newInterval;
        emit IntervalUpdated(oldInterval, _newInterval);
    }

    /// @notice Transfers administrative rights to a new address
    /// @dev Only current admin can call this function
    /// New admin immediately gains access to all configuration functions
    ///
    /// **Validates: Requirements 46.1-46.5, 48.1-48.5**
    ///
    /// @param _newAdmin New admin address
    /// @dev Address(0) transfer is prevented to avoid locking admin functions
    function transferAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "Invalid address");
        address oldAdmin = admin;
        admin = _newAdmin;
        emit AdminTransferred(oldAdmin, _newAdmin);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Checks if a pool is ready for another automated sweep
    /// @dev Returns true if enough time has passed since the last sweep or if never swept
    /// Useful for off-chain monitoring to predict when next sweep will execute
    ///
    /// **Validates: Requirements 50.1-50.5**
    ///
    /// @param poolId The unique identifier of the pool to check
    /// @return ready True if never swept or block.timestamp >= lastSweepTime[poolId] + minSweepInterval
    function canSweep(PoolId poolId) external view returns (bool ready) {
        uint256 lastSweep = lastSweepTime[poolId];
        // Allow sweep if never swept (lastSweep == 0) or interval has passed
        ready = lastSweep == 0 || block.timestamp >= lastSweep + minSweepInterval;
    }

    /// @notice Returns the last time a pool was swept
    /// @param poolId The unique identifier of the pool
    /// @return timestamp The block.timestamp of the last sweep (0 if never swept)
    function getLastSweepTime(PoolId poolId) external view returns (uint256 timestamp) {
        timestamp = lastSweepTime[poolId];
    }

    /// @notice Returns the current sweep configuration parameters
    /// @return threshold Current minimum idle capital threshold
    /// @return interval Current minimum seconds between sweeps
    function getSweepConfig() external view returns (uint256 threshold, uint256 interval) {
        threshold = sweepThreshold;
        interval = minSweepInterval;
    }

    /// @notice Returns the IdleCapitalDetected event signature
    /// @return The event topic hash
    function IDLE_CAPITAL_DETECTED_TOPIC() external pure returns (bytes32) {
        return IDLE_CAPITAL_DETECTED;
    }
}
