// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @title IOracle Interface Test
/// @notice Tests to verify IOracle interface implementation and compatibility
contract IOracleTest is Test {
    MockOracle public oracle;
    address public token0;
    address public token1;

    function setUp() public {
        oracle = new MockOracle();
        token0 = address(0x1);
        token1 = address(0x2);
    }

    /// @notice Test that MockOracle correctly implements IOracle interface
    function test_MockOracleImplementsIOracle() public {
        // Set a price
        oracle.setPrice(token0, token1, 1e18);

        // Call through IOracle interface
        IOracle iOracle = IOracle(address(oracle));
        (uint256 price, uint256 timestamp) = iOracle.getPrice(token0, token1);

        // Verify results
        assertEq(price, 1e18, "Price should be 1e18");
        assertEq(timestamp, block.timestamp, "Timestamp should be current block timestamp");
    }

    /// @notice Test getPrice returns correct values
    function test_GetPriceReturnsCorrectValues() public {
        uint256 expectedPrice = 2.5e18; // 2.5 token1 per token0
        oracle.setPrice(token0, token1, expectedPrice);

        (uint256 price, uint256 timestamp) = oracle.getPrice(token0, token1);

        assertEq(price, expectedPrice, "Price should match set value");
        assertGt(timestamp, 0, "Timestamp should be greater than 0");
    }

    /// @notice Test getPrice with custom timestamp
    function test_GetPriceWithCustomTimestamp() public {
        uint256 expectedPrice = 1.5e18;
        uint256 customTimestamp = block.timestamp - 100;
        
        oracle.setPriceWithTimestamp(token0, token1, expectedPrice, customTimestamp);

        (uint256 price, uint256 timestamp) = oracle.getPrice(token0, token1);

        assertEq(price, expectedPrice, "Price should match set value");
        assertEq(timestamp, customTimestamp, "Timestamp should match custom timestamp");
    }

    /// @notice Test that getPrice reverts when price not set
    function test_GetPriceRevertsWhenNotSet() public {
        vm.expectRevert("MockOracle: Price not set");
        oracle.getPrice(token0, token1);
    }

    /// @notice Test that getPrice reverts when configured to revert
    function test_GetPriceRevertsWhenConfigured() public {
        oracle.setPrice(token0, token1, 1e18);
        oracle.setShouldRevert(true);

        vm.expectRevert("MockOracle: Configured to revert");
        oracle.getPrice(token0, token1);
    }

    /// @notice Test getPrice returns different values for different token pairs
    function test_GetPriceDifferentTokenPairs() public {
        address token2 = address(0x3);
        
        oracle.setPrice(token0, token1, 1e18);
        oracle.setPrice(token0, token2, 2e18);

        (uint256 price01,) = oracle.getPrice(token0, token1);
        (uint256 price02,) = oracle.getPrice(token0, token2);

        assertEq(price01, 1e18, "Price for token0/token1 should be 1e18");
        assertEq(price02, 2e18, "Price for token0/token2 should be 2e18");
    }

    /// @notice Test stale price detection helper
    function test_StalePriceHelper() public {
        uint256 ageSeconds = 300; // 5 minutes old
        oracle.setStalePrice(token0, token1, 1e18, ageSeconds);

        (uint256 price, uint256 timestamp) = oracle.getPrice(token0, token1);

        assertEq(price, 1e18, "Price should be 1e18");
        assertLe(timestamp, block.timestamp - ageSeconds, "Timestamp should be at least ageSeconds old");
    }

    /// @notice Fuzz test: getPrice handles various price values correctly
    function testFuzz_GetPriceHandlesVariousPrices(uint256 randomPrice) public {
        vm.assume(randomPrice > 0 && randomPrice < type(uint128).max);
        
        oracle.setPrice(token0, token1, randomPrice);
        (uint256 price,) = oracle.getPrice(token0, token1);

        assertEq(price, randomPrice, "Price should match random input");
    }

    /// @notice Test that interface can be used with different implementations
    function test_InterfaceCompatibility() public view {
        // This test verifies that IOracle is properly defined as an interface
        // and can be type-cast to different implementations
        IOracle iOracle = IOracle(address(oracle));
        
        // Verify the interface has the expected function selector
        bytes4 expectedSelector = bytes4(keccak256("getPrice(address,address)"));
        // This would be the selector for getPrice
        assertEq(
            expectedSelector, 
            IOracle.getPrice.selector, 
            "Function selector should match"
        );
    }
}
