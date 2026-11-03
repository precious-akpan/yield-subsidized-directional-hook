// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import {YieldSubsidizedDirectionalHook} from "../../src/YieldSubsidizedDirectionalHook.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @title RealPoolManagerSwapTest
/// @notice Runs swaps through the real v4 PoolManager (not MockPoolManager) to check that the fee
///         returned by beforeSwap is actually applied, which the mock-based tests cannot show
contract RealPoolManagerSwapTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint24 constant BASE_FEE_BPS = 30; // 0.30% -> 3000 pips
    uint24 constant MAX_FEE_MULTIPLIER = 30_000; // 3x
    uint24 constant DEVIATION_THRESHOLD_BPS = 50;
    int24 constant TICK_SPACING = 60;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liquidityRouter;
    YieldSubsidizedDirectionalHook hook;
    MockOracle oracle;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;

    function setUp() public override {
        super.setUp();

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // The PoolManager checks that the hook address encodes its permissions
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        address hookAddress = address(flags ^ (uint160(0x4444) << 144));
        deployCodeTo(
            "YieldSubsidizedDirectionalHook.sol:YieldSubsidizedDirectionalHook", abi.encode(manager), hookAddress
        );
        hook = YieldSubsidizedDirectionalHook(hookAddress);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: DYNAMIC_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        oracle = new MockOracle();
        // Oracle is 10% above the pool: oneForZero swaps move toward it (benign), zeroForOne away (toxic)
        oracle.setPrice(address(token0), address(token1), 1.1e18);

        hook.configurePool(
            key.toId(),
            DataTypes.PoolConfig({
                oracle: address(oracle),
                vault0: address(new MockERC4626Vault(address(token0))),
                vault1: address(new MockERC4626Vault(address(token1))),
                baseFeeBps: BASE_FEE_BPS,
                maxFeeMultiplier: MAX_FEE_MULTIPLIER,
                deviationThresholdBps: DEVIATION_THRESHOLD_BPS,
                isPaused: false
            })
        );

        token0.mint(address(this), 1000e18);
        token1.mint(address(this), 1000e18);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        liquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 10, tickUpper: TICK_SPACING * 10, liquidityDelta: 100e18, salt: 0
            }),
            ""
        );
    }

    /// @dev Swaps 0.01 tokens exact-input and returns the LP fee the PoolManager reports for it
    function _swapAndGetFee(bool zeroForOne) internal returns (uint24 fee) {
        vm.recordLogs();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -0.01e18,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("Swap event not found");
    }

    function test_BenignSwapChargesBaseFee() public {
        // 30 bps = 3000 pips
        assertEq(_swapAndGetFee(false), 3000, "benign flow should pay the base fee");
    }

    function test_ToxicSwapChargesScaledFee() public {
        // 3x multiplier on 30 bps = 90 bps = 9000 pips
        assertEq(_swapAndGetFee(true), 9000, "toxic flow should pay the scaled fee");
    }

    function test_PausedPoolChargesBaseFee() public {
        hook.pausePool(key.toId());
        assertEq(_swapAndGetFee(true), 3000, "paused pool should pay the base fee");
    }

    function test_StaleOracleFallsBackToBaseFee() public {
        oracle.setShouldRevert(true);
        assertEq(_swapAndGetFee(true), 3000, "failed oracle should fall back to the base fee");
    }

    function test_SwapBeforeConfigurationReverts() public {
        // A second pool that is initialized but never configured
        PoolKey memory unconfigured = key;
        unconfigured.tickSpacing = TICK_SPACING * 2;
        manager.initialize(unconfigured, SQRT_PRICE_1_1);

        vm.expectRevert(); // PoolManager wraps the hook's PoolNotConfigured revert
        swapRouter.swap(
            unconfigured,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -0.01e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_StaticFeePoolCannotBeInitialized() public {
        PoolKey memory staticKey = key;
        staticKey.fee = 3000;
        vm.expectRevert(); // PoolManager wraps the hook revert
        manager.initialize(staticKey, SQRT_PRICE_1_1);
    }
}
