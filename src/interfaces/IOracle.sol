// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice External price oracle interface for directional fee calculation
/// @dev Implementations must return manipulation-resistant prices with staleness checks
/// @dev Prices should be returned in a consistent fixed-point format (e.g., 18 decimals)
/// @dev Timestamp must be block.timestamp or recent to enable staleness detection
/// @dev Should implement TWAP (Time-Weighted Average Price) or other manipulation-resistant pricing mechanisms
/// @dev Revert behavior should be handled gracefully by the calling hook contract
interface IOracle {
    /// @notice Returns the current price for a token pair
    /// @dev Price must be expressed in a manipulation-resistant format (e.g., TWAP)
    /// @dev Timestamp should reflect when the price observation was made
    /// @dev Implementations should revert if price data is unavailable or invalid
    /// @param token0 The base token address
    /// @param token1 The quote token address
    /// @return price The price expressed as token1 per token0 in fixed-point format
    /// @return timestamp The timestamp of the price observation (should be block.timestamp or recent)
    function getPrice(address token0, address token1) external view returns (uint256 price, uint256 timestamp);
}
