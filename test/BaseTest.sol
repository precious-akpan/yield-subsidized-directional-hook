// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @title BaseTest
/// @notice Base test contract with common setup and utilities for all tests
abstract contract BaseTest is Test {
    using PoolIdLibrary for PoolKey;

    // Common test addresses
    address internal constant ALICE = address(0x1);
    address internal constant BOB = address(0x2);
    address internal constant KEEPER = address(0x3);
    address internal constant ADMIN = address(0x4);

    // Common test values
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant SQRT_PRICE_1_2 = 112045541949572279837463876454;
    uint160 internal constant SQRT_PRICE_2_1 = 56022770974786139918731938227;

    // Test labels for better trace output
    function setUp() public virtual {
        vm.label(ALICE, "Alice");
        vm.label(BOB, "Bob");
        vm.label(KEEPER, "Keeper");
        vm.label(ADMIN, "Admin");
    }

    /// @notice Helper to create a test PoolKey
    function createPoolKey(
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
    }

    /// @notice Helper to deal tokens to an address
    function dealTokens(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
    }

    /// @notice Helper to approve tokens
    function approveTokens(address token, address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        (bool success,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(success, "Approval failed");
    }

    /// @notice Warp time forward by specified seconds
    function warpTime(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    /// @notice Helper to calculate price deviation in basis points
    function calculateDeviationBps(uint256 price1, uint256 price2) internal pure returns (uint256) {
        uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
        return (diff * 10000) / (price1 > price2 ? price1 : price2);
    }

    /// @notice Helper to convert sqrtPriceX96 to human-readable price
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        return (sqrtPrice * sqrtPrice * 1e18) >> 192;
    }

    /// @notice Expect specific custom error
    function expectCustomError(bytes4 selector) internal {
        vm.expectRevert(abi.encodeWithSelector(selector));
    }

    /// @notice Assert event emission with indexed parameters
    function expectEventWithIndexed(address emitter, bytes32 eventSignature) internal {
        vm.expectEmit(true, true, true, true, emitter);
    }
}
