// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import {YieldSubsidizedDirectionalHook} from "../../src/YieldSubsidizedDirectionalHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IExternalVault} from "../../src/interfaces/IExternalVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract SubsidyDistributionTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    
    // Test constants
    address public testLP = address(0xABCD);
    uint256 constant INITIAL_TOKEN0 = 1000e18;
    uint256 constant INITIAL_TOKEN1 = 1000e18;
    uint256 constant LIQUIDITY_AMOUNT = 1000e18;
    int24 constant TICK_LOWER = -100;
    int24 constant TICK_UPPER = 100;

    // Contract instances
    YieldSubsidizedDirectionalHook public hook;
    MockPoolManager public mockPoolManager;
    PoolKey public testPoolKey;
    MockERC20 public mockToken0;
    MockERC20 public mockToken1;
    
    // Mock vault for testing
    MockVault public mockVault0;
    MockVault public mockVault1;

    function setUp() public override {
        super.setUp();
        
        // Deploy mock PoolManager
        mockPoolManager = new MockPoolManager();
        
        // Deploy hook
        hook = new YieldSubsidizedDirectionalHook(IPoolManager(address(mockPoolManager)));
        
        // Deploy mock tokens
        mockToken0 = new MockERC20("Token0", "TKN0", 18);
        mockToken1 = new MockERC20("Token1", "TKN1", 18);
        
        // Deploy mock vaults
        mockVault0 = new MockVault(address(mockToken0));
        mockVault1 = new MockVault(address(mockToken1));
        
        // Create a test PoolKey
        testPoolKey = createPoolKey(
            address(mockToken0),
            address(mockToken1),
            3000,
            60,
            address(hook)
        );
        
        // Register pool
        vm.prank(address(mockPoolManager));
        hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
    }

    /// @notice Test calculateAvailableYield returns zero when no vault shares exist
    function test_CalculateAvailableYield_NoShares() public {
        PoolId poolId = testPoolKey.toId();
        
        // Create a helper contract to call internal function
        SubsidyDistributionHelper helper = new SubsidyDistributionHelper(address(mockPoolManager));
        
        // Register pool in helper
        vm.prank(address(mockPoolManager));
        helper.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
        
        uint256 availableYield = helper.exposed_calculateAvailableYield(poolId, true);
        
        assertEq(availableYield, 0, "Should return 0 when no vault shares exist");
    }

    /// @notice Test calculateAvailableYield returns correct yield amount
    function test_CalculateAvailableYield_WithYield() public {
        PoolId poolId = testPoolKey.toId();
        
        // Create helper and setup
        SubsidyDistributionHelper helper = new SubsidyDistributionHelper(address(mockPoolManager));
        vm.prank(address(mockPoolManager));
        helper.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
        
        // Manually set subsidy pool data to simulate a capital sweep
        uint256 principal = 1000e18;
        uint256 shares = 1000e18;
        helper.setSubsidyPoolData(poolId, principal, 0, shares, 0);
        
        // Configure vault
        helper.setVault0(poolId, address(mockVault0));
        
        // Set vault to return more assets than principal (simulating yield)
        mockVault0.setConvertToAssetsReturn(1100e18); // 100e18 yield
        
        uint256 availableYield = helper.exposed_calculateAvailableYield(poolId, true);
        
        assertEq(availableYield, 100e18, "Should return correct yield amount");
    }

    /// @notice Test calculateAvailableYield returns zero when vault has loss
    function test_CalculateAvailableYield_WithLoss() public {
        PoolId poolId = testPoolKey.toId();
        
        SubsidyDistributionHelper helper = new SubsidyDistributionHelper(address(mockPoolManager));
        vm.prank(address(mockPoolManager));
        helper.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
        
        uint256 principal = 1000e18;
        uint256 shares = 1000e18;
        helper.setSubsidyPoolData(poolId, principal, 0, shares, 0);
        helper.setVault0(poolId, address(mockVault0));
        
        // Vault lost value
        mockVault0.setConvertToAssetsReturn(900e18);
        
        uint256 availableYield = helper.exposed_calculateAvailableYield(poolId, true);
        
        assertEq(availableYield, 0, "Should return 0 when vault has loss");
    }

    /// @notice Test withdrawFromVault succeeds and updates principal
    function test_WithdrawFromVault_Success() public {
        PoolId poolId = testPoolKey.toId();
        
        SubsidyDistributionHelper helper = new SubsidyDistributionHelper(address(mockPoolManager));
        vm.prank(address(mockPoolManager));
        helper.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
        
        // Setup subsidy pool with principal
        uint256 principal = 1000e18;
        helper.setSubsidyPoolData(poolId, principal, 0, 0, 0);
        helper.setVault0(poolId, address(mockVault0));
        
        // Set vault to succeed withdrawal
        mockVault0.setShouldRevert(false);
        
        // Mint tokens to vault for withdrawal
        mockToken0.mint(address(mockVault0), 100e18);
        
        // Withdraw 100e18
        helper.exposed_withdrawFromVault(testPoolKey, poolId, testLP, true, 100e18);
        
        // Check that principal was updated
        DataTypes.SubsidyPool memory pool = helper.getSubsidyPool(poolId);
        assertEq(pool.totalToken0Principal, principal - 100e18, "Principal should be reduced");
    }

    /// @notice Test withdrawFromVault mints claim token on failure
    function test_WithdrawFromVault_MintsClaimToken() public {
        PoolId poolId = testPoolKey.toId();
        
        SubsidyDistributionHelper helper = new SubsidyDistributionHelper(address(mockPoolManager));
        vm.prank(address(mockPoolManager));
        helper.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);
        
        helper.setVault0(poolId, address(mockVault0));
        
        // Set vault to fail withdrawal
        mockVault0.setShouldRevert(true);
        
        // Expect ClaimTokenMinted event
        vm.expectEmit(true, true, false, true);
        uint256 expectedTokenId = helper.exposed_generateClaimTokenId(poolId, testPoolKey.currency0);
        emit ClaimTokenMinted(testLP, expectedTokenId, 100e18, address(mockVault0));
        
        // Attempt withdrawal (should mint claim token)
        helper.exposed_withdrawFromVault(testPoolKey, poolId, testLP, true, 100e18);
        
        // Verify LP received claim token
        uint256 balance = helper.balanceOf(testLP, expectedTokenId);
        assertEq(balance, 100e18, "LP should receive claim token");
    }

    /// @notice Test beforeRemoveLiquidity with no IL returns selector
    function test_BeforeRemoveLiquidity_NoIL() public {
        // Pool is already registered in setUp
        
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: -1e18,
            salt: bytes32(0)
        });
        
        // Call beforeRemoveLiquidity (no LP position exists, so no IL)
        vm.prank(address(mockPoolManager));
        bytes4 result = hook.beforeRemoveLiquidity(address(this), testPoolKey, params, "");
        
        assertEq(result, IHooks.beforeRemoveLiquidity.selector, "Should return correct selector");
    }

    /// @notice Test beforeRemoveLiquidity validates pool is registered
    function test_RevertWhen_BeforeRemoveLiquidityOnUnregisteredPool() public {
        // Create a new pool key that hasn't been registered
        PoolKey memory unregisteredPoolKey = createPoolKey(
            address(0x9999),
            address(0x8888),
            3000,
            60,
            address(hook)
        );
        
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: -1e18,
            salt: bytes32(0)
        });
        
        vm.prank(address(mockPoolManager));
        vm.expectRevert();
        hook.beforeRemoveLiquidity(address(this), unregisteredPoolKey, params, "");
    }
}

// Event declarations
event ClaimTokenMinted(
    address indexed lp,
    uint256 indexed claimTokenId,
    uint256 amount,
    address vault
);

/// @notice Helper contract to expose internal functions for testing
contract SubsidyDistributionHelper is YieldSubsidizedDirectionalHook {
    constructor(address _poolManager) YieldSubsidizedDirectionalHook(IPoolManager(_poolManager)) {}
    
    function exposed_calculateAvailableYield(PoolId poolId, bool isToken0) 
        external 
        view 
        returns (uint256) 
    {
        return calculateAvailableYield(poolId, isToken0);
    }
    
    function exposed_withdrawFromVault(
        PoolKey memory key,
        PoolId poolId,
        address lp,
        bool isToken0,
        uint256 amount
    ) external {
        withdrawFromVault(key, poolId, lp, isToken0, amount);
    }
    
    function exposed_generateClaimTokenId(PoolId poolId, Currency currency) 
        external 
        pure 
        returns (uint256) 
    {
        return generateClaimTokenId(poolId, currency);
    }
    
    function setSubsidyPoolData(
        PoolId poolId,
        uint256 principal0,
        uint256 principal1,
        uint256 shares0,
        uint256 shares1
    ) external {
        DataTypes.SubsidyPool storage pool = subsidyPools[poolId];
        pool.totalToken0Principal = principal0;
        pool.totalToken1Principal = principal1;
        pool.vaultShares0 = shares0;
        pool.vaultShares1 = shares1;
    }
    
    function setVault0(PoolId poolId, address vault) external {
        poolConfigs[poolId].vault0 = vault;
    }
    
    function getSubsidyPool(PoolId poolId) external view returns (DataTypes.SubsidyPool memory) {
        return subsidyPools[poolId];
    }
}

/// @notice Mock vault for testing
contract MockVault {
    address public immutable asset;
    bool public shouldRevert;
    uint256 public convertToAssetsReturn;
    
    constructor(address _asset) {
        asset = _asset;
        convertToAssetsReturn = 0;
    }
    
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
    
    function setConvertToAssetsReturn(uint256 _return) external {
        convertToAssetsReturn = _return;
    }
    
    function withdraw(uint256 assets, address receiver, address) external returns (uint256) {
        if (shouldRevert) {
            revert("Vault withdrawal failed");
        }
        
        // Transfer tokens to receiver
        IERC20(asset).transfer(receiver, assets);
        return assets;
    }
    
    function convertToAssets(uint256) external view returns (uint256) {
        return convertToAssetsReturn;
    }
}
