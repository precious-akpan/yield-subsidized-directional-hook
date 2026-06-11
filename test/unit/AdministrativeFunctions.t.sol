// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {YieldSubsidizedDirectionalHook} from "../../src/YieldSubsidizedDirectionalHook.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {BaseTest} from "../BaseTest.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @title AdministrativeFunctions.t.sol
/// @notice Unit tests for administrative functions: configurePool, pausePool, unpausePool
/// @custom:requirements Validates: 19.1-19.5, 20.1-20.5, 21.1-21.5, 22.1-22.5, 33.1-33.5
contract AdministrativeFunctionsTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    // ========== TEST STATE ==========

    YieldSubsidizedDirectionalHook hook;
    MockPoolManager mockPoolManager;
    PoolKey testPoolKey;

    // Tokens
    MockERC20 token0;
    MockERC20 token1;

    // Test oracle and vaults
    MockOracle testOracle;
    MockERC4626Vault testVault0;
    MockERC4626Vault testVault1;

    // Test addresses
    address owner;
    address attacker;

    /// @notice Setup function - initializes test contracts and creates a test pool
    function setUp() public override {
        super.setUp();

        // Initialize test addresses
        owner = address(this);
        attacker = address(0x999);

        // Deploy mock contracts
        mockPoolManager = new MockPoolManager();

        // Deploy tokens
        token0 = new MockERC20("Token 0", "TOKEN0", 18);
        token1 = new MockERC20("Token 1", "TOKEN1", 18);

        // Deploy hook
        hook = new YieldSubsidizedDirectionalHook(IPoolManager(address(mockPoolManager)));

        // Deploy test oracle and vaults
        testOracle = new MockOracle();
        testVault0 = new MockERC4626Vault(address(token0));
        testVault1 = new MockERC4626Vault(address(token1));

        // Configure oracle with a default price
        testOracle.setPrice(address(0), address(0), 1e18, block.timestamp);

        // Create a test PoolKey
        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Register the pool
        vm.prank(address(mockPoolManager));
        hook.beforeInitialize(address(mockPoolManager), testPoolKey, uint160(2 ** 96));

        // Setup labels for better trace output
        vm.label(owner, "Owner");
        vm.label(attacker, "Attacker");
        vm.label(address(hook), "Hook");
        vm.label(address(testOracle), "TestOracle");
        vm.label(address(testVault0), "TestVault0");
        vm.label(address(testVault1), "TestVault1");
    }

    // ========== CONFIGURE POOL TESTS ==========

    /// @notice Test successful pool configuration with valid parameters (Req 19.1-19.5, 20.1-20.5, 21.1-21.5)
    /// @custom:requirements Validates: 19.1-19.5, 20.1-20.5, 21.1-21.5
    function test_ConfigurePool_Success_WithValidParameters() public {
        PoolId poolId = testPoolKey.toId();

        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(testOracle),
            vault0: address(testVault0),
            vault1: address(testVault1),
            baseFeeBps: 30, // 0.3%
            maxFeeMultiplier: 300, // 3x
            deviationThresholdBps: 500, // 5%
            isPaused: false
        });

        // Expect PoolConfigured event
        vm.expectEmit(true, true, true, true, address(hook));
        emit PoolConfigured(poolId, address(testOracle), address(testVault0), address(testVault1), 30, 300, 500);

        // Configure pool as owner
        vm.prank(owner);
        hook.configurePool(poolId, config);

        // Verify configuration is stored
        (
            address oracle,
            address vault0,
            address vault1,
            uint24 baseFeeBps,
            uint24 maxFeeMultiplier,
            uint24 deviationThresholdBps,
            bool isPaused
        ) = hook.poolConfigs(poolId);
        assertEq(oracle, address(testOracle), "Oracle not stored");
        assertEq(vault0, address(testVault0), "Vault0 not stored");
        assertEq(vault1, address(testVault1), "Vault1 not stored");
        assertEq(baseFeeBps, 30, "Base fee not stored");
        assertEq(maxFeeMultiplier, 300, "Max multiplier not stored");
        assertEq(deviationThresholdBps, 500, "Deviation threshold not stored");
        assertEq(isPaused, false, "Pause flag not stored");
    }

    /// @notice Test configuration with zero addresses (disabling oracle/vaults)
    /// @custom:requirements Validates: 20.1-20.5, 21.1-21.5
    function test_ConfigurePool_Success_WithZeroAddresses() public {
        PoolId poolId = testPoolKey.toId();

        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(0),
            vault0: address(0),
            vault1: address(0),
            baseFeeBps: 50,
            maxFeeMultiplier: 200,
            deviationThresholdBps: 1000,
            isPaused: false
        });

        // Configure pool with zero addresses should succeed
        vm.prank(owner);
        hook.configurePool(poolId, config);

        (address oracle, address vault0, address vault1,,,,) = hook.poolConfigs(poolId);
        assertEq(oracle, address(0), "Oracle should be zero");
        assertEq(vault0, address(0), "Vault0 should be zero");
        assertEq(vault1, address(0), "Vault1 should be zero");
    }

    /// @notice Test configuration fails when pool not registered
    /// @custom:requirements Validates: 19.1-19.5
    function test_ConfigurePool_Fails_PoolNotRegistered() public {
        // Create a pool ID that doesn't exist
        PoolKey memory unregisteredPool = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(0x5678)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        PoolId unregisteredPoolId = unregisteredPool.toId();

        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(testOracle),
            vault0: address(testVault0),
            vault1: address(testVault1),
            baseFeeBps: 30,
            maxFeeMultiplier: 300,
            deviationThresholdBps: 500,
            isPaused: false
        });

        // Should revert with PoolNotRegistered
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolNotRegistered.selector, PoolId.unwrap(unregisteredPoolId)));
        hook.configurePool(unregisteredPoolId, config);
    }

    /// @notice Test configuration fails when called by non-owner
    /// @custom:requirements Validates: 22.1-22.5
    function test_ConfigurePool_Fails_NonOwnerCaller() public {
        PoolId poolId = testPoolKey.toId();

        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(testOracle),
            vault0: address(testVault0),
            vault1: address(testVault1),
            baseFeeBps: 30,
            maxFeeMultiplier: 300,
            deviationThresholdBps: 500,
            isPaused: false
        });

        // Should revert with Unauthorized when called by non-owner
        vm.prank(address(0x999));
        vm.expectRevert(Errors.Unauthorized.selector);
        hook.configurePool(poolId, config);
    }

    /// @notice Test configuration fails when maxFeeMultiplier < baseFeeBps (Req 19.4)
    /// @custom:requirements Validates: 19.4
    function test_ConfigurePool_Fails_InvalidFeeParameters() public {
        PoolId poolId = testPoolKey.toId();

        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(testOracle),
            vault0: address(testVault0),
            vault1: address(testVault1),
            baseFeeBps: 300, // 3x
            maxFeeMultiplier: 30, // 0.3% (less than base!)
            deviationThresholdBps: 500,
            isPaused: false
        });

        // Should revert with InvalidConfiguration
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidConfiguration.selector, "maxFeeMultiplier must be >= baseFeeBps")
        );
        hook.configurePool(poolId, config);
    }

    /// @notice Test configuration fails when baseFeeBps exceeds 100%
    /// @custom:requirements Validates: 19.4
    function test_ConfigurePool_Fails_BaseFeeExceedsBound() public {
        PoolId poolId = testPoolKey.toId();

        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(testOracle),
            vault0: address(testVault0),
            vault1: address(testVault1),
            baseFeeBps: 10001, // > 100%
            maxFeeMultiplier: 10001,
            deviationThresholdBps: 500,
            isPaused: false
        });

        // Should revert with InvalidConfiguration
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidConfiguration.selector, "baseFeeBps exceeds 100%"));
        hook.configurePool(poolId, config);
    }

    /// @notice Test configuration fails when maxFeeMultiplier exceeds 1000%
    /// @custom:requirements Validates: 19.4
    function test_ConfigurePool_Fails_MaxMultiplierExceedsBound() public {
        PoolId poolId = testPoolKey.toId();

        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(testOracle),
            vault0: address(testVault0),
            vault1: address(testVault1),
            baseFeeBps: 30,
            maxFeeMultiplier: 100001, // > 1000%
            deviationThresholdBps: 500,
            isPaused: false
        });

        // Should revert with InvalidConfiguration
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidConfiguration.selector, "maxFeeMultiplier exceeds 1000%"));
        hook.configurePool(poolId, config);
    }

    /// @notice Test configuration fails when deviationThresholdBps is invalid
    /// @custom:requirements Validates: 19.4
    function test_ConfigurePool_Fails_InvalidDeviationThreshold() public {
        PoolId poolId = testPoolKey.toId();

        // Test with zero deviation threshold
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(testOracle),
            vault0: address(testVault0),
            vault1: address(testVault1),
            baseFeeBps: 30,
            maxFeeMultiplier: 300,
            deviationThresholdBps: 0, // Invalid: zero
            isPaused: false
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidConfiguration.selector, "deviationThresholdBps must be between 1 and 10000"
            )
        );
        hook.configurePool(poolId, config);

        // Test with threshold > 100%
        config.deviationThresholdBps = 10001;

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidConfiguration.selector, "deviationThresholdBps must be between 1 and 10000"
            )
        );
        hook.configurePool(poolId, config);
    }

    /// @notice Test configuration fails with invalid oracle
    /// @custom:requirements Validates: 20.1-20.5
    function test_ConfigurePool_Fails_InvalidOracle() public {
        PoolId poolId = testPoolKey.toId();

        // Use a non-contract address as oracle
        address invalidOracle = address(0x1111);

        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: invalidOracle,
            vault0: address(testVault0),
            vault1: address(testVault1),
            baseFeeBps: 30,
            maxFeeMultiplier: 300,
            deviationThresholdBps: 500,
            isPaused: false
        });

        vm.prank(owner);
        // The try-catch will fail when calling a non-contract, which reverts with empty reason
        vm.expectRevert();
        hook.configurePool(poolId, config);
    }

    /// @notice Test configuration fails with invalid vault0
    /// @custom:requirements Validates: 21.1-21.5
    function test_ConfigurePool_Fails_InvalidVault0() public {
        PoolId poolId = testPoolKey.toId();

        // Use a non-contract address as vault
        address invalidVault = address(0x2222);

        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(testOracle),
            vault0: invalidVault,
            vault1: address(testVault1),
            baseFeeBps: 30,
            maxFeeMultiplier: 300,
            deviationThresholdBps: 500,
            isPaused: false
        });

        vm.prank(owner);
        // The try-catch will fail when calling a non-contract, which reverts with empty reason
        vm.expectRevert();
        hook.configurePool(poolId, config);
    }

    /// @notice Test configuration fails with invalid vault1
    /// @custom:requirements Validates: 21.1-21.5
    function test_ConfigurePool_Fails_InvalidVault1() public {
        PoolId poolId = testPoolKey.toId();

        // Use a non-contract address as vault
        address invalidVault = address(0x3333);

        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(testOracle),
            vault0: address(testVault0),
            vault1: invalidVault,
            baseFeeBps: 30,
            maxFeeMultiplier: 300,
            deviationThresholdBps: 500,
            isPaused: false
        });

        vm.prank(owner);
        // The try-catch will fail when calling a non-contract, which reverts with empty reason
        vm.expectRevert();
        hook.configurePool(poolId, config);
    }

    // ========== PAUSE POOL TESTS ==========

    /// @notice Test successful pool pause
    /// @custom:requirements Validates: 22.1-22.5, 33.1-33.5
    function test_PausePool_Success() public {
        PoolId poolId = testPoolKey.toId();

        // Pool should not be paused initially
        (,,,,,, bool isPaused) = hook.poolConfigs(poolId);
        assertFalse(isPaused, "Pool should not be paused initially");

        // Expect PoolPaused event
        vm.expectEmit(true, true, true, true, address(hook));
        emit PoolPaused(poolId, block.timestamp);

        // Pause pool as owner
        vm.prank(owner);
        hook.pausePool(poolId);

        // Verify pool is paused
        (,,,,,, bool isPausedAfter) = hook.poolConfigs(poolId);
        assertTrue(isPausedAfter, "Pool should be paused");
    }

    /// @notice Test pause fails when pool not registered
    /// @custom:requirements Validates: 22.1-22.5
    function test_PausePool_Fails_PoolNotRegistered() public {
        PoolKey memory unregisteredPool = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(0x5678)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        PoolId unregisteredPoolId = unregisteredPool.toId();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolNotRegistered.selector, PoolId.unwrap(unregisteredPoolId)));
        hook.pausePool(unregisteredPoolId);
    }

    /// @notice Test pause fails when called by non-owner
    /// @custom:requirements Validates: 22.1-22.5
    function test_PausePool_Fails_NonOwnerCaller() public {
        PoolId poolId = testPoolKey.toId();

        vm.prank(address(0x999));
        vm.expectRevert(Errors.Unauthorized.selector);
        hook.pausePool(poolId);
    }

    // ========== UNPAUSE POOL TESTS ==========

    /// @notice Test successful pool unpause
    /// @custom:requirements Validates: 33.1-33.5
    function test_UnpausePool_Success() public {
        PoolId poolId = testPoolKey.toId();

        // First pause the pool
        vm.prank(owner);
        hook.pausePool(poolId);
        (,,,,,, bool isPausedBefore) = hook.poolConfigs(poolId);
        assertTrue(isPausedBefore, "Pool should be paused");

        // Expect PoolUnpaused event
        vm.expectEmit(true, true, true, true, address(hook));
        emit PoolUnpaused(poolId, block.timestamp);

        // Unpause pool as owner
        vm.prank(owner);
        hook.unpausePool(poolId);

        // Verify pool is unpaused
        (,,,,,, bool isPausedAfter) = hook.poolConfigs(poolId);
        assertFalse(isPausedAfter, "Pool should be unpaused");
    }

    /// @notice Test unpause fails when pool not registered
    /// @custom:requirements Validates: 33.1-33.5
    function test_UnpausePool_Fails_PoolNotRegistered() public {
        PoolKey memory unregisteredPool = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(0x5678)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        PoolId unregisteredPoolId = unregisteredPool.toId();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolNotRegistered.selector, PoolId.unwrap(unregisteredPoolId)));
        hook.unpausePool(unregisteredPoolId);
    }

    /// @notice Test unpause fails when called by non-owner
    /// @custom:requirements Validates: 33.1-33.5
    function test_UnpausePool_Fails_NonOwnerCaller() public {
        PoolId poolId = testPoolKey.toId();

        // Pause the pool first
        vm.prank(owner);
        hook.pausePool(poolId);

        // Try to unpause as non-owner
        vm.prank(address(0x999));
        vm.expectRevert(Errors.Unauthorized.selector);
        hook.unpausePool(poolId);
    }

    // ========== PAUSE/UNPAUSE INTEGRATION TESTS ==========

    /// @notice Test multiple pause/unpause cycles
    /// @custom:requirements Validates: 33.1-33.5
    function test_PauseUnpause_MultipleCycles() public {
        PoolId poolId = testPoolKey.toId();

        // First cycle
        vm.prank(owner);
        hook.pausePool(poolId);
        (,,,,,, bool isPaused1) = hook.poolConfigs(poolId);
        assertTrue(isPaused1, "Pool should be paused");

        vm.prank(owner);
        hook.unpausePool(poolId);
        (,,,,,, bool isUnpaused1) = hook.poolConfigs(poolId);
        assertFalse(isUnpaused1, "Pool should be unpaused");

        // Second cycle
        vm.prank(owner);
        hook.pausePool(poolId);
        (,,,,,, bool isPaused2) = hook.poolConfigs(poolId);
        assertTrue(isPaused2, "Pool should be paused again");

        vm.prank(owner);
        hook.unpausePool(poolId);
        (,,,,,, bool isUnpaused2) = hook.poolConfigs(poolId);
        assertFalse(isUnpaused2, "Pool should be unpaused again");
    }

    // ========== EVENT DEFINITIONS ==========

    event PoolConfigured(
        PoolId indexed poolId,
        address oracle,
        address vault0,
        address vault1,
        uint24 baseFeeBps,
        uint24 maxFeeMultiplier,
        uint24 deviationThresholdBps
    );

    event PoolPaused(PoolId indexed poolId, uint256 timestamp);

    event PoolUnpaused(PoolId indexed poolId, uint256 timestamp);
}
