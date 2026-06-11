// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {YieldSubsidizedDirectionalHook} from "../../src/YieldSubsidizedDirectionalHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

/// @title YieldSubsidizedDirectionalHookHelper
/// @notice Test helper contract that exposes internal functions for unit testing
/// @dev Wraps YieldSubsidizedDirectionalHook to make internal functions public
contract YieldSubsidizedDirectionalHookHelper is YieldSubsidizedDirectionalHook {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager _poolManager) YieldSubsidizedDirectionalHook(_poolManager) {}

    // ============ EXPOSED ORACLE AND PRICE UTILITIES ============

    /// @notice Exposes getOraclePriceWithValidation for testing
    /// @dev Calls internal function directly as inheritance allows access
    function testGetOraclePriceWithValidation(PoolKey calldata key) public returns (uint256 price, bool isValid) {
        // Call internal function (accessible via inheritance)
        return YieldSubsidizedDirectionalHook.getOraclePriceWithValidation(key);
    }

    /// @notice Exposes sqrtPriceX96ToPrice for testing
    /// @dev Calls internal function directly as inheritance allows access
    function testSqrtPriceX96ToPrice(uint160 sqrtPriceX96) public pure returns (uint256 price) {
        // Call internal function (accessible via inheritance)
        return YieldSubsidizedDirectionalHook.sqrtPriceX96ToPrice(sqrtPriceX96);
    }

    /// @notice Exposes calculateDeviation for testing
    /// @dev Calls internal function directly as inheritance allows access
    function testCalculateDeviation(uint256 price1, uint256 price2) public pure returns (uint256 deviationBps) {
        // Call internal function (accessible via inheritance)
        return YieldSubsidizedDirectionalHook.calculateDeviation(price1, price2);
    }

    // ============ HELPER FUNCTIONS FOR TEST SETUP ============

    /// @notice Allows test to set pool configuration directly
    function setPoolConfig(PoolId poolId, DataTypes.PoolConfig memory config) external {
        poolConfigs[poolId] = config;
    }

    /// @notice Allows test to register pool directly
    function registerPool(PoolId poolId) external {
        registeredPools[poolId] = true;
    }

    // ============ EXPOSED LP POSITION TRACKING ============

    /// @notice Exposes trackLPPosition for testing
    /// @dev Calls internal function directly as inheritance allows access
    function testTrackLPPosition(address lp, PoolId poolId, DataTypes.LPPosition memory position) external {
        // Call internal function (accessible via inheritance)
        return YieldSubsidizedDirectionalHook.trackLPPosition(lp, poolId, position);
    }
}
