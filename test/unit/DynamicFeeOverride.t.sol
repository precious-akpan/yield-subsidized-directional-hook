// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import {YieldSubsidizedDirectionalHookHelper} from "../helpers/YieldSubsidizedDirectionalHookHelper.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

/// @title DynamicFeeOverrideTest
/// @notice The fee returned from beforeSwap must be in v4 pips with OVERRIDE_FEE_FLAG set,
///         otherwise the PoolManager ignores it (or, above MAX_LP_FEE, reverts the swap)
contract DynamicFeeOverrideTest is BaseTest {
    YieldSubsidizedDirectionalHookHelper public hook;

    function setUp() public override {
        super.setUp();
        hook = new YieldSubsidizedDirectionalHookHelper(IPoolManager(address(new MockPoolManager())));
    }

    function test_OverrideFlagIsSet() public view {
        assertTrue(hook.testToLpFeeOverride(30) & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "flag must be set");
        assertTrue(hook.testToLpFeeOverride(0) & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "flag must be set for zero fee");
    }

    function test_BpsAreConvertedToPips() public view {
        // 30 bps = 0.30% = 3000 pips
        assertEq(hook.testToLpFeeOverride(30) & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, 3000);
        // 10_000 bps = 100% = MAX_LP_FEE
        assertEq(hook.testToLpFeeOverride(10_000) & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, LPFeeLibrary.MAX_LP_FEE);
    }

    function test_FeeAboveOneHundredPercentIsCapped() public view {
        assertEq(hook.testToLpFeeOverride(10_001) & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, LPFeeLibrary.MAX_LP_FEE);
        assertEq(hook.testToLpFeeOverride(type(uint24).max) & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, LPFeeLibrary.MAX_LP_FEE);
    }

    /// @dev The result must always pass v4's own validation, or the swap would revert
    function testFuzz_ResultIsAlwaysAValidOverride(uint24 feeBps) public view {
        uint24 result = hook.testToLpFeeOverride(feeBps);
        assertTrue(LPFeeLibrary.isOverride(result), "must be an override");
        assertTrue(LPFeeLibrary.isValid(result & ~LPFeeLibrary.OVERRIDE_FEE_FLAG), "must be a valid LP fee");
    }
}
