// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20 as IERC20Token} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockPoolManager
/// @notice Simplified mock for testing hook access control and flash accounting
/// @dev Implements minimal IPoolManager interface for testing capital sweep flows
contract MockPoolManager {
    // Storage for arbitrary slot data (mimics extsload behavior)
    mapping(bytes32 => bytes32) private slots;

    // POOLS_SLOT constant from PoolManager (slot 6)
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));

    // Track ERC6909 balances for mint/burn operations
    mapping(address => mapping(uint256 => uint256)) private erc6909Balances;

    /// @notice Set slot0 data for a pool (for testing)
    function setSlot0(PoolId poolId, uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) external {
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

    /// @notice Unlock flash accounting (matches v4-core IPoolManager.unlock)
    /// @dev Calls the unlockCallback on the sender and returns the result
    /// @param data Arbitrary data to pass to the callback
    /// @return The data returned from the callback
    function unlock(bytes calldata data) external returns (bytes memory) {
        // Call unlockCallback on the sender
        (bool success, bytes memory result) = msg.sender.call(
            abi.encodeWithSignature("unlockCallback(bytes)", data)
        );
        
        require(success, "Unlock callback failed");
        return result;
    }

    /// @notice Take tokens from the pool (flash accounting)
    /// @dev In real PoolManager, this creates a debt. In mock, we just transfer tokens.
    /// @param currency The currency to take
    /// @param to The address to send tokens to
    /// @param amount The amount to take
    function take(Currency currency, address to, uint256 amount) external {
        // Transfer tokens from this contract to the recipient
        address token = Currency.unwrap(currency);
        IERC20Token(token).transfer(to, amount);
    }

    /// @notice Mint ERC6909 claims (settles debt from take)
    /// @dev In real PoolManager, this converts debt to claims. In mock, we just track balances.
    /// @param to The address to mint claims to
    /// @param id The currency ID (from Currency.toId())
    /// @param amount The amount to mint
    function mint(address to, uint256 id, uint256 amount) external {
        erc6909Balances[to][id] += amount;
    }

    /// @notice Get ERC6909 balance (for testing)
    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return erc6909Balances[owner][id];
    }
}
