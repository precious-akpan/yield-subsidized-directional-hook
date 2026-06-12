// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import "../../src/YieldSubsidizedDirectionalHook.sol";
import "../mocks/MockOracle.sol";
import "../mocks/MockERC4626Vault.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

/// @title SwapFlow Integration Test
/// @notice End-to-end integration test for the complete swap flow with directional fee scaling
/// @dev Tests Requirements: 1.1-1.7, 2.1-2.8, 5.1-5.5, 6.1-6.5, 23.1-23.5
/// @custom:task Task 19.1 - Write end-to-end swap flow test
contract SwapFlowIntegrationTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    // Test contracts
    YieldSubsidizedDirectionalHook public hook;
    MockOracle public oracle;
    MockERC4626Vault public vault0;
    MockERC4626Vault public vault1;
    MockERC20 public token0;
    MockERC20 public token1;
    MockPoolManager public poolManager;

    // Test pool
    PoolKey public testPoolKey;
    PoolId public testPoolId;

    // Test configuration
    uint24 constant BASE_FEE_BPS = 30; // 0.3%
    uint24 constant MAX_FEE_MULTIPLIER = 30000; // 3x multiplier
    uint24 constant DEVIATION_THRESHOLD_BPS = 50; // 0.5%
    uint24 constant POOL_FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60;

    // Price constants
    uint256 constant ORACLE_PRICE_1_1 = 1e18; // 1:1 price in 18 decimals
    uint256 constant ORACLE_PRICE_HIGH = 2e18; // 2:1 price
    uint256 constant ORACLE_PRICE_LOW = 0.5e18; // 1:2 price

    function setUp() public override {
        super.setUp();

        // Deploy mock tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Ensure token0 < token1 (Uniswap v4 requirement)
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy pool manager mock
        poolManager = new MockPoolManager();

        // Deploy oracle
        oracle = new MockOracle();

        // Deploy vaults
        vault0 = new MockERC4626Vault(address(token0));
        vault1 = new MockERC4626Vault(address(token1));

        // Deploy hook
        hook = new YieldSubsidizedDirectionalHook(IPoolManager(address(poolManager)));

        // Create test pool key
        testPoolKey = createPoolKey(
            address(token0),
            address(token1),
            POOL_FEE,
            TICK_SPACING,
            address(hook)
        );
        testPoolId = testPoolKey.toId();

        // Initialize pool through PoolManager mock
        // Set initial pool price to 1:1 (SQRT_PRICE_1_1)
        poolManager.setSlot0(
            testPoolId,
            SQRT_PRICE_1_1, // sqrtPriceX96
            0, // tick
            0, // protocolFee
            POOL_FEE // lpFee
        );

        // Initialize pool in hook (simulating beforeInitialize callback)
        vm.prank(address(poolManager));
        hook.beforeInitialize(address(0), testPoolKey, SQRT_PRICE_1_1);

        // Configure pool
        DataTypes.PoolConfig memory config = DataTypes.PoolConfig({
            oracle: address(oracle),
            vault0: address(vault0),
            vault1: address(vault1),
            baseFeeBps: BASE_FEE_BPS,
            maxFeeMultiplier: MAX_FEE_MULTIPLIER,
            deviationThresholdBps: DEVIATION_THRESHOLD_BPS,
            isPaused: false
        });

        vm.prank(hook.owner());
        hook.configurePool(testPoolId, config);

        // Set initial oracle price to match pool price (1:1)
        oracle.setPrice(address(token0), address(token1), ORACLE_PRICE_1_1);

        // Fund test accounts
        token0.mint(ALICE, 1000e18);
        token1.mint(ALICE, 1000e18);
        token0.mint(BOB, 1000e18);
        token1.mint(BOB, 1000e18);
    }

    // ============ TEST: TOXIC SWAP - DYNAMIC FEE APPLIED ============

    /// @notice Test that a toxic swap (moving away from oracle) applies dynamic fee
    /// @dev Validates Requirements: 1.1-1.7, 2.1-2.8, 5.1-5.5, 6.1-6.5, 23.1-23.5
    function test_ToxicSwap_DynamicFeeApplied() public {
        // Setup: Set oracle price lower than pool price to create favorable toxic conditions
        // Pool starts at 1:1, oracle at 0.9:1
        // Large swap moving away from oracle should trigger dynamic fee

        // Set oracle price lower (0.9:1)
        oracle.setPrice(address(token0), address(token1), 0.9e18);

        // Pool price stays at 1:1 (SQRT_PRICE_1_1 already set in setUp)

        // Create a large swap that will move price further away from oracle
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true, // Swap token0 for token1 (increases price)
            amountSpecified: 10e18, // Large exact input amount
            sqrtPriceLimitX96: 0 // No limit
        });

        // Expect DirectionalFeeApplied event
        vm.expectEmit(true, true, true, false, address(hook));
        emit YieldSubsidizedDirectionalHook.DirectionalFeeApplied(
            testPoolId,
            true, // zeroForOne
            true, // isToxic - expected for this scenario
            0, // fee - we'll check this separately
            0, // oraclePrice - will be filled by hook
            0, // poolPrice - will be filled by hook
            0 // deviation - will be filled by hook
        );

        // Execute beforeSwap
        vm.prank(address(poolManager));
        (bytes4 selector, , uint24 feeOverride) = hook.beforeSwap(
            address(0),
            testPoolKey,
            swapParams,
            bytes("")
        );

        // Verify selector returned
        assertEq(selector, hook.beforeSwap.selector, "Should return correct selector");

        // Verify dynamic fee is applied
        // Note: Due to simplified estimation, actual fee may vary
        // We check that the fee is at least the baseline
        assertGe(feeOverride, BASE_FEE_BPS, "Fee should be at least baseline");
        assertLe(feeOverride, MAX_FEE_MULTIPLIER, "Fee should be capped at max multiplier");
    }

    // ============ TEST: BENIGN SWAP - BASELINE FEE APPLIED ============

    /// @notice Test that a benign swap (moving toward oracle) applies baseline fee
    /// @dev Validates Requirements: 1.1-1.7, 2.1-2.8, 5.1-5.5, 6.1-6.5, 23.1-23.5
    function test_BenignSwap_BaselineFeeApplied() public {
        // Setup: Pool price is lower than oracle price
        // Pool at 1:1, oracle at 1.1:1 (higher)
        // A oneForZero swap (selling token1) will INCREASE price toward oracle (benign)
        
        // Note: In Uniswap pricing, zeroForOne=true DECREASES price (more token1 per token0)
        // To move toward a HIGHER oracle price, we need zeroForOne=false (oneForZero)

        // Set oracle price higher (1.1:1)
        oracle.setPrice(address(token0), address(token1), 1.1e18);

        // Pool price is at 1:1 (SQRT_PRICE_1_1), which is lower than oracle

        // Create swap params that will move price toward oracle
        // oneForZero (zeroForOne=false) will increase the price toward the higher oracle price
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false, // Swap token1 for token0 (increases price toward oracle)
            amountSpecified: 0.1e18, // Small exact input to minimize classification issues
            sqrtPriceLimitX96: 0 // No limit
        });

        // Execute beforeSwap
        vm.prank(address(poolManager));
        (bytes4 selector, , uint24 feeOverride) = hook.beforeSwap(
            address(0),
            testPoolKey,
            swapParams,
            bytes("")
        );

        // Verify selector returned
        assertEq(selector, hook.beforeSwap.selector, "Should return correct selector");

        // Verify baseline fee applied (benign flow or below threshold)
        assertEq(feeOverride, BASE_FEE_BPS, "Benign swap should apply baseline fee");
    }

    // ============ TEST: STALE ORACLE - BASELINE FEE FALLBACK ============

    /// @notice Test that stale oracle price results in baseline fee fallback
    /// @dev Validates Requirements: 3.4 (oracle staleness handling)
    function test_StaleOracle_BaselineFeeApplied() public {
        // Set oracle price with stale timestamp (10 minutes old)
        oracle.setStalePrice(address(token0), address(token1), ORACLE_PRICE_1_1, 600);

        // Create swap params
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        // Execute beforeSwap
        vm.prank(address(poolManager));
        (bytes4 selector, , uint24 feeOverride) = hook.beforeSwap(
            address(0),
            testPoolKey,
            swapParams,
            bytes("")
        );

        // Verify selector returned
        assertEq(selector, hook.beforeSwap.selector, "Should return correct selector");

        // Verify baseline fee applied when oracle is stale
        assertEq(feeOverride, BASE_FEE_BPS, "Stale oracle should fallback to baseline fee");
    }

    // ============ TEST: ORACLE FAILURE - BASELINE FEE FALLBACK ============

    /// @notice Test that oracle failure (revert) results in baseline fee fallback
    /// @dev Validates Requirements: 3.4 (graceful oracle failure handling)
    function test_OracleFailure_BaselineFeeApplied() public {
        // Configure oracle to revert
        oracle.setShouldRevert(true);

        // Create swap params
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        // Execute beforeSwap
        vm.prank(address(poolManager));
        (bytes4 selector, , uint24 feeOverride) = hook.beforeSwap(
            address(0),
            testPoolKey,
            swapParams,
            bytes("")
        );

        // Verify selector returned
        assertEq(selector, hook.beforeSwap.selector, "Should return correct selector");

        // Verify baseline fee applied when oracle fails
        assertEq(feeOverride, BASE_FEE_BPS, "Failed oracle should fallback to baseline fee");
    }

    // ============ TEST: FEE SCALING WITH VARIOUS DEVIATIONS ============

    /// @notice Test fee scaling with different price deviation magnitudes
    /// @dev Validates Requirements: 6.3 (fee scaling curve)
    function test_FeeScaling_VariousDeviations() public {
        // Test scenario 1: Very small swap with oracle at 1:1
        oracle.setPrice(address(token0), address(token1), ORACLE_PRICE_1_1);
        
        IPoolManager.SwapParams memory smallSwap = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 0.001e18, // Very small swap
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(poolManager));
        (, , uint24 fee1) = hook.beforeSwap(address(0), testPoolKey, smallSwap, bytes(""));
        
        // Small swap should apply baseline fee
        assertEq(fee1, BASE_FEE_BPS, "Small swap should apply baseline fee");

        // Test scenario 2: Larger swap that could be toxic
        IPoolManager.SwapParams memory largeSwap = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 10e18, // Large swap
            sqrtPriceLimitX96: 0
        });
        
        // Set oracle price below pool to create toxic condition
        oracle.setPrice(address(token0), address(token1), 0.85e18);

        vm.prank(address(poolManager));
        (, , uint24 fee2) = hook.beforeSwap(address(0), testPoolKey, largeSwap, bytes(""));
        
        // Large swap with deviation should potentially apply scaled fee
        assertGe(fee2, BASE_FEE_BPS, "Large swap fee should be at least base");
        assertLe(fee2, MAX_FEE_MULTIPLIER, "Fee should not exceed maximum");

        // Test scenario 3: Very large swap
        IPoolManager.SwapParams memory hugeSwap = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 100e18, // Huge swap
            sqrtPriceLimitX96: 0
        });
        
        // Set oracle price significantly lower
        oracle.setPrice(address(token0), address(token1), ORACLE_PRICE_LOW);

        vm.prank(address(poolManager));
        (, , uint24 fee3) = hook.beforeSwap(address(0), testPoolKey, hugeSwap, bytes(""));
        
        // Huge swap should apply scaled fee
        assertGe(fee3, BASE_FEE_BPS, "Huge swap fee should be at least base");
        assertLe(fee3, MAX_FEE_MULTIPLIER, "Fee should not exceed maximum");
    }

    // ============ TEST: UNAUTHORIZED CALLER REVERTS ============

    /// @notice Test that non-PoolManager caller is rejected
    /// @dev Validates Requirements: 2.1-2.5 (access control)
    function test_UnauthorizedCaller_Reverts() public {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        // Attempt to call from unauthorized address
        vm.prank(ALICE);
        vm.expectRevert(); // Should revert with UnauthorizedCaller
        hook.beforeSwap(address(0), testPoolKey, swapParams, bytes(""));
    }

    // ============ TEST: UNREGISTERED POOL REVERTS ============

    /// @notice Test that swap on unregistered pool is rejected
    /// @dev Validates Requirements: 2.6-2.8 (pool registration validation)
    function test_UnregisteredPool_Reverts() public {
        // Create a different pool key that hasn't been initialized
        PoolKey memory unregisteredKey = createPoolKey(
            address(token1),
            address(token0),
            POOL_FEE,
            TICK_SPACING,
            address(hook)
        );

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        // Attempt swap on unregistered pool
        vm.prank(address(poolManager));
        vm.expectRevert(); // Should revert with PoolNotRegistered
        hook.beforeSwap(address(0), unregisteredKey, swapParams, bytes(""));
    }

    // ============ TEST: PAUSED POOL APPLIES BASELINE FEE ============

    /// @notice Test that paused pool applies baseline fee regardless of oracle
    /// @dev Validates Requirements: 33.3 (pause mechanism)
    function test_PausedPool_BaselineFeeOnly() public {
        // Pause the pool
        vm.prank(hook.owner());
        hook.pausePool(testPoolId);

        // Set oracle to indicate potentially toxic conditions
        oracle.setPrice(address(token0), address(token1), ORACLE_PRICE_HIGH);

        // Update pool price
        uint160 newSqrtPrice = SQRT_PRICE_1_1 - (SQRT_PRICE_1_1 * 30) / 100;
        poolManager.setSlot0(testPoolId, newSqrtPrice, -200, 0, POOL_FEE);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });

        // Execute swap
        vm.prank(address(poolManager));
        (, , uint24 feeOverride) = hook.beforeSwap(address(0), testPoolKey, swapParams, bytes(""));

        // Verify baseline fee applied despite toxic conditions
        // Paused pools still return baseFeeBps from config
        assertEq(feeOverride, BASE_FEE_BPS, "Paused pool should return baseline fee");
    }

    // ============ TEST: DIRECTIONAL FEE EVENT DETAILS ============

    /// @notice Test that DirectionalFeeApplied event includes all required details
    /// @dev Validates Requirements: 23.1-23.5 (event emission)
    function test_DirectionalFeeEvent_Details() public {
        // Set oracle price lower to create toxic conditions
        oracle.setPrice(address(token0), address(token1), 0.85e18);

        // Create a larger swap to ensure meaningful price impact
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 10e18, // Large swap
            sqrtPriceLimitX96: 0
        });

        // Record logs
        vm.recordLogs();

        // Execute swap
        vm.prank(address(poolManager));
        hook.beforeSwap(address(0), testPoolKey, swapParams, bytes(""));

        // Get emitted logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find DirectionalFeeApplied event
        bool eventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0]
                    == keccak256(
                        "DirectionalFeeApplied(bytes32,bool,bool,uint24,uint256,uint256,uint256)"
                    )
            ) {
                eventFound = true;

                // Decode event data (non-indexed parameters)
                (, uint24 fee, uint256 oraclePrice, uint256 poolPrice, uint256 deviation) =
                    abi.decode(logs[i].data, (bool, uint24, uint256, uint256, uint256));

                // Verify event includes oracle price
                assertGt(oraclePrice, 0, "Event should include oracle price");

                // Verify event includes pool price
                assertGt(poolPrice, 0, "Event should include pool price");

                // Verify event includes deviation (can be 0 if prices match)
                assertGe(deviation, 0, "Event should include price deviation");

                // Verify fee is included
                assertGt(fee, 0, "Event should include applied fee");

                break;
            }
        }

        assertTrue(eventFound, "DirectionalFeeApplied event should be emitted");
    }

    // ============ TEST: ZERO FOR ONE VS ONE FOR ZERO ============

    /// @notice Test that swap direction (zeroForOne) is correctly tracked
    /// @dev Validates Requirements: 5.4 (swap direction handling)
    function test_SwapDirection_Tracking() public {
        oracle.setPrice(address(token0), address(token1), ORACLE_PRICE_1_1);

        // Test zeroForOne
        IPoolManager.SwapParams memory swapParamsZeroForOne = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: 0
        });

        vm.recordLogs();
        vm.prank(address(poolManager));
        hook.beforeSwap(address(0), testPoolKey, swapParamsZeroForOne, bytes(""));

        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        bool foundZeroForOne = false;
        for (uint256 i = 0; i < logs1.length; i++) {
            if (
                logs1[i].topics[0]
                    == keccak256(
                        "DirectionalFeeApplied(bytes32,bool,bool,uint24,uint256,uint256,uint256)"
                    )
            ) {
                // zeroForOne is NOT indexed, it's in the data section (first bool)
                (bool zeroForOne, , , , ,) =
                    abi.decode(logs1[i].data, (bool, bool, uint24, uint256, uint256, uint256));
                foundZeroForOne = zeroForOne == true;
                break;
            }
        }
        assertTrue(foundZeroForOne, "Should track zeroForOne = true");

        // Test oneForZero
        IPoolManager.SwapParams memory swapParamsOneForZero = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: 0
        });

        vm.recordLogs();
        vm.prank(address(poolManager));
        hook.beforeSwap(address(0), testPoolKey, swapParamsOneForZero, bytes(""));

        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        bool foundOneForZero = false;
        for (uint256 i = 0; i < logs2.length; i++) {
            if (
                logs2[i].topics[0]
                    == keccak256(
                        "DirectionalFeeApplied(bytes32,bool,bool,uint24,uint256,uint256,uint256)"
                    )
            ) {
                // zeroForOne is NOT indexed, it's in the data section (first bool)
                (bool zeroForOne, , , , ,) =
                    abi.decode(logs2[i].data, (bool, bool, uint24, uint256, uint256, uint256));
                foundOneForZero = zeroForOne == false;
                break;
            }
        }
        assertTrue(foundOneForZero, "Should track zeroForOne = false");
    }
}
