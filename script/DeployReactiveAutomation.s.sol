// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ReactiveKeeperCallback} from "../src/automation/ReactiveKeeperCallback.sol";
import {ReactiveSubscriber} from "../src/automation/ReactiveSubscriber.sol";

/// @title DeployReactiveAutomation
/// @notice Foundry script to deploy Reactive Network automation contracts for the Yield Subsidized Directional Hook
/// @dev This script deploys two contracts:
///   1. ReactiveKeeperCallback - deployed on Reactive Network for automated sweep triggering
///   2. ReactiveSubscriber - deployed on origin chain for event monitoring and forwarding
///
/// Environment Variables Required:
///   - REACTIVE_SERVICE_ADDRESS: Reactive Network service contract address
///   - HOOK_ADDRESS: YieldSubsidizedDirectionalHook contract address on origin chain
///   - PRIVATE_KEY: Deployer private key
///
/// Environment Variables Optional:
///   - SWEEP_THRESHOLD: Minimum idle capital to trigger sweep (default: 1 ether)
///   - SWEEP_INTERVAL: Minimum seconds between sweeps (default: 1 hour)
///
/// Usage:
///   # Deploy to Reactive Network (for callback contract)
///   forge script script/DeployReactiveAutomation.s.sol:DeployReactiveAutomation \
///     --rpc-url $REACTIVE_NETWORK_RPC_URL \
///     --broadcast \
///     --verify
///
///   # Deploy to origin chain (for subscriber contract)
///   forge script script/DeployReactiveAutomation.s.sol:DeployReactiveAutomation \
///     --rpc-url $ORIGIN_CHAIN_RPC_URL \
///     --broadcast \
///     --verify
///
/// **Validates: Requirements 42.1-42.5, 45.1-45.5**
contract DeployReactiveAutomation is Script {
    // ========== CONFIGURATION ==========

    /// @notice Default minimum idle capital threshold for sweep triggering (1 token with 18 decimals)
    uint256 constant DEFAULT_SWEEP_THRESHOLD = 1 ether;

    /// @notice Default minimum time between consecutive sweeps per pool (1 hour)
    uint256 constant DEFAULT_SWEEP_INTERVAL = 1 hours;

    // ========== DEPLOYMENT STATE ==========

    /// @notice Address of the Reactive Network service contract
    address public reactiveServiceAddress;

    /// @notice Address of the YieldSubsidizedDirectionalHook on origin chain
    address public hookAddress;

    /// @notice Minimum idle capital threshold for triggering sweeps
    uint256 public sweepThreshold;

    /// @notice Minimum seconds between consecutive sweeps per pool
    uint256 public sweepInterval;

    /// @notice Deployed ReactiveKeeperCallback contract address
    address public callbackContract;

    /// @notice Deployed ReactiveSubscriber contract address
    address public subscriberContract;

    // ========== ERRORS ==========

    error InvalidReactiveServiceAddress();
    error InvalidHookAddress();
    error InvalidPrivateKey();

    // ========== MAIN ENTRY POINT ==========

    /// @notice Main deployment function - orchestrates the full deployment flow
    /// @dev Reads environment variables, deploys contracts, logs deployment addresses
    function run() external virtual {
        // Step 1: Load and validate configuration from environment
        _loadConfiguration();

        // Step 2: Log deployment parameters
        _logDeploymentParameters();

        // Step 3: Deploy contracts with broadcast
        _deployContracts();

        // Step 4: Output deployment summary and verification instructions
        _outputDeploymentSummary();
    }

    // ========== INTERNAL FUNCTIONS ==========

    /// @notice Loads configuration from environment variables
    /// @dev Validates required parameters and sets defaults for optional ones
    function _loadConfiguration() internal {
        // Required: Reactive Network service address
        reactiveServiceAddress = vm.envAddress("REACTIVE_SERVICE_ADDRESS");
        if (reactiveServiceAddress == address(0)) revert InvalidReactiveServiceAddress();

        // Required: Hook contract address on origin chain
        hookAddress = vm.envAddress("HOOK_ADDRESS");
        if (hookAddress == address(0)) revert InvalidHookAddress();

        // Optional: Sweep threshold (default: 1 ether)
        sweepThreshold = vm.envOr("SWEEP_THRESHOLD", DEFAULT_SWEEP_THRESHOLD);

        // Optional: Sweep interval (default: 1 hour)
        sweepInterval = vm.envOr("SWEEP_INTERVAL", DEFAULT_SWEEP_INTERVAL);
    }

    /// @notice Logs deployment parameters before execution
    function _logDeploymentParameters() internal view {
        console2.log("=== Deployment Configuration ===");
        console2.log("Reactive Service Address:", reactiveServiceAddress);
        console2.log("Hook Address:", hookAddress);
        console2.log("Sweep Threshold:", sweepThreshold);
        console2.log("Sweep Interval:", sweepInterval, "seconds");
        console2.log("================================");
    }

    /// @notice Deploys both automation contracts
    /// @dev Uses vm.broadcast for on-chain deployment
    function _deployContracts() internal {
        // Get deployer private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Start broadcast for on-chain deployment
        vm.startBroadcast(deployerPrivateKey);

        // Deploy ReactiveKeeperCallback
        // This contract is deployed on Reactive Network and triggers sweepIdleCapital
        console2.log("[1/2] Deploying ReactiveKeeperCallback...");
        ReactiveKeeperCallback callback = new ReactiveKeeperCallback(hookAddress, sweepThreshold, sweepInterval);
        callbackContract = address(callback);
        console2.log("    ReactiveKeeperCallback deployed at:", callbackContract);
        console2.log("    - hookAddress:", hookAddress);
        console2.log("    - sweepThreshold:", sweepThreshold);
        console2.log("    - sweepInterval:", sweepInterval);

        // Deploy ReactiveSubscriber
        // This contract is deployed on origin chain and forwards events to Reactive Network
        console2.log("[2/2] Deploying ReactiveSubscriber...");
        ReactiveSubscriber subscriber = new ReactiveSubscriber(hookAddress, callbackContract);
        subscriberContract = address(subscriber);
        console2.log("    ReactiveSubscriber deployed at:", subscriberContract);
        console2.log("    - hookAddress:", hookAddress);
        console2.log("    - callbackContract:", callbackContract);

        vm.stopBroadcast();
    }

    /// @notice Outputs deployment summary and verification instructions
    function _outputDeploymentSummary() internal view {
        console2.log("");
        console2.log("================================================================");
        console2.log("              DEPLOYMENT SUCCESSFUL");
        console2.log("================================================================");
        console2.log("");
        console2.log("  ReactiveKeeperCallback (Reactive Network):");
        console2.log("    Address:", callbackContract);
        console2.log("");
        console2.log("  ReactiveSubscriber (Origin Chain):");
        console2.log("    Address:", subscriberContract);
        console2.log("");
        console2.log("  Configuration:");
        console2.log("    Hook Address:", hookAddress);
        console2.log("    Sweep Threshold:", sweepThreshold);
        console2.log("    Sweep Interval:", sweepInterval, "seconds");
        console2.log("");
        console2.log("================================================================");

        // Output verification commands
        _outputVerificationInstructions();
    }

    /// @notice Outputs verification instructions for deployed contracts
    function _outputVerificationInstructions() internal view {
        console2.log("");
        console2.log("=== Verification Instructions ===");
        console2.log("");

        // Verify ReactiveKeeperCallback
        console2.log("1. Verify ReactiveKeeperCallback on Reactive Network:");
        console2.log("   forge verify-contract \\");
        console2.log("     --chain-id <REACTIVE_CHAIN_ID> \\");
        console2.log("     --num-of-optimizations 200 \\");
        console2.log("     --watch \\");
        console2.log("     --constructor-args (cast abi-encode constructor(address,uint256,uint256)) \\");
        console2.log("     --verifier <VERIFIER_URL> \\");
        console2.log("     <CALLBACK_ADDRESS> \\");
        console2.log("     src/automation/ReactiveKeeperCallback.sol:ReactiveKeeperCallback");
        console2.log("");

        // Verify ReactiveSubscriber
        console2.log("2. Verify ReactiveSubscriber on Origin Chain:");
        console2.log("   forge verify-contract \\");
        console2.log("     --chain-id <ORIGIN_CHAIN_ID> \\");
        console2.log("     --num-of-optimizations 200 \\");
        console2.log("     --watch \\");
        console2.log("     --constructor-args (cast abi-encode constructor(address,address)) \\");
        console2.log("     --verifier-url <ETHERSCAN_API_URL> \\");
        console2.log("     <SUBSCRIBER_ADDRESS> \\");
        console2.log("     src/automation/ReactiveSubscriber.sol:ReactiveSubscriber");
        console2.log("");

        // Post-deployment steps
        console2.log("=== Post-Deployment Steps ===");
        console2.log("");
        console2.log("1. Fund ReactiveKeeperCallback on Reactive Network for automation costs");
        console2.log("   (Reactive Network may require subscription or deposit)");
        console2.log("");

        console2.log("2. Update ReactiveSubscriber callback address (if deployed separately):");
        console2.log("   subscriber.setCallbackContract(<CALLBACK_ADDRESS>)");
        console2.log("");

        console2.log("3. Configure automation parameters (optional):");
        console2.log("   callback.setSweepThreshold(<new_threshold>)");
        console2.log("   callback.setMinSweepInterval(<new_interval>)");
        console2.log("");

        console2.log("4. Monitor automation events:");
        console2.log("   - SweepTriggered(poolId, idleAmount0, idleAmount1, timestamp)");
        console2.log("   - EventForwarded(poolId, idleAmount0, idleAmount1)");
        console2.log("");

        console2.log("=== Deployment Complete ===");
    }
}

/// @title DeployCallbackOnly
/// @notice Helper script to deploy only ReactiveKeeperCallback (for Reactive Network deployment)
/// @dev Use this when deploying to Reactive Network separately from origin chain
contract DeployCallbackOnly is DeployReactiveAutomation {
    /// @notice Deploys only the ReactiveKeeperCallback contract
    function run() external override {
        // Load configuration
        _loadConfiguration();
        _logDeploymentParameters();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy only ReactiveKeeperCallback
        console2.log("[1/1] Deploying ReactiveKeeperCallback...");
        ReactiveKeeperCallback callback = new ReactiveKeeperCallback(hookAddress, sweepThreshold, sweepInterval);
        callbackContract = address(callback);
        console2.log("    ReactiveKeeperCallback deployed at:", callbackContract);

        vm.stopBroadcast();

        console2.log("=== Callback Deployment Complete ===");
        console2.log("ReactiveKeeperCallback:", callbackContract);
        console2.log("Hook Address:", hookAddress);
        console2.log("Sweep Threshold:", sweepThreshold);
        console2.log("Sweep Interval:", sweepInterval);
        console2.log("Note: Deploy ReactiveSubscriber on origin chain with this callback address.");
    }
}

/// @title DeploySubscriberOnly
/// @notice Helper script to deploy only ReactiveSubscriber (for origin chain deployment)
/// @dev Use this when deploying to origin chain after callback is deployed on Reactive Network
contract DeploySubscriberOnly is DeployReactiveAutomation {
    /// @notice Deploys only the ReactiveSubscriber contract
    /// @dev Requires CALLBACK_CONTRACT env var pointing to deployed ReactiveKeeperCallback
    function run() external override {
        // Load required addresses
        hookAddress = vm.envAddress("HOOK_ADDRESS");
        address deployedCallback = vm.envAddress("CALLBACK_CONTRACT");

        if (hookAddress == address(0)) revert InvalidHookAddress();
        if (deployedCallback == address(0)) revert InvalidReactiveServiceAddress();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console2.log("=== Subscriber Deployment Configuration ===");
        console2.log("Hook Address:", hookAddress);
        console2.log("Callback Contract:", deployedCallback);
        console2.log("============================================");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy only ReactiveSubscriber
        console2.log("[1/1] Deploying ReactiveSubscriber...");
        ReactiveSubscriber subscriber = new ReactiveSubscriber(hookAddress, deployedCallback);
        subscriberContract = address(subscriber);
        console2.log("    ReactiveSubscriber deployed at:", subscriberContract);

        vm.stopBroadcast();

        console2.log("=== Subscriber Deployment Complete ===");
        console2.log("ReactiveSubscriber:", subscriberContract);
        console2.log("Hook Address:", hookAddress);
        console2.log("Callback Contract:", deployedCallback);
    }
}
