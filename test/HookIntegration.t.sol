// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {BoundedSwapHook} from "../src/BoundedSwapHook.sol";
import {DisabledCallbacks} from "../src/DisabledCallbacks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

contract HookIntegrationTest is Fixture {
    using StateLibrary for IPoolManager;

    uint160 internal constant PRICE = 1 << 96;
    BoundedSwapHook internal hook;
    PoolRouter internal router;
    TestToken internal tokenA;
    TestToken internal tokenB;
    TestToken internal tokenC;
    PoolKey internal poolA;
    PoolKey internal poolB;

    function setUp() public override {
        super.setUp();
        hook = BoundedSwapHook(_deploy(spec).hook);
        router = new PoolRouter(manager);
        tokenA = new TestToken("A", 6);
        tokenB = new TestToken("B", 18);
        tokenC = new TestToken("C", 8);
        _fund(tokenA);
        _fund(tokenB);
        _fund(tokenC);
        poolA = _key(tokenA, tokenB, 3000);
        poolB = _key(tokenA, tokenC, 500);
        assertNotEq(PoolId.unwrap(poolA.toId()), PoolId.unwrap(poolB.toId()));
        // Neither pool existed before the hook was deployed. No vm.etch or callback simulation here.
        (uint160 priceA,,,) = IPoolManager(manager).getSlot0(poolA.toId());
        (uint160 priceB,,,) = IPoolManager(manager).getSlot0(poolB.toId());
        assertEq(priceA, 0);
        assertEq(priceB, 0);
        assertFalse(hook.initialized(poolA.toId()));
        assertFalse(hook.initialized(poolB.toId()));
        manager.initialize(poolA, PRICE);
        manager.initialize(poolB, PRICE);
        router.liquidity(poolA, 1e12);
        router.liquidity(poolB, 1e12);
    }

    function testTwoNewPoolsReuseOneDeployedHook() public {
        assertTrue(hook.initialized(poolA.toId()));
        assertTrue(hook.initialized(poolB.toId()));
        _swap(poolA, true, -10_000);
        _swap(poolB, false, 20_000);
        _swap(poolA, false, -30_000);
        assertEq(hook.swapCount(poolA.toId()), 2);
        assertEq(hook.swapCount(poolB.toId()), 1);
        assertEq(tokenA.balanceOf(address(hook)), 0);
        assertEq(tokenB.balanceOf(address(hook)), 0);
        assertEq(tokenC.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }

    function testAllDirectionsAndExactModesAcceptLimit() public {
        int256 limit = int256(uint256(spec.maxSpecifiedAmount));
        _swap(poolA, true, -limit);
        _swap(poolA, false, -limit);
        _swap(poolA, true, limit);
        _swap(poolA, false, limit);
        assertEq(hook.swapCount(poolA.toId()), 4);
        assertEq(hook.swapCount(poolB.toId()), 0);
    }

    function testFuzzRealSwapsSettleAndConserve(uint128 raw, bool zeroForOne, bool exactInput, bool secondPool) public {
        uint256 amount = bound(uint256(raw), 10, spec.maxSpecifiedAmount);
        PoolKey memory key = secondPool ? poolB : poolA;
        TestToken t0 = TestToken(Currency.unwrap(key.currency0));
        TestToken t1 = TestToken(Currency.unwrap(key.currency1));
        uint256 before0 = t0.balanceOf(address(this)) + t0.balanceOf(address(manager));
        uint256 before1 = t1.balanceOf(address(this)) + t1.balanceOf(address(manager));
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        BalanceDelta delta = _swap(key, zeroForOne, specified);
        int128 input = zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = zeroForOne ? delta.amount1() : delta.amount0();
        assertLt(input, 0);
        assertGt(output, 0);
        if (exactInput) assertEq(-int256(input), int256(amount));
        else assertEq(int256(output), int256(amount));
        assertEq(t0.balanceOf(address(this)) + t0.balanceOf(address(manager)), before0);
        assertEq(t1.balanceOf(address(this)) + t1.balanceOf(address(manager)), before1);
        assertEq(hook.swapCount(key.toId()), 1);
        assertEq(hook.swapCount((secondPool ? poolA : poolB).toId()), 0);
    }

    /// @dev Decision: the limit caps only `amountSpecified`. The unspecified side (input of an
    /// exact-output swap, output of an exact-input swap) is not capped by the hook; see README.
    function testLimitCapsOnlySpecifiedSideNotUnspecifiedSide() public {
        int256 limit = int256(uint256(spec.maxSpecifiedAmount));
        // Exact output of exactly the limit: the input paid includes the 0.3% fee and price impact.
        BalanceDelta exactOut = _swap(poolA, true, limit);
        assertEq(int256(exactOut.amount1()), limit);
        assertGt(-int256(exactOut.amount0()), limit, "input side exceeds the limit and is still accepted");
        // Exact input of exactly the limit: the output is whatever the pool gives, below the limit here.
        BalanceDelta exactIn = _swap(poolA, false, -limit);
        assertEq(-int256(exactIn.amount1()), limit);
        assertLt(int256(exactIn.amount0()), limit);
        assertEq(hook.swapCount(poolA.toId()), 2);
        // One raw unit more on the specified side is refused in both modes.
        _expectWrapped(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(BoundedSwapHook.AmountOutsideLimit.selector, limit + 1, spec.maxSpecifiedAmount)
        );
        _swap(poolA, true, limit + 1);
    }

    function testOverLimitRevertsThroughManagerInAllModes() public {
        int256 over = int256(uint256(spec.maxSpecifiedAmount)) + 1;
        for (uint256 i; i < 4; ++i) {
            int256 amount = i < 2 ? -over : over;
            _expectWrapped(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(BoundedSwapHook.AmountOutsideLimit.selector, amount, spec.maxSpecifiedAmount)
            );
            _swap(poolA, i % 2 == 0, amount);
        }
        assertEq(hook.swapCount(poolA.toId()), 0);
    }

    function testSettlementFailureRollsBackCounterAndPoolState() public {
        (uint160 priceBefore,,,) = IPoolManager(manager).getSlot0(poolA.toId());
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(poolA, _params(true, -10_000), "", true);
        (uint160 priceAfter,,,) = IPoolManager(manager).getSlot0(poolA.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(hook.swapCount(poolA.toId()), 0);
        _swap(poolA, true, -10_000);
        assertEq(hook.swapCount(poolA.toId()), 1);
    }

    function testLiquidityWithdrawalRemainsAvailableAfterRejectedSwap() public {
        int256 over = int256(uint256(spec.maxSpecifiedAmount)) + 1;
        _expectWrapped(
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(BoundedSwapHook.AmountOutsideLimit.selector, -over, spec.maxSpecifiedAmount)
        );
        _swap(poolA, true, -over);
        BalanceDelta removed = router.liquidity(poolA, -1e12);
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
    }

    function testDuplicatePoolInitializationFails() public {
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(poolA, PRICE);
    }

    function testDynamicFeePoolRejectedAtomically() public {
        PoolKey memory key = poolA;
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _expectWrapped(
            IHooks.afterInitialize.selector, abi.encodeWithSelector(BoundedSwapHook.DynamicFeeUnsupported.selector)
        );
        manager.initialize(key, PRICE);
        assertFalse(hook.initialized(key.toId()));
        (uint160 price,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(price, 0);
    }

    function testFuzzUnauthorizedCallbacks(address caller) public {
        vm.assume(caller != address(manager));
        vm.startPrank(caller);
        vm.expectRevert(BoundedSwapHook.OnlyPoolManager.selector);
        hook.afterInitialize(caller, poolA, PRICE, 0);
        vm.expectRevert(BoundedSwapHook.OnlyPoolManager.selector);
        hook.beforeSwap(caller, poolA, _params(true, -100), "");
        vm.expectRevert(BoundedSwapHook.OnlyPoolManager.selector);
        hook.afterSwap(caller, poolA, _params(true, -100), BalanceDelta.wrap(0), "");
        vm.stopPrank();
    }

    function testWrongHookAndUnknownPoolRejected() public {
        PoolKey memory wrong = poolA;
        wrong.hooks = IHooks(address(factory));
        vm.startPrank(address(manager));
        vm.expectRevert(BoundedSwapHook.WrongHook.selector);
        hook.beforeSwap(address(this), wrong, _params(true, -100), "");
        PoolKey memory unknown = poolA;
        unknown.fee = 100;
        vm.expectRevert(BoundedSwapHook.PoolNotInitialized.selector);
        hook.beforeSwap(address(this), unknown, _params(true, -100), "");
        vm.expectRevert(BoundedSwapHook.PoolNotInitialized.selector);
        hook.afterSwap(address(this), unknown, _params(true, -100), BalanceDelta.wrap(0), "");
        vm.expectRevert(BoundedSwapHook.PoolAlreadyInitialized.selector);
        hook.afterInitialize(address(this), poolA, PRICE, 0);
        vm.stopPrank();
    }

    function testFuzzSignedBoundaryAndNeutralReturn(int256 amount, bytes memory hookData) public {
        int256 limit = int256(uint256(spec.maxSpecifiedAmount));
        vm.prank(address(manager));
        if (amount == 0 || amount < -limit || amount > limit) {
            vm.expectRevert(
                abi.encodeWithSelector(BoundedSwapHook.AmountOutsideLimit.selector, amount, spec.maxSpecifiedAmount)
            );
            hook.beforeSwap(address(this), poolA, _params(true, amount), hookData);
        } else {
            (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
                hook.beforeSwap(address(this), poolA, _params(true, amount), hookData);
            assertEq(selector, IHooks.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(delta), 0);
            assertEq(fee, 0);
        }
    }

    function testIntMinIntMaxAndZeroFailClearly() public {
        int256[3] memory amounts = [type(int256).min, type(int256).max, int256(0)];
        vm.startPrank(address(manager));
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(BoundedSwapHook.AmountOutsideLimit.selector, amounts[i], spec.maxSpecifiedAmount)
            );
            hook.beforeSwap(address(this), poolA, _params(true, amounts[i]), "");
        }
        vm.stopPrank();
    }

    function testUnusedCallbacksAlwaysRevert() public {
        IPoolManager.ModifyLiquidityParams memory lp;
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(IHooks.beforeInitialize, (address(this), poolA, PRICE));
        calls[1] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), poolA, lp, ""));
        calls[2] = abi.encodeCall(IHooks.afterAddLiquidity, (address(this), poolA, lp, zero, zero, ""));
        calls[3] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), poolA, lp, ""));
        calls[4] = abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), poolA, lp, zero, zero, ""));
        calls[5] = abi.encodeCall(IHooks.beforeDonate, (address(this), poolA, 1, 1, ""));
        calls[6] = abi.encodeCall(IHooks.afterDonate, (address(this), poolA, 1, 1, ""));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(manager));
            (bool ok, bytes memory data) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(data, abi.encodeWithSelector(DisabledCallbacks.CallbackNotEnabled.selector));
        }
    }

    function testFuzzHookDataHasNoAuthority(bytes memory data) public {
        router.swap(poolA, _params(true, -100), data, false);
        assertEq(hook.swapCount(poolA.toId()), 1);
        assertEq(hook.maxSpecifiedAmount(), spec.maxSpecifiedAmount);
    }

    function _expectWrapped(bytes4 callback, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callback,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _fund(TestToken token) internal {
        token.mint(address(this), 1e15);
        token.approve(address(router), 1e15);
    }

    function _key(TestToken a, TestToken b, uint24 fee) internal view returns (PoolKey memory) {
        (address low, address high) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        return PoolKey(Currency.wrap(low), Currency.wrap(high), fee, 60, IHooks(address(hook)));
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return router.swap(key, _params(zeroForOne, amount), "", false);
    }
}
