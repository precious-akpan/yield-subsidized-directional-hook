// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockOracle
/// @notice Mock implementation of IOracle for testing
contract MockOracle {
    struct PriceData {
        uint256 price;
        uint256 timestamp;
    }

    mapping(address => mapping(address => PriceData)) private prices;
    bool public shouldRevert;
    uint256 public gasConsumption;

    /// @notice Set price for a token pair
    function setPrice(address token0, address token1, uint256 price) external {
        prices[token0][token1] = PriceData({price: price, timestamp: block.timestamp});
    }

    /// @notice Set price with custom timestamp
    function setPrice(address token0, address token1, uint256 price, uint256 timestamp_) external {
        prices[token0][token1] = PriceData({price: price, timestamp: timestamp_});
    }

    /// @notice Set price with custom timestamp (alternative method name for compatibility)
    function setPriceWithTimestamp(address token0, address token1, uint256 price, uint256 timestamp_) external {
        prices[token0][token1] = PriceData({price: price, timestamp: timestamp_});
    }

    /// @notice Configure oracle to revert
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /// @notice Simulate high gas consumption
    function setGasConsumption(uint256 _gasConsumption) external {
        gasConsumption = _gasConsumption;
    }

    /// @notice Get price for token pair (IOracle interface)
    function getPrice(address token0, address token1) external view returns (uint256 price, uint256 timestamp) {
        require(!shouldRevert, "MockOracle: Configured to revert");

        // Simulate gas consumption
        if (gasConsumption > 0) {
            uint256 gasStart = gasleft();
            while (gasStart - gasleft() < gasConsumption) {
                // Burn gas
            }
        }

        PriceData memory data = prices[token0][token1];
        require(data.price > 0, "MockOracle: Price not set");

        return (data.price, data.timestamp);
    }

    /// @notice Helper to set stale price (old timestamp)
    function setStalePrice(address token0, address token1, uint256 price, uint256 ageSeconds) external {
        // Handle edge case where block.timestamp might be less than ageSeconds (in tests)
        uint256 timestamp = block.timestamp > ageSeconds ? block.timestamp - ageSeconds : 0;
        prices[token0][token1] = PriceData({price: price, timestamp: timestamp});
    }
}
