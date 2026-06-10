// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title MockPoolManager
/// @notice Simplified mock for testing hook access control
/// @dev Does not implement full IPoolManager to avoid interface complexity
///      Simply provides an address that can be used to test msg.sender checks
contract MockPoolManager {
    // Storage for arbitrary slot data (mimics extsload behavior)
    mapping(bytes32 => bytes32) private slots;

    // POOLS_SLOT constant from PoolManager (slot 6)
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));

    /// @notice Set slot0 data for a pool (for testing)
    function setSlot0(
        PoolId poolId,
        uint160 sqrtPriceX96,
        int24 tick,
        uint24 protocolFee,
        uint24 lpFee
    ) external {
        // Pack the data in the same format as v4-core
        bytes32 data;
        assembly ("memory-safe") {
            // Pack: sqrtPriceX96 (160 bits) | tick (24 bits) | protocolFee (24 bits) | lpFee (24 bits)
            data := or(sqrtPriceX96, shl(160, and(tick, 0xFFFFFF)))
            data := or(data, shl(184, and(protocolFee, 0xFFFFFF)))
            data := or(data, shl(208, and(lpFee, 0xFFFFFF)))
        }
        
        // Calculate the state slot using the same logic as StateLibrary
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
        slots[stateSlot] = data;
    }

    /// @notice Get slot data (matches v4-core IPoolManager.extsload)
    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }
    
    /// @notice Set arbitrary slot data (for advanced test scenarios)
    function setSlot(bytes32 slot, bytes32 value) external {
        slots[slot] = value;
    }
}
