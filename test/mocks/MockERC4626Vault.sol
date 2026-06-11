// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title MockERC4626Vault
/// @notice Mock ERC-4626 vault for testing yield generation and withdrawals
contract MockERC4626Vault {
    IERC20 public immutable asset;

    uint256 public totalAssets_;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    bool public shouldRevertOnDeposit;
    bool public shouldRevertOnWithdraw;
    bool public isIlliquid;
    uint256 public yieldRate; // Basis points per second (for simulation)
    uint256 public lastYieldUpdate;

    error InsufficientLiquidity();
    error DepositFailed();
    error WithdrawFailed();

    constructor(address _asset) {
        asset = IERC20(_asset);
        lastYieldUpdate = block.timestamp;
    }

    /// @notice Returns the underlying asset address
    function assetAddress() external view returns (address) {
        return address(asset);
    }

    /// @notice Deposit assets and receive shares
    function deposit(uint256 assets, address receiver) external returns (uint256 sharesAmount) {
        require(!shouldRevertOnDeposit, "Deposit reverted");

        // Update yield before deposit
        _updateYield();

        // Transfer assets from sender
        require(asset.transferFrom(msg.sender, address(this), assets), "Transfer failed");

        // Calculate shares to mint (1:1 for simplicity, can be modified for yield)
        sharesAmount = totalShares == 0 ? assets : (assets * totalShares) / totalAssets_;

        shares[receiver] += sharesAmount;
        totalShares += sharesAmount;
        totalAssets_ += assets;

        return sharesAmount;
    }

    /// @notice Withdraw assets by burning shares
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 sharesAmount) {
        require(!shouldRevertOnWithdraw, "Withdraw reverted");
        require(!isIlliquid, "Vault is illiquid");

        // Update yield before withdrawal
        _updateYield();

        // Calculate shares to burn
        sharesAmount = (assets * totalShares) / totalAssets_;
        require(shares[owner] >= sharesAmount, "Insufficient shares");

        // Check liquidity
        require(asset.balanceOf(address(this)) >= assets, "Insufficient liquidity");

        // Burn shares and transfer assets
        shares[owner] -= sharesAmount;
        totalShares -= sharesAmount;
        totalAssets_ -= assets;

        require(asset.transfer(receiver, assets), "Transfer failed");

        return sharesAmount;
    }

    /// @notice Convert shares to assets
    function convertToAssets(uint256 sharesAmount) external view returns (uint256) {
        if (totalShares == 0) return 0;

        // Simulate yield without updating state
        uint256 simulatedAssets = totalAssets_;
        if (yieldRate > 0) {
            uint256 timeElapsed = block.timestamp - lastYieldUpdate;
            uint256 yield = (simulatedAssets * yieldRate * timeElapsed) / (10000 * 1);
            simulatedAssets += yield;
        }

        return (sharesAmount * simulatedAssets) / totalShares;
    }

    /// @notice Get total assets under management
    function totalAssets() external view returns (uint256) {
        // Simulate yield without updating state
        uint256 simulatedAssets = totalAssets_;
        if (yieldRate > 0) {
            uint256 timeElapsed = block.timestamp - lastYieldUpdate;
            uint256 yield = (simulatedAssets * yieldRate * timeElapsed) / (10000 * 1);
            simulatedAssets += yield;
        }
        return simulatedAssets;
    }

    /// @notice Configure vault to revert on deposit
    function setShouldRevertOnDeposit(bool _shouldRevert) external {
        shouldRevertOnDeposit = _shouldRevert;
    }

    /// @notice Configure vault to revert on withdraw
    function setShouldRevertOnWithdraw(bool _shouldRevert) external {
        shouldRevertOnWithdraw = _shouldRevert;
    }

    /// @notice Simulate vault illiquidity
    function setIsIlliquid(bool _isIlliquid) external {
        isIlliquid = _isIlliquid;
    }

    /// @notice Set yield rate (basis points per second)
    function setYieldRate(uint256 _yieldRate) external {
        _updateYield();
        yieldRate = _yieldRate;
    }

    /// @notice Simulate yield generation
    function simulateYield(uint256 additionalAssets) external {
        totalAssets_ += additionalAssets;
    }

    /// @notice Update yield based on rate and time elapsed
    function _updateYield() internal {
        if (yieldRate > 0 && totalAssets_ > 0) {
            uint256 timeElapsed = block.timestamp - lastYieldUpdate;
            uint256 yield = (totalAssets_ * yieldRate * timeElapsed) / (10000 * 1);
            totalAssets_ += yield;
        }
        lastYieldUpdate = block.timestamp;
    }
}
