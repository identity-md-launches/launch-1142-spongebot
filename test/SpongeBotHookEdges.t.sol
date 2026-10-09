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

/// @dev A router that tries to run `sweep()` from inside its own unlock: the hook must not be sweepable mid-swap.
contract ReentrantSweeper is IUnlockCallback {
    IPoolManager immutable manager;
    SpongeBotHook immutable hook;

    constructor(IPoolManager manager_, SpongeBotHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function run() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        hook.sweep();
        return "";
    }
}

/// @notice Adversarial edge cases for the hook on a fresh PoolManager: dust, zero fills, exact revert data, block
/// boundaries, events, claim redemption, reentrancy and misuse.
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
        assertEq(manager.balanceOf(address(swapRouter), IMD_ID), 1, "whole reservation refunded");
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
        assertEq(manager.balanceOf(address(swapRouter), IMD_ID), 1);
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
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        uint256 poolImd = paid - fee - refund;
        assertLt(poolImd, 1e24, "only a sliver filled");
        assertEq(fee, poolImd * rate / BPS, "fee on the fill only");
        assertEq(paid - refund, poolImd + fee, "net cost is fill plus fee");
    }

    function test_unspecifiedSideFeeNeverExceedsRateOnHugeFill() public {
        // Exact-input sell of a large token amount: IMD out is unspecified, fee from the real delta.
        uint256 rate = hook.feeBps();
        uint256 imdBefore = _imdBalance(address(this));
        _sell(-int256(uint256(500_000 ether)), 0);
        uint256 received = _imdBalance(address(this)) - imdBefore;
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        assertEq(fee, (received + fee) * rate / BPS);
        assertEq(manager.balanceOf(address(swapRouter), IMD_ID), 0);
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

    function test_feeAccruedEventReportsRefundOnPartialFill() public {
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price - price / 10_000 : price + price / 10_000;
        uint256 snap = vm.snapshotState();
        _buy(-int256(uint256(10_000 ether)), limit);
        uint256 anti = hook.pendingAntiSnipe();
        uint256 staking = hook.pendingStaking();
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        assertGt(refund, 0);
        vm.revertToState(snap);

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
    // Refund claim: redeemable by a swapper that is its own router, and usable to pay the next swap
    // ---------------------------------------------------------------------------------------------

    function test_refundClaimIsRedeemableBySelfRoutingSwapper() public {
        ClaimRouter router = new ClaimRouter(manager);
        router.setUseClaims(false); // keep the claim instead of burning it on the spot
        uint256 amountIn = 10_000 ether;
        IERC20Minimal(IMD).transfer(address(router), amountIn);
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price - price / 10_000 : price + price / 10_000;
        uint256 tokenBefore = token.balanceOf(address(this));

        router.swap(key, SwapParams(imdIsCurrency0, -int256(amountIn), limit));

        uint256 refund = manager.balanceOf(address(router), IMD_ID);
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        assertGt(refund, fee, "most of the reservation came back as a claim to the sender");
        assertEq(manager.balanceOf(address(swapRouter), IMD_ID), 0, "nothing to the uninvolved test router");
        assertGt(token.balanceOf(address(this)), tokenBefore, "owner received the tokens");

        uint256 imdBefore = _imdBalance(address(this));
        uint256 redeemed = router.redeem(Currency.wrap(IMD));
        assertEq(redeemed, refund);
        assertEq(_imdBalance(address(this)) - imdBefore, refund, "claim redeemed to real IMD");
        assertEq(manager.balanceOf(address(router), IMD_ID), 0);
    }

    function test_selfRoutingSwapperBurnsTheRefundInsideTheSameSwap() public {
        ClaimRouter router = new ClaimRouter(manager);
        uint256 rate = hook.feeBps();
        IERC20Minimal(IMD).transfer(address(router), 10_000 ether);
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price - price / 10_000 : price + price / 10_000;
        uint256 routerImd = _imdBalance(address(router));

        router.swap(key, SwapParams(imdIsCurrency0, -int256(uint256(10_000 ether)), limit));

        uint256 paid = routerImd - _imdBalance(address(router));
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        assertEq(manager.balanceOf(address(router), IMD_ID), 0, "refund already spent on the settlement");
        uint256 poolImd = paid - fee;
        assertEq(fee, poolImd * rate / BPS, "fee on the fill only");
        assertLt(paid, 10_000 ether / 10, "a partial fill costs a fraction of the request");
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

    function test_sweepCannotRunInsideAnotherUnlock() public {
        _buy(-100 ether, 0);
        uint256 pendingBefore = hook.pending();
        ReentrantSweeper sweeper = new ReentrantSweeper(manager, hook);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        sweeper.run();
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
        assertEq(vault.queuedRewards(), staking1 + staking2);
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

    function test_hookDataIsIgnored() public {
        uint256 snap = vm.snapshotState();
        _buy(-100 ether, 0);
        uint256 feePlain = manager.balanceOf(address(hook), IMD_ID);
        vm.revertToState(snap);
        swapRouter.swap(
            key,
            SwapParams(
                imdIsCurrency0, -100 ether, imdIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            hex"deadbeef00000000000000000000000000000000000000000000000000000001"
        );
        assertEq(manager.balanceOf(address(hook), IMD_ID), feePlain);
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
        vm.expectRevert(SpongeBotHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1 ether), uint256(1 ether)));
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

    function test_rewardsReachMultipleStakersProRataAfterSweep() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        token.transfer(alice, 300 ether);
        token.transfer(bob, 100 ether);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.stake(300 ether);
        vm.stopPrank();
        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vault.stake(100 ether);
        vm.stopPrank();

        _buy(-1_000 ether, 0);
        uint256 staking = hook.pendingStaking();
        hook.sweep();
        assertEq(vault.earned(alice) + vault.earned(bob), 0, "no stake-blocks yet: queued, not distributed");
        assertEq(vault.queuedRewards(), staking);
        vm.roll(vm.getBlockNumber() + 7);
        _buy(-1 ether, 0);
        uint256 total = staking + hook.pendingStaking();
        hook.sweep();
        // 400 ether x 7 blocks = 2800e18 stake-blocks: the floored rate leaves under 2800 wei re-queued.
        assertApproxEqAbs(vault.earned(alice), total * 3 / 4, 3_000);
        assertApproxEqAbs(vault.earned(bob), total / 4, 3_000);
        assertLe(vault.earned(alice) + vault.earned(bob) + vault.queuedRewards(), total, "never owes more than swept");
    }

    // ---------------------------------------------------------------------------------------------
    // Staking rewards are time-weighted through the real sweep (the reopened finding)
    // ---------------------------------------------------------------------------------------------

    function _stakeAs(address who, uint256 amount) internal {
        token.transfer(who, amount);
        vm.startPrank(who);
        token.approve(address(vault), type(uint256).max);
        vault.stake(amount);
        vm.stopPrank();
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
        assertLe(vault.earned(alice) + vault.queuedRewards(), staking);
        assertGe(vault.earned(alice) + vault.queuedRewards() + 1, staking);
    }

    /// @notice A bot that first resets the epoch with a dust swap plus sweep, then stakes a large bag, only earns its
    /// stake-share of fees generated while it was staked; everything accrued before went to the incumbent.
    function test_dustSweepResetBeforeStakingCannotCaptureEarlierFees() public {
        address alice = makeAddr("alice");
        address botAddr = makeAddr("bot");
        _stakeAs(alice, 100 ether);
        vm.roll(hook.poolOpenBlock() + 10);
        _buy(-5_000 ether, 0); // the fee the bot would like to take
        uint256 earlier = hook.pendingStaking();
        vm.roll(vm.getBlockNumber() + 1_000);

        // Reset: a dust buy so sweep() has something to move, then the sweep closes the epoch to alice alone.
        _buy(-1e15, 0);
        vm.prank(botAddr);
        hook.sweep();
        assertGe(vault.earned(alice) + vault.queuedRewards(), earlier, "the incumbent got everything accrued so far");
        assertEq(vault.currentTotalPoints(), 0, "stake-blocks reset");

        _stakeAs(botAddr, 9_900 ether);
        vm.roll(vm.getBlockNumber() + 1);
        _buy(-1e15, 0); // a dust fee is all that accrues while the bot is staked
        uint256 later = hook.pendingStaking() + vault.queuedRewards();
        vm.prank(botAddr);
        hook.sweep();
        vm.prank(botAddr);
        vault.exit();

        assertLe(_imdBalance(botAddr), later * 99 / 100 + 1, "at most its stake-share of the later dust");
        assertLt(_imdBalance(botAddr), earlier / 1_000_000, "nothing of the earlier fee");
        assertGe(vault.earned(alice), earlier - 1);
    }

    function test_oneBlockStakeThroughSweepEarnsOneBlockShare() public {
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
        // alice: 100 x 1000 = 100_000 stake-blocks; bot: 100_000 x 1 = 100_000. An even split.
        hook.sweep();
        vm.prank(botAddr);
        vault.exit();
        // The rate floors over 200_000e18 stake-blocks: under 200_000 wei is re-queued, not paid.
        assertApproxEqAbs(_imdBalance(botAddr), staking / 2, 200_001);
        assertApproxEqAbs(vault.earned(alice), staking / 2, 200_001);
        assertEq(_imdBalance(botAddr) + vault.earned(alice) + vault.queuedRewards(), staking, "exact conservation");
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
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
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
    }
}

/// @notice Launch-like pool (tokens only above the opening price): swaps that cannot fill must not revert or accrue.
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
        assertEq(manager.balanceOf(address(swapRouter), IMD_ID), 0);
    }

    function test_exactOutputSellIntoEmptySideRefundsTheWholeReservation() public {
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price + price / 100 : price - price / 100;
        int256 walletBefore = int256(_imdBalance(address(this)));
        _sell(int256(100 ether), limit);
        int256 walletChange = int256(_imdBalance(address(this))) - walletBefore;
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        // Nothing filled: no fee accrues, and the reservation comes back in full as a claim to the sender.
        assertEq(hook.pending(), 0);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 0);
        assertEq(walletChange + int256(refund), 0, "net zero for the swapper");
        assertGt(refund, 0);
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
}
