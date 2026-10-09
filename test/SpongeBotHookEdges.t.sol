// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {SpongeBotHook} from "../src/SpongeBotHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";
import {ClaimRouter} from "./utils/ClaimRouter.sol";
import {PreSyncSwapRouter} from "./utils/PreSyncSwapRouter.sol";

/// @dev A router that tries to run `sweep()` or `redeemRefund()` from inside its own unlock: the hook must not be
/// usable mid-swap.
contract ReentrantSweeper is IUnlockCallback {
    IPoolManager immutable manager;
    SpongeBotHook immutable hook;
    bool redeem;

    constructor(IPoolManager manager_, SpongeBotHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function run(bool redeem_) external {
        redeem = redeem_;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (redeem) hook.redeemRefund(1);
        else hook.sweep();
        return "";
    }
}

/// @notice Adversarial edge cases for the hook on a fresh PoolManager: dust, zero fills, exact revert data, block
/// boundaries, events, refund delivery and redemption, reentrancy and misuse.
contract SpongeBotHookEdgesTest is HookTestBase {
    uint256 constant BPS = 10_000;

    function _poolManager() internal override returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(this))));
    }

    function _fundImd(address to, uint256 amount) internal override {
        MockERC20(IMD).mint(to, amount);
    }

    function setUp() public {
        vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        vm.roll(1_000);
        _setUpPool(true);
    }

    function _wrapped(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Dust: one wei in every direction and kind
    // ---------------------------------------------------------------------------------------------

    function test_oneWeiExactInputBuyDoesNotRevert() public {
        // reserved = ceil(1 x 3100 / 13100) = 1, so the pool is asked to swap 0 and fills nothing.
        uint256 imdBefore = _imdBalance(address(this));
        _buy(-1, 0);
        assertEq(imdBefore - _imdBalance(address(this)), 1, "pays the one wei");
        assertEq(_routerRefund(), 1, "whole reservation refunded");
        assertEq(_imdBalance(address(swapRouter)), 1, "as IMD: the manager could cover it");
        assertEq(hook.pending(), 0, "no fee on a zero fill");
        assertEq(manager.balanceOf(address(hook), IMD_ID), 0);
    }

    function test_oneWeiExactOutputBuyDoesNotRevert() public {
        uint256 tokenBefore = token.balanceOf(address(this));
        _buy(1, 0);
        assertEq(token.balanceOf(address(this)) - tokenBefore, 1);
        assertEq(hook.pending(), manager.balanceOf(address(hook), IMD_ID));
    }

    function test_oneWeiExactInputSellDoesNotRevert() public {
        uint256 imdBefore = _imdBalance(address(this));
        _sell(-1, 0);
        // The pool delivers at most one wei of IMD; the fee on one wei floors to zero.
        assertLe(_imdBalance(address(this)) - imdBefore, 1);
        assertEq(hook.pending(), 0);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 0);
    }

    function test_oneWeiExactOutputSellDoesNotRevert() public {
        uint256 imdBefore = _imdBalance(address(this));
        _sell(1, 0);
        assertEq(_imdBalance(address(this)) - imdBefore, 1, "receives exactly one wei");
        assertEq(hook.pending(), manager.balanceOf(address(hook), IMD_ID));
        // reserved = ceil(1 x 3100 / 6900) = 1; the pool delivered 2, fee = floor(2 x 0.31) = 0, so it is refunded.
        assertEq(_routerRefund(), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Accepted swap domain: exact revert data, and the largest representable requests
    // ---------------------------------------------------------------------------------------------

    function test_unrepresentableFeeIsTheExactWrappedRevert() public {
        bytes memory expected = _wrapped(IHooks.beforeSwap.selector, SpongeBotHook.UnrepresentableFee.selector);
        vm.expectRevert(expected);
        _sell(type(int256).max, 0);
        vm.expectRevert(expected);
        _buy(type(int256).min, 0);
        // A reservation that would not fit the int128 return delta is refused the same way.
        vm.expectRevert(expected);
        _buy(-int256(uint256(1) << 140), 0);
        vm.expectRevert(expected);
        _sell(int256(uint256(1) << 140), 0);
        assertEq(hook.pending(), 0, "nothing accrued by a refused swap");
    }

    function test_hugeRepresentableExactInputBuyWithPriceLimitRefundsTheUnfilledReservation() public {
        uint256 rate = hook.feeBps();
        uint256 amountIn = 1e30;
        _fundImd(address(this), amountIn);
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price - price / 1_000 : price + price / 1_000;
        uint256 imdBefore = _imdBalance(address(this));

        _buy(-int256(amountIn), limit);

        uint256 paid = imdBefore - _imdBalance(address(this));
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = _routerRefund();
        uint256 poolImd = paid - fee - refund;
        assertLt(poolImd, 1e24, "only a sliver filled");
        assertEq(fee, poolImd * rate / BPS, "fee on the fill only");
        assertEq(paid - refund, poolImd + fee, "net cost is fill plus fee");
        // The reservation (about 2.3e29) dwarfs the manager's IMD, so this refund had to be a claim.
        assertEq(manager.balanceOf(address(swapRouter), IMD_ID), refund, "refund minted as a claim");
        assertEq(_imdBalance(address(swapRouter)), 0);
    }

    function test_unspecifiedSideFeeNeverExceedsRateOnHugeFill() public {
        // Exact-input sell of a large token amount: IMD out is unspecified, fee from the real delta.
        uint256 rate = hook.feeBps();
        uint256 imdBefore = _imdBalance(address(this));
        _sell(-int256(uint256(500_000 ether)), 0);
        uint256 received = _imdBalance(address(this)) - imdBefore;
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        assertEq(fee, (received + fee) * rate / BPS);
        assertEq(_routerRefund(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Block boundaries through real swaps
    // ---------------------------------------------------------------------------------------------

    function test_blockNineChargesThreePercentAntiSnipeAndBlockTenChargesNone() public {
        uint256 open = hook.poolOpenBlock();
        vm.roll(open + 9);
        assertEq(hook.antiSnipeBps(), 300);
        uint256 amountOut = 100 ether;
        uint256 imdBefore = _imdBalance(address(this));
        _buy(int256(amountOut), 0); // IMD unspecified: fee straight from the delta
        uint256 paid = imdBefore - _imdBalance(address(this));
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 poolImd = paid - fee;
        assertEq(hook.pendingStaking(), poolImd * 100 / BPS);
        assertEq(hook.pendingAntiSnipe(), fee - poolImd * 100 / BPS);
        assertEq(fee, poolImd * 400 / BPS);

        vm.roll(open + 10);
        assertEq(hook.antiSnipeBps(), 0);
        uint256 antiBefore = hook.pendingAntiSnipe();
        imdBefore = _imdBalance(address(this));
        uint256 feeBefore = manager.balanceOf(address(hook), IMD_ID);
        _buy(int256(amountOut), 0);
        paid = imdBefore - _imdBalance(address(this));
        uint256 fee2 = manager.balanceOf(address(hook), IMD_ID) - feeBefore;
        assertEq(fee2, (paid - fee2) * 100 / BPS, "one percent only");
        assertEq(hook.pendingAntiSnipe(), antiBefore, "no anti-snipe from block ten on");

        vm.roll(open + 1_000_000);
        assertEq(hook.feeBps(), 100, "never grows back");
    }

    function test_openingBlockSwapPaysThirtyPercentAntiSnipe() public {
        assertEq(block.number, hook.poolOpenBlock());
        uint256 imdBefore = _imdBalance(address(this));
        _buy(int256(100 ether), 0);
        uint256 paid = imdBefore - _imdBalance(address(this));
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 poolImd = paid - fee;
        assertEq(hook.pendingAntiSnipe(), fee - poolImd * 100 / BPS);
        assertApproxEqAbs(hook.pendingAntiSnipe(), poolImd * 3_000 / BPS, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    function test_feeAccruedEventCarriesTheSplit() public {
        uint256 snap = vm.snapshotState();
        _buy(int256(250 ether), 0);
        uint256 anti = hook.pendingAntiSnipe();
        uint256 staking = hook.pendingStaking();
        vm.revertToState(snap);

        vm.expectEmit(true, true, true, true, address(hook));
        emit SpongeBotHook.FeeAccrued(anti, staking, 0);
        _buy(int256(250 ether), 0);
    }

    function test_feeAccruedAndRefundedEventsOnPartialFill() public {
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price - price / 10_000 : price + price / 10_000;
        uint256 snap = vm.snapshotState();
        _buy(-int256(uint256(10_000 ether)), limit);
        uint256 anti = hook.pendingAntiSnipe();
        uint256 staking = hook.pendingStaking();
        uint256 refund = _routerRefund();
        assertGt(refund, 0);
        vm.revertToState(snap);

        vm.expectEmit(true, true, true, true, address(hook));
        emit SpongeBotHook.Refunded(address(swapRouter), refund, false);
        vm.expectEmit(true, true, true, true, address(hook));
        emit SpongeBotHook.FeeAccrued(anti, staking, refund);
        _buy(-int256(uint256(10_000 ether)), limit);
    }

    function test_poolOpenedEventOnInitialize() public {
        SpongeBotHook fresh = _deployHook(4_000_000);
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        vm.expectEmit(true, true, true, true, address(fresh));
        emit SpongeBotHook.PoolOpened(k.toId(), block.number);
        vm.prank(FACTORY);
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------------------------------------
    // Refund delivery: exact-output sell with a hookData recipient, self-routing swappers, redemption
    // ---------------------------------------------------------------------------------------------

    /// @notice The other specified-side kind: a price-limited exact-output sell names the swapper in hookData and
    /// gets the unfilled reservation back as IMD in its own wallet.
    function test_exactOutputSellPartialFillRefundReachesHookDataRecipient() public {
        uint256 rate = hook.feeBps();
        address user = makeAddr("user");
        token.transfer(user, 100_000 ether);
        _fundImd(user, 1_000 ether); // tiny fills can leave a sell owing a few wei of IMD
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price + price / 1_000 : price - price / 1_000;
        vm.startPrank(user);
        token.approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(IMD).approve(address(swapRouter), type(uint256).max);
        _swap(!imdIsCurrency0, int256(10_000 ether), limit, abi.encode(user));
        vm.stopPrank();

        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 received = _imdBalance(user) - 1_000 ether;
        assertLt(received, 10_000 ether, "partial fill");
        assertEq(fee, (received + fee) * rate / BPS, "fee on what filled only");
        assertEq(_routerRefund(), 0, "nothing stranded on the router");
        assertEq(manager.balanceOf(user, IMD_ID), 0, "no claim needed");
    }

    function test_selfRoutingSwapperGetsRefundAsImdInTheSameSwap() public {
        ClaimRouter router = new ClaimRouter(manager);
        uint256 rate = hook.feeBps();
        IERC20Minimal(IMD).transfer(address(router), 10_000 ether);
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price - price / 10_000 : price + price / 10_000;
        uint256 tokenBefore = token.balanceOf(address(this));

        router.swap(key, SwapParams(imdIsCurrency0, -int256(uint256(10_000 ether)), limit));

        uint256 refund = _imdBalance(address(router));
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        assertGt(refund, fee, "most of the reservation came back as IMD to the sender");
        assertEq(manager.balanceOf(address(router), IMD_ID), 0, "no claim on a funded manager");
        assertEq(_routerRefund(), 0, "nothing to the uninvolved test router");
        assertGt(token.balanceOf(address(this)), tokenBefore, "owner received the tokens");
        uint256 poolImd = 10_000 ether - refund - fee;
        assertEq(fee, poolImd * rate / BPS, "fee on the fill only");
        assertLt(10_000 ether - refund, 10_000 ether / 10, "a partial fill costs a fraction of the request");
        assertEq(router.redeem(Currency.wrap(IMD)), 0, "no claim to redeem");
    }

    function test_claimRefundCanPayTheNextSwapOrBeRedeemed() public {
        // Force the claim path: IMD is the synced currency while the hook refunds.
        PreSyncSwapRouter preSync = new PreSyncSwapRouter(manager);
        IERC20Minimal(IMD).approve(address(preSync), type(uint256).max);
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price - price / 10_000 : price + price / 10_000;
        preSync.swap(key, SwapParams(imdIsCurrency0, -10_000 ether, limit), 10_000 ether, abi.encode(address(this)));
        uint256 claim = manager.balanceOf(address(this), IMD_ID);
        assertGt(claim, 0, "refund as a claim");

        // Redeeming more than held, or without approving the hook, fails and burns nothing.
        vm.expectRevert();
        hook.redeemRefund(claim);
        manager.setOperator(address(hook), true);
        vm.expectRevert();
        hook.redeemRefund(claim + 1);
        assertEq(manager.balanceOf(address(this), IMD_ID), claim);

        // Half redeemed now, half spent on the next swap through the test router's claim settlement.
        uint256 half = claim / 2;
        uint256 imdBefore = _imdBalance(address(this));
        vm.expectEmit(true, true, true, true, address(hook));
        emit SpongeBotHook.RefundRedeemed(address(this), half);
        hook.redeemRefund(half);
        assertEq(_imdBalance(address(this)) - imdBefore, half);
        uint256 rest = claim - half;
        manager.setOperator(address(swapRouter), true);
        uint256 feeBefore = manager.balanceOf(address(hook), IMD_ID);
        swapRouter.swap(
            key,
            SwapParams(
                imdIsCurrency0,
                -int256(rest),
                imdIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, true),
            ""
        );
        assertEq(manager.balanceOf(address(this), IMD_ID), 0, "claims burned to pay the input");
        assertEq(_imdBalance(address(this)), imdBefore + half, "no IMD moved from the wallet");
        assertGt(manager.balanceOf(address(hook), IMD_ID), feeBefore, "and the fee accrued as usual");
    }

    function test_testRouterClaimSettingsComposeWithTheHook() public {
        uint256 rate = hook.feeBps();
        // Take the SPONGEBOT output as a claim, then sell it back paying with that claim.
        BalanceDelta d = swapRouter.swap(
            key,
            SwapParams(
                imdIsCurrency0,
                -int256(uint256(100 ether)),
                imdIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
        uint256 tokenClaims = manager.balanceOf(address(this), uint256(uint160(address(token))));
        assertEq(tokenClaims, uint256(uint128(_tokenDelta(d))));
        uint256 feeBefore = manager.balanceOf(address(hook), IMD_ID);
        uint256 imdBefore = _imdBalance(address(this));

        manager.setOperator(address(swapRouter), true);
        swapRouter.swap(
            key,
            SwapParams(
                !imdIsCurrency0,
                -int256(tokenClaims),
                imdIsCurrency0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            ),
            PoolSwapTest.TestSettings(false, true),
            ""
        );
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(token)))), 0, "claims burned to pay");
        uint256 received = _imdBalance(address(this)) - imdBefore;
        uint256 fee = manager.balanceOf(address(hook), IMD_ID) - feeBefore;
        assertEq(fee, (received + fee) * rate / BPS, "fee unchanged by the settlement style");
    }

    // ---------------------------------------------------------------------------------------------
    // Misuse and reentrancy
    // ---------------------------------------------------------------------------------------------

    function test_sweepAndRedeemCannotRunInsideAnotherUnlock() public {
        _buy(-100 ether, 0);
        uint256 pendingBefore = hook.pending();
        ReentrantSweeper sweeper = new ReentrantSweeper(manager, hook);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        sweeper.run(false);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        sweeper.run(true);
        assertEq(hook.pending(), pendingBefore, "nothing moved");
    }

    function test_sweepFromAnyoneInTheSwapBlockThenAgainLater() public {
        _buy(-100 ether, 0);
        uint256 anti1 = hook.pendingAntiSnipe();
        uint256 staking1 = hook.pendingStaking();
        vm.prank(makeAddr("keeper"));
        hook.sweep();
        vm.roll(hook.poolOpenBlock() + 10);
        _sell(-100 ether, 0);
        uint256 staking2 = hook.pendingStaking();
        assertEq(hook.pendingAntiSnipe(), 0);
        vm.prank(makeAddr("other keeper"));
        hook.sweep();
        assertEq(_imdBalance(hook.HACKATHON_VAULT()), anti1);
        assertEq(_imdBalance(address(vault)), staking1 + staking2);
        assertApproxEqAbs(vault.unstreamedRewards(), staking1 + staking2, 2, "nothing staked: all still to stream");
        assertEq(vault.streamEnd(), block.number + vault.REWARD_DURATION());
        assertEq(hook.pending(), 0);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 0);
    }

    function test_hookNeverHoldsTokensDirectly() public {
        _buy(-1_000 ether, 0);
        _sell(-1_000 ether, 0);
        _buy(int256(10 ether), 0);
        _sell(int256(10 ether), 0);
        hook.sweep();
        assertEq(_imdBalance(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "no token claims either");
    }

    function test_oddHookDataNeverRevertsOrChangesTheFee() public {
        uint256 snap = vm.snapshotState();
        _buy(-100 ether, 0);
        uint256 feePlain = manager.balanceOf(address(hook), IMD_ID);
        vm.revertToState(snap);
        // 32 bytes of garbage: the low 160 bits are taken as the refund recipient; the fee is untouched.
        _swap(imdIsCurrency0, -100 ether, 0, hex"deadbeef00000000000000000000000000000000000000000000000000000001");
        assertEq(manager.balanceOf(address(hook), IMD_ID), feePlain);
        vm.revertToState(snap);
        // Any other length is ignored.
        _swap(imdIsCurrency0, -100 ether, 0, hex"deadbeef");
        assertEq(manager.balanceOf(address(hook), IMD_ID), feePlain);
        vm.revertToState(snap);
        _swap(imdIsCurrency0, -100 ether, 0, abi.encode(address(this), uint256(1)));
        assertEq(manager.balanceOf(address(hook), IMD_ID), feePlain);
    }

    function test_hookDataRecipientCanBeAnyAddressIncludingOnesThatCannotSettle() public {
        // The refund is an IMD transfer (or a claim), never a call: a recipient with no code path for it is fine.
        address sink = address(0x1234);
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price - price / 10_000 : price + price / 10_000;
        _swap(imdIsCurrency0, -10_000 ether, limit, abi.encode(sink));
        assertGt(_imdBalance(sink), 0, "refund delivered as IMD to the named address");
        assertEq(_routerRefund(), 0);
    }

    function test_swapOnAnUninitializedKeyWithThisHookIsRefusedByTheManager() public {
        PoolKey memory other = key;
        other.fee = 3_000;
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        swapRouter.swap(
            other,
            SwapParams(
                imdIsCurrency0, -1 ether, imdIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(hook.pending(), 0);
    }

    function test_managerCannotReplayAfterSwapWithoutASwap() public {
        // Even the manager cannot make the hook mint claims outside a swap: mint needs the manager unlocked.
        SwapParams memory params = SwapParams(!imdIsCurrency0, -1 ether, 0);
        vm.prank(address(manager));
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(int256(1 ether) << 128 | int256(1 ether)), "");
        assertEq(hook.pending(), 0);
    }

    function test_unlockCallbackWithMalformedDataIsRefused() public {
        vm.prank(address(manager));
        vm.expectRevert(SpongeBotHook.NotSweeping.selector);
        hook.unlockCallback(hex"01");
        vm.prank(address(manager));
        vm.expectRevert(SpongeBotHook.NotSweeping.selector);
        hook.unlockCallback(abi.encode(uint256(1 ether), uint256(1 ether), address(this)));
        vm.expectRevert(SpongeBotHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1 ether), uint256(1 ether), address(this)));
    }

    function test_initializeFromNonFactoryBeforeFactoryIsRefusedByAlreadyInitialized() public {
        // The launch pool is open; nobody, factory or not, can open a second pool on this hook.
        PoolKey memory other = key;
        other.tickSpacing = 10;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(SpongeBotHook.AlreadyInitialized.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_freshHookRefusesWrongPairAndDynamicFeeWithExactErrors() public {
        SpongeBotHook fresh = _deployHook(5_000_000);
        MockERC20 other = new MockERC20("X", "X", 0);
        (address c0, address c1) = address(other) < IMD ? (address(other), IMD) : (IMD, address(other));
        PoolKey memory wrong = PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, 60, IHooks(address(fresh)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(SpongeBotHook.WrongPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(wrong, SQRT_PRICE_1_1);

        PoolKey memory dyn = key;
        dyn.fee = 0x800000;
        dyn.hooks = IHooks(address(fresh));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fresh),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(SpongeBotHook.DynamicFeeNotAllowed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(dyn, SQRT_PRICE_1_1);
        assertEq(fresh.poolOpenBlock(), 0, "still unopened");
    }

    // ---------------------------------------------------------------------------------------------
    // Staking rewards stream through the real sweep
    // ---------------------------------------------------------------------------------------------

    function _stakeAs(address who, uint256 amount) internal {
        token.transfer(who, amount);
        vm.startPrank(who);
        token.approve(address(vault), type(uint256).max);
        vault.stake(amount);
        vm.stopPrank();
    }

    function test_rewardsReachMultipleStakersProRataAfterSweep() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _stakeAs(alice, 300 ether);
        _stakeAs(bob, 100 ether);
        uint256 D = vault.REWARD_DURATION();

        _buy(-1_000 ether, 0);
        uint256 staking = hook.pendingStaking();
        hook.sweep();
        assertEq(vault.earned(alice) + vault.earned(bob), 0, "nothing in the sweep block");
        assertApproxEqAbs(vault.unstreamedRewards(), staking, 1);
        vm.roll(vm.getBlockNumber() + 7);
        _buy(-1 ether, 0);
        uint256 total = staking + hook.pendingStaking();
        hook.sweep(); // folds the unstreamed rest of the first window into a fresh one
        assertEq(vault.streamEnd(), block.number + D);
        vm.roll(vm.getBlockNumber() + D);
        assertApproxEqAbs(vault.earned(alice), total * 3 / 4, 4);
        assertApproxEqAbs(vault.earned(bob), total / 4, 4);
        assertLe(vault.earned(alice) + vault.earned(bob), total, "never owes more than swept");
        assertEq(vault.unstreamedRewards(), 0);
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_flashStakeAroundSweepNeverEarns(uint128 bag, uint32 wait, uint128 swapAmount, bool sellSide)
        public
    {
        uint256 bot = bound(uint256(bag), 1, 100_000 ether);
        uint256 blocks = bound(uint256(wait), 1, 10_000_000);
        uint256 amount = bound(uint256(swapAmount), 1e12, 10_000 ether);
        address alice = makeAddr("alice");
        address botAddr = makeAddr("bot");
        _stakeAs(alice, 100 ether);
        vm.roll(vm.getBlockNumber() + blocks);
        if (sellSide) _sell(-int256(amount), 0);
        else _buy(-int256(amount), 0);
        uint256 staking = hook.pendingStaking();
        vm.assume(staking > 0);

        _stakeAs(botAddr, bot);
        vm.prank(botAddr);
        hook.sweep();
        vm.prank(botAddr);
        vault.exit();

        assertEq(_imdBalance(botAddr), 0, "zero blocks staked earns nothing through the real sweep");
        assertEq(token.balanceOf(botAddr), bot);
        vm.roll(vm.getBlockNumber() + vault.REWARD_DURATION());
        assertLe(vault.earned(alice), staking);
        assertGe(vault.earned(alice) + 2, staking, "the incumbent gets the whole distribution");
    }

    /// @notice A bot that sweeps right before staking a bag 99 times the incumbent's and holds it one block gets one
    /// block of the window (under 0.014% of the backlog), nothing like the fees accrued before it came.
    function test_sweepThenStakeOneBlockCapturesOneWindowBlockOnly() public {
        address alice = makeAddr("alice");
        address botAddr = makeAddr("bot");
        uint256 D = vault.REWARD_DURATION();
        _stakeAs(alice, 100 ether);
        vm.roll(hook.poolOpenBlock() + 10);
        _buy(-5_000 ether, 0); // the fee the bot would like to take
        uint256 earlier = hook.pendingStaking();
        vm.roll(vm.getBlockNumber() + 1_000);

        vm.prank(botAddr);
        hook.sweep();
        _stakeAs(botAddr, 9_900 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(botAddr);
        vault.exit();

        assertApproxEqAbs(_imdBalance(botAddr), earlier / D * 99 / 100, 2, "99% of one block of the window");
        assertLt(_imdBalance(botAddr), earlier / 7_000, "nothing like the backlog");
        vm.roll(vm.getBlockNumber() + D);
        assertApproxEqAbs(vault.earned(alice) + _imdBalance(botAddr), earlier, 2, "conservation");
    }

    function test_stakeOneBlockBeforeSweepAndExitInItEarnsNothing() public {
        address alice = makeAddr("alice");
        address botAddr = makeAddr("bot");
        uint256 open = hook.poolOpenBlock();
        _stakeAs(alice, 100 ether);
        vm.roll(open + 10);
        _buy(-5_000 ether, 0);
        uint256 staking = hook.pendingStaking();
        vm.roll(open + 999);
        _stakeAs(botAddr, 100_000 ether);
        vm.roll(open + 1_000);
        hook.sweep();
        vm.prank(botAddr);
        vault.exit();
        assertEq(_imdBalance(botAddr), 0, "the block before the sweep streamed nothing");
        vm.roll(vm.getBlockNumber() + vault.REWARD_DURATION());
        assertApproxEqAbs(vault.earned(alice), staking, 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: the reservation never under-collects and the refund never over-pays
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 600
    function testFuzz_specifiedSideReservationBoundsTheFee(uint256 amount, bool exactIn, uint8 blocks, uint16 limitBps)
        public
    {
        amount = bound(amount, 1, 50_000 ether);
        vm.roll(hook.poolOpenBlock() + bound(uint256(blocks), 0, 12));
        uint256 rate = hook.feeBps();
        uint160 price = _sqrtPrice();
        uint256 cut = bound(uint256(limitBps), 1, 5_000);
        bool isBuy = exactIn; // exact-input buy and exact-output sell are the two specified-side kinds
        bool zeroForOne = isBuy == imdIsCurrency0;
        uint160 limit = zeroForOne ? uint160(price - price * cut / 10_000) : uint160(price + price * cut / 10_000);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        int256 specified = exactIn ? -int256(amount) : int256(amount);

        int256 walletBefore = int256(_imdBalance(address(this)));
        if (isBuy) _buy(specified, limit);
        else _sell(specified, limit);
        int256 walletChange = int256(_imdBalance(address(this))) - walletBefore;

        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = _routerRefund();
        int256 poolImd = isBuy ? -walletChange - int256(fee + refund) : walletChange + int256(fee + refund);
        assertGe(poolImd, 0);
        assertEq(fee, uint256(poolImd) * rate / BPS, "fee == rate x fill");
        assertEq(hook.pending(), fee);
        // Reservation (fee + refund) never exceeds the rate on the requested amount by more than rounding.
        uint256 maxReserved = exactIn
            ? (amount * rate + (BPS + rate) - 1) / (BPS + rate)
            : (amount * rate + (BPS - rate) - 1) / (BPS - rate);
        assertEq(fee + refund, maxReserved, "reservation is the closed-form amount");
        assertEq(_imdBalance(address(hook)), 0);
        assertEq(manager.balanceOf(address(swapRouter), IMD_ID), 0, "a funded manager refunds in IMD, not claims");
    }
}

/// @notice Launch-like pool (tokens only above the opening price): swaps that cannot fill must not revert or accrue,
/// and refunds the manager cannot cover in IMD are claims.
contract SpongeBotHookEdgesTokenOnlyTest is HookTestBase {
    function _poolManager() internal override returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(this))));
    }

    function _fundImd(address to, uint256 amount) internal override {
        MockERC20(IMD).mint(to, amount);
    }

    function setUp() public {
        vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        vm.roll(1_000);
        _setUpPool(false);
    }

    function test_exactInputSellIntoEmptySideFillsNothingAndChargesNothing() public {
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price + price / 100 : price - price / 100;
        uint256 imdBefore = _imdBalance(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        _sell(-100 ether, limit);
        assertEq(_imdBalance(address(this)), imdBefore, "no IMD came out");
        assertEq(token.balanceOf(address(this)), tokenBefore, "no tokens went in");
        assertEq(hook.pending(), 0);
        assertEq(_routerRefund(), 0);
    }

    function test_exactOutputSellIntoEmptySideRefundsTheWholeReservationAsClaim() public {
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price + price / 100 : price - price / 100;
        int256 walletBefore = int256(_imdBalance(address(this)));
        vm.expectEmit(true, false, false, false, address(hook));
        emit SpongeBotHook.Refunded(address(swapRouter), 0, true);
        _sell(int256(100 ether), limit);
        int256 walletChange = int256(_imdBalance(address(this))) - walletBefore;
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        // Nothing filled: no fee accrues, and the reservation comes back in full as a claim (the manager holds no
        // IMD yet) to the sender.
        assertEq(hook.pending(), 0);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 0);
        assertEq(walletChange + int256(refund), 0, "net zero for the swapper");
        assertGt(refund, 0);
        assertEq(_imdBalance(address(swapRouter)), 0);
    }

    function test_firstBuyThenSellThenSweepOnLaunchLikePool() public {
        _buy(-1_000 ether, 0);
        vm.roll(hook.poolOpenBlock() + 3);
        uint256 imdBefore = _imdBalance(address(this));
        _sell(-100 ether, 0);
        assertGt(_imdBalance(address(this)), imdBefore, "the buy's IMD backs the sell");
        uint256 anti = hook.pendingAntiSnipe();
        uint256 staking = hook.pendingStaking();
        hook.sweep();
        assertEq(_imdBalance(hook.HACKATHON_VAULT()), anti);
        assertEq(_imdBalance(address(vault)), staking);
        assertGe(_imdBalance(address(manager)), manager.balanceOf(address(swapRouter), IMD_ID), "claims stay backed");
    }

    /// @notice On the first partial-fill buy the manager has no IMD, so the refund is a claim; once the pool holds
    /// IMD the next one is a transfer. Both paths pay exactly the rate on what filled.
    function test_refundPathSwitchesFromClaimToTransferAsTheManagerFills() public {
        uint256 rate = hook.feeBps();
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price - price / 100 : price + price / 100;
        uint256 walletBefore = _imdBalance(address(this));
        _buy(-10_000 ether, limit);
        uint256 claim = manager.balanceOf(address(swapRouter), IMD_ID);
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        assertGt(claim, 0, "first refund is a claim");
        assertEq(_imdBalance(address(swapRouter)), 0);
        uint256 poolImd = walletBefore - _imdBalance(address(this)) - fee - claim;
        assertEq(fee, poolImd * rate / BPS_());

        price = _sqrtPrice();
        limit = imdIsCurrency0 ? price - price / 100 : price + price / 100;
        walletBefore = _imdBalance(address(this));
        _buy(-10_000 ether, limit);
        uint256 transferred = _imdBalance(address(swapRouter));
        assertGt(transferred, 0, "second refund is an IMD transfer");
        assertEq(manager.balanceOf(address(swapRouter), IMD_ID), claim, "no new claim");
        uint256 fee2 = manager.balanceOf(address(hook), IMD_ID) - fee;
        uint256 poolImd2 = walletBefore - _imdBalance(address(this)) - fee2 - transferred;
        assertEq(fee2, poolImd2 * rate / BPS_());
        assertGe(_imdBalance(address(manager)), claim + fee + fee2, "claims stay backed");
    }

    function BPS_() internal pure returns (uint256) {
        return 10_000;
    }
}
