// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IExternalVault
/// @notice ERC-4626 compatible yield vault interface for external yield generation
/// @dev Vaults must support standard deposit/withdraw operations and be compatible with the hook's capital sweep mechanism.
/// The hook validates that vault.asset() matches the expected token address on configuration.
/// Deposit operations use address(this) as receiver to custody vault shares.
/// Withdraw failures are caught and handled via claim token minting to ensure non-blocking LP operations.
/// Share-to-asset conversion is used for real-time yield calculation.
interface IExternalVault {
    /// @notice Returns the address of the underlying token accepted by the vault
    /// @dev Must return a valid ERC-20 token address that matches the pool token for proper integration
    /// @return The address of the underlying asset token
    function asset() external view returns (address);

    /// @notice Deposits assets into the vault and mints vault shares to receiver
    /// @dev Caller must approve the vault to spend at least `assets` amount of underlying tokens.
    /// The vault should transfer `assets` from caller and mint corresponding shares to `receiver`.
    /// @param assets The amount of underlying tokens to deposit
    /// @param receiver The address to receive vault shares
    /// @return shares The amount of vault shares minted to the receiver
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Withdraws assets from the vault by burning vault shares from owner
    /// @dev Burns `shares` from `owner` and transfers corresponding `assets` to `receiver`.
    /// If the vault has insufficient liquidity, this call may revert, triggering claim token minting in the hook.
    /// @param assets The amount of underlying tokens to withdraw
    /// @param receiver The address to receive underlying tokens
    /// @param owner The address that owns the vault shares to burn
    /// @return shares The amount of vault shares burned from the owner
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Converts vault shares to the equivalent amount of underlying asset
    /// @dev Used by the hook to calculate real-time yield: yield = convertToAssets(vaultShares) - principal.
    /// Must return the current exchange rate accounting for accrued yield.
    /// @param shares The amount of vault shares to convert
    /// @return assets The corresponding amount of underlying tokens
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the total assets managed by the vault
    /// @dev Includes both deposited principal and accrued yield across all depositors.
    /// Used for accounting and yield tracking purposes.
    /// @return The total amount of underlying assets held by the vault
    function totalAssets() external view returns (uint256);
}
