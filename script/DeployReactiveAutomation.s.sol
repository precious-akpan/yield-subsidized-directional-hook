// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ReactiveKeeperCallback} from "../src/automation/ReactiveKeeperCallback.sol";
import {ReactiveSubscriber} from "../src/automation/ReactiveSubscriber.sol";

/// @title DeployReactiveAutomation
/// @notice Script to deploy Reactive Network automation contracts
/// @dev Deploy callback on Reactive Network, subscriber on origin chain
contract DeployReactiveAutomation is Script {
    // Default configuration values
    uint256 constant DEFAULT_SWEEP_THRESHOLD = 1 ether; // 1 token minimum
    uint256 constant DEFAULT_SWEEP_INTERVAL = 1 hours; // Minimum 1 hour between sweeps

    function run() external {
        // Load environment variables
        address reactiveService = vm.envAddress("REACTIVE_SERVICE_ADDRESS");
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        
        // Optional: custom thresholds
        uint256 sweepThreshold = vm.envOr("SWEEP_THRESHOLD", DEFAULT_SWEEP_THRESHOLD);
        uint256 sweepInterval = vm.envOr("SWEEP_INTERVAL", DEFAULT_SWEEP_INTERVAL);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy callback contract (on Reactive Network)
        console2.log("Deploying ReactiveKeeperCallback...");
        ReactiveKeeperCallback callback = new ReactiveKeeperCallback(
            reactiveService,
            hookAddress,
            sweepThreshold,
            sweepInterval
        );
        console2.log("ReactiveKeeperCallback deployed at:", address(callback));

        // Deploy subscriber contract (on origin chain)
        console2.log("Deploying ReactiveSubscriber...");
        ReactiveSubscriber subscriber = new ReactiveSubscriber(
            reactiveService,
            hookAddress,
            address(callback)
        );
        console2.log("ReactiveSubscriber deployed at:", address(subscriber));

        vm.stopBroadcast();

        // Log deployment summary
        console2.log("\n=== Deployment Summary ===");
        console2.log("Reactive Service:", reactiveService);
        console2.log("Hook Address:", hookAddress);
        console2.log("Callback Contract:", address(callback));
        console2.log("Subscriber Contract:", address(subscriber));
        console2.log("Sweep Threshold:", sweepThreshold);
        console2.log("Sweep Interval:", sweepInterval, "seconds");
        console2.log("========================\n");
    }
}
