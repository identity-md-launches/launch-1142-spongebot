// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {SpongeBotHook} from "../src/SpongeBotHook.sol";
import {SpongeBotVault} from "../src/SpongeBotVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";

/// @notice Hook tests against a fresh local PoolManager with a mock ERC-20 standing in at IMD's address.
contract SpongeBotHookTest is HookTestBase {
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

    // ---------------------------------------------------------------------------------------------
    // Deployment, permissions, initialization
    // ---------------------------------------------------------------------------------------------

    function test_immutablesAndConstants() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
        assertEq(address(hook.vault()), address(vault));
        assertEq(address(vault.stakingToken()), address(token));
        assertEq(address(vault.rewardToken()), IMD);
        assertEq(vault.hook(), address(hook));
        assertEq(hook.PAIRED_CURRENCY(), IMD);
        assertEq(hook.HACKATHON_VAULT(), 0x3dD5F73dD1A4E62630fAd3909673F130aD429985);
        assertEq(hook.poolOpenBlock(), 1_000);
    }

    function test_creationCodeWithinEip3860Limit() public pure {
        assertLe(type(SpongeBotHook).creationCode.length + 64, 49_152);
    }

    function test_permissionBitsMatchAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        uint160 implemented = 0;
        if (p.beforeInitialize) implemented |= HookFlags.BEFORE_INITIALIZE;
        if (p.afterInitialize) implemented |= HookFlags.AFTER_INITIALIZE;
        if (p.beforeAddLiquidity) implemented |= HookFlags.BEFORE_ADD_LIQUIDITY;
        if (p.afterAddLiquidity) implemented |= HookFlags.AFTER_ADD_LIQUIDITY;
        if (p.beforeRemoveLiquidity) implemented |= HookFlags.BEFORE_REMOVE_LIQUIDITY;
        if (p.afterRemoveLiquidity) implemented |= HookFlags.AFTER_REMOVE_LIQUIDITY;
        if (p.beforeSwap) implemented |= HookFlags.BEFORE_SWAP;
        if (p.afterSwap) implemented |= HookFlags.AFTER_SWAP;
        if (p.beforeDonate) implemented |= HookFlags.BEFORE_DONATE;
        if (p.afterDonate) implemented |= HookFlags.AFTER_DONATE;
        if (p.beforeSwapReturnDelta) implemented |= HookFlags.BEFORE_SWAP_RETURN_DELTA;
        if (p.afterSwapReturnDelta) implemented |= HookFlags.AFTER_SWAP_RETURN_DELTA;
        if (p.afterAddLiquidityReturnDelta) implemented |= HookFlags.AFTER_ADD_LIQUIDITY_RETURN_DELTA;
        if (p.afterRemoveLiquidityReturnDelta) implemented |= HookFlags.AFTER_REMOVE_LIQUIDITY_RETURN_DELTA;
        assertEq(implemented, FLAGS);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        assertTrue(HookFlags.matches(address(hook), FLAGS));
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), POOL_FEE));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(SpongeBotHook.ZeroAddress.selector);
        new SpongeBotHook(IPoolManager(address(0)), address(token));
        vm.expectRevert(SpongeBotHook.ZeroAddress.selector);
        new SpongeBotHook(manager, address(0));
    }

    function test_callbacksRefuseNonPoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        vm.expectRevert(SpongeBotHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(SpongeBotHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(SpongeBotHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(SpongeBotHook.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_unlockCallbackRefusedOutsideSweep() public {
        vm.prank(address(manager));
        vm.expectRevert(SpongeBotHook.NotSweeping.selector);
        hook.unlockCallback(abi.encode(uint256(1), uint256(1)));
    }

    function test_secondPoolRefused() public {
        PoolKey memory other = key;
        other.fee = 3_000;
        vm.prank(FACTORY);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_wrongCurrenciesRefused() public {
        SpongeBotHook fresh = _deployHook(1_000_000);
        MockERC20 other = new MockERC20("X", "X", 0);
        (address c0, address c1) =
            address(other) < address(token) ? (address(other), address(token)) : (address(token), address(other));
        PoolKey memory wrong = PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, 60, IHooks(address(fresh)));
        vm.prank(FACTORY);
        vm.expectRevert();
        manager.initialize(wrong, SQRT_PRICE_1_1);
        assertEq(fresh.poolOpenBlock(), 0);
    }

    function test_dynamicFeeRefused() public {
        SpongeBotHook fresh = _deployHook(2_000_000);
        PoolKey memory dyn = key;
        dyn.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        dyn.hooks = IHooks(address(fresh));
        vm.prank(FACTORY);
        vm.expectRevert();
        manager.initialize(dyn, SQRT_PRICE_1_1);
    }

    function test_freshHookAcceptsLaunchPoolFromFactory() public {
        SpongeBotHook fresh = _deployHook(3_000_000);
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        vm.roll(2_000);
        vm.prank(FACTORY);
        manager.initialize(k, SQRT_PRICE_1_1);
        assertEq(fresh.poolOpenBlock(), 2_000);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee schedule
    // ---------------------------------------------------------------------------------------------

    function test_antiSnipeDecaysLinearlyOverTenBlocks() public {
        uint256 open = hook.poolOpenBlock();
        for (uint256 k = 0; k <= 12; k++) {
            vm.roll(open + k);
            uint256 expected = k >= 10 ? 0 : 3_000 * (10 - k) / 10;
            assertEq(hook.antiSnipeBps(), expected, "anti-snipe");
            assertEq(hook.feeBps(), expected + 100, "total");
        }
        assertEq(hook.feeBps(), 100);
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps: each direction and kind, full fills
    // ---------------------------------------------------------------------------------------------

    /// @dev Reads what the swap left behind and checks fee == rate x IMD-through-the-pool.
    function _assertFee(uint256 poolImd, uint256 rate, uint256 hookClaimsBefore, uint256 routerClaimsBefore)
        internal
        view
        returns (uint256 fee, uint256 refund)
    {
        fee = manager.balanceOf(address(hook), IMD_ID) - hookClaimsBefore;
        refund = manager.balanceOf(address(swapRouter), IMD_ID) - routerClaimsBefore;
        assertEq(fee, poolImd * rate / BPS, "fee is the rate on what moved through the pool");
        assertEq(hook.pending(), manager.balanceOf(address(hook), IMD_ID), "pending equals claims");
        assertEq(hook.pendingStaking(), poolImd * 100 / BPS, "staking share");
        assertEq(hook.pendingAntiSnipe(), fee - poolImd * 100 / BPS, "anti-snipe share");
    }

    function test_buyExactInputDuringAntiSnipe() public {
        uint256 rate = hook.feeBps();
        assertEq(rate, 3_100);
        uint256 amountIn = 1_000 ether;
        uint256 imdBefore = _imdBalance(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 managerBefore = _imdBalance(address(manager));

        BalanceDelta delta = _buy(-int256(amountIn), 0);

        assertEq(imdBefore - _imdBalance(address(this)), amountIn, "pays exactly the input");
        assertEq(_imdDelta(delta), -int256(amountIn));
        assertGt(token.balanceOf(address(this)) - tokenBefore, 0, "received tokens");
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        uint256 poolImd = amountIn - fee - refund;
        (uint256 f,) = _assertFee(poolImd, rate, 0, 0);
        assertApproxEqAbs(f, amountIn * 3_100 / 13_100, 2, "about 23.7% of gross, 31% of pool input");
        assertLe(refund, 1, "full fill refunds at most rounding dust");
        assertEq(_imdBalance(address(manager)) - managerBefore, amountIn, "manager holds it all");
    }

    function test_buyExactOutputDuringAntiSnipe() public {
        uint256 rate = hook.feeBps();
        uint256 amountOut = 500 ether;
        uint256 imdBefore = _imdBalance(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));

        BalanceDelta delta = _buy(int256(amountOut), 0);

        assertEq(token.balanceOf(address(this)) - tokenBefore, amountOut, "exact output");
        uint256 paid = imdBefore - _imdBalance(address(this));
        assertEq(uint256(uint128(-_imdDelta(delta))), paid);
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 poolImd = paid - fee;
        (, uint256 refund) = _assertFee(poolImd, rate, 0, 0);
        assertEq(refund, 0, "no reservation on the unspecified side");
    }

    function test_sellExactInputDuringAntiSnipe() public {
        uint256 rate = hook.feeBps();
        uint256 amountIn = 1_000 ether;
        uint256 imdBefore = _imdBalance(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));

        BalanceDelta delta = _sell(-int256(amountIn), 0);

        assertEq(tokenBefore - token.balanceOf(address(this)), amountIn, "exact input");
        uint256 received = _imdBalance(address(this)) - imdBefore;
        assertEq(uint256(uint128(_imdDelta(delta))), received);
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 poolImd = received + fee;
        (, uint256 refund) = _assertFee(poolImd, rate, 0, 0);
        assertEq(refund, 0);
    }

    function test_sellExactOutputDuringAntiSnipe() public {
        uint256 rate = hook.feeBps();
        uint256 amountOut = 500 ether;
        uint256 imdBefore = _imdBalance(address(this));

        BalanceDelta delta = _sell(int256(amountOut), 0);

        uint256 received = _imdBalance(address(this)) - imdBefore;
        assertEq(received, amountOut, "receives exactly the requested IMD");
        assertEq(uint256(uint128(_imdDelta(delta))), amountOut);
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        uint256 poolImd = amountOut + fee + refund;
        _assertFee(poolImd, rate, 0, 0);
        assertLe(refund, 1, "full fill refunds at most rounding dust");
    }

    function test_feesAfterAntiSnipeWindowAreOnePercent() public {
        vm.roll(hook.poolOpenBlock() + 10);
        assertEq(hook.feeBps(), 100);
        uint256 amountIn = 1_000 ether;
        _buy(-int256(amountIn), 0);
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        uint256 poolImd = amountIn - fee - refund;
        assertEq(fee, poolImd * 100 / BPS);
        assertEq(hook.pendingAntiSnipe(), 0);
        assertEq(hook.pendingStaking(), fee);
    }

    function test_feeAccumulatesAcrossSwapsAndBlocks() public {
        uint256 open = hook.poolOpenBlock();
        _buy(-100 ether, 0);
        vm.roll(open + 5);
        _sell(-100 ether, 0);
        vm.roll(open + 20);
        _buy(int256(10 ether), 0);
        _sell(int256(10 ether), 0);
        assertEq(hook.pending(), manager.balanceOf(address(hook), IMD_ID));
        assertGt(hook.pendingAntiSnipe(), 0);
        assertGt(hook.pendingStaking(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Partial fills with a price limit (specified-side reservation must reconcile)
    // ---------------------------------------------------------------------------------------------

    function test_buyExactInputPartialFillRefundsExcess() public {
        uint256 rate = hook.feeBps();
        uint256 amountIn = 10_000 ether;
        uint160 price = _sqrtPrice();
        // Stop after a 0.01% price move: only a fraction of the input fills.
        uint160 limit = imdIsCurrency0 ? price - price / 10_000 : price + price / 10_000;
        uint256 imdBefore = _imdBalance(address(this));

        _buy(-int256(amountIn), limit);

        assertEq(_sqrtPrice(), limit, "stopped at the limit");
        uint256 paid = imdBefore - _imdBalance(address(this));
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        uint256 reserved = fee + refund;
        uint256 poolImd = paid - reserved;
        assertLt(poolImd, amountIn / 10, "a small fraction filled");
        assertEq(fee, poolImd * rate / BPS, "fee on what filled only");
        assertGt(refund, fee, "most of the reservation came back");
        assertEq(paid - refund, poolImd + fee, "net cost is fill plus fee");
    }

    function test_sellExactOutputPartialFillRefundsExcess() public {
        vm.roll(hook.poolOpenBlock() + 10);
        uint256 rate = hook.feeBps();
        uint256 amountOut = 10_000 ether;
        uint160 price = _sqrtPrice();
        // Stop after a 0.1% price move: roughly a tenth of the request fills.
        uint160 limit = imdIsCurrency0 ? price + price / 1_000 : price - price / 1_000;
        uint256 imdBefore = _imdBalance(address(this));

        _sell(int256(amountOut), limit);

        assertEq(_sqrtPrice(), limit, "stopped at the limit");
        uint256 received = _imdBalance(address(this)) - imdBefore;
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        uint256 reserved = fee + refund;
        uint256 poolImd = received + reserved;
        assertLt(poolImd, amountOut / 2, "a fraction filled");
        assertEq(fee, poolImd * rate / BPS, "fee on what filled only");
        assertGt(refund, 0, "excess reservation refunded");
        assertEq(received + refund, poolImd - fee, "net proceeds are fill minus fee");
    }

    /// @dev An exact-output sell whose fill is smaller than the reservation leaves the swapper with a negative
    /// IMD delta in the manager and a larger IMD claim; the net is still fill minus fee. See README "Known edge".
    function test_sellExactOutputTinyFillNetsToFillMinusFee() public {
        uint256 rate = hook.feeBps();
        assertEq(rate, 3_100);
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price + price / 20_000 : price - price / 20_000;
        int256 imdBefore = int256(_imdBalance(address(this)));

        _sell(int256(10_000 ether), limit);

        int256 walletChange = int256(_imdBalance(address(this))) - imdBefore;
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        assertLt(walletChange, 0, "wallet paid the difference");
        int256 poolImd = walletChange + int256(fee + refund);
        assertGt(poolImd, 0);
        assertEq(fee, uint256(poolImd) * rate / BPS, "fee on what filled only");
        assertEq(walletChange + int256(refund), poolImd - int256(fee), "net proceeds are fill minus fee");
    }

    function test_unspecifiedSidePartialFillsNeedNoRefund() public {
        uint256 rate = hook.feeBps();
        uint160 price = _sqrtPrice();
        uint160 limit = imdIsCurrency0 ? price + price / 10_000 : price - price / 10_000;
        uint256 imdBefore = _imdBalance(address(this));
        _sell(-10_000 ether, limit);
        uint256 received = _imdBalance(address(this)) - imdBefore;
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        assertEq(fee, (received + fee) * rate / BPS);
        assertEq(manager.balanceOf(address(swapRouter), IMD_ID), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Accepted swap domain: overflow guard
    // ---------------------------------------------------------------------------------------------

    function test_unrepresentableFeeReverts() public {
        vm.expectRevert();
        _sell(type(int256).max, 0);
        vm.expectRevert();
        _buy(type(int256).min, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Sweep
    // ---------------------------------------------------------------------------------------------

    function test_sweepPaysBothVaultsAndNotifies() public {
        _buy(-1_000 ether, 0);
        vm.roll(hook.poolOpenBlock() + 3);
        _sell(-1_000 ether, 0);
        uint256 anti = hook.pendingAntiSnipe();
        uint256 staking = hook.pendingStaking();
        assertGt(anti, 0);
        assertGt(staking, 0);

        vm.prank(makeAddr("anyone"));
        vm.expectEmit(true, true, true, true);
        emit SpongeBotHook.Swept(anti, staking);
        hook.sweep();

        assertEq(_imdBalance(hook.HACKATHON_VAULT()), anti, "anti-snipe to hackathon vault");
        assertEq(_imdBalance(address(vault)), staking, "staking fee to vault");
        assertEq(vault.queuedRewards(), staking, "notified while nothing staked: queued");
        assertEq(hook.pending(), 0);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 0, "claims burned");

        vm.expectRevert(SpongeBotHook.NothingToSweep.selector);
        hook.sweep();
    }

    function test_sweptRewardsReachStakers() public {
        address alice = makeAddr("alice");
        token.transfer(alice, 100 ether);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.stake(100 ether);
        vm.stopPrank();

        vm.roll(hook.poolOpenBlock() + 10);
        _buy(-1_000 ether, 0);
        uint256 staking = hook.pendingStaking();
        hook.sweep();

        // Alice has 100 x 10 = 1000e18 stake-blocks; the rate's remainder (under 1000 wei) is queued, not lost.
        uint256 queued = vault.queuedRewards();
        assertLe(queued, 1_000);
        assertApproxEqAbs(vault.earned(alice) + queued, staking, 1);
        vm.prank(alice);
        vault.claim();
        assertApproxEqAbs(_imdBalance(alice) + queued, staking, 1);
    }

    /// @notice The reopened finding: staking in the sweep's block earns nothing from it; stake-time earns.
    function test_flashStakeAroundSweepEarnsNothing() public {
        address alice = makeAddr("alice");
        address bot = makeAddr("bot");
        token.transfer(alice, 100 ether);
        token.transfer(bot, 9_900 ether);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.stake(100 ether);
        vm.stopPrank();

        vm.roll(hook.poolOpenBlock() + 10);
        _buy(-1_000 ether, 0);
        uint256 staking = hook.pendingStaking();
        vm.roll(block.number + 100);

        // Stake, sweep, exit, all in one block.
        vm.startPrank(bot);
        token.approve(address(vault), type(uint256).max);
        vault.stake(9_900 ether);
        hook.sweep();
        vault.exit();
        vm.stopPrank();

        assertEq(_imdBalance(bot), 0, "zero blocks of stake earns nothing");
        assertEq(token.balanceOf(bot), 9_900 ether);
        assertApproxEqAbs(vault.earned(alice) + vault.queuedRewards(), staking, 1);
        assertGt(vault.earned(alice), staking * 99 / 100);
    }

    function test_sweepRevertsWhenNothingPending() public {
        vm.expectRevert(SpongeBotHook.NothingToSweep.selector);
        hook.sweep();
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: every fee is the rate on what filled, in every direction and kind
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 400
    function testFuzz_feeIsRateOnFilledAmount(uint256 amount, uint8 mode, uint8 blocksAfterOpen, bool limited) public {
        amount = bound(amount, 1e12, 5_000 ether);
        mode = mode % 4;
        vm.roll(hook.poolOpenBlock() + bound(uint256(blocksAfterOpen), 0, 15));
        uint256 rate = hook.feeBps();
        uint160 price = _sqrtPrice();
        bool isBuy = mode < 2;
        bool exactIn = mode % 2 == 0;
        uint160 limit = 0;
        if (limited) {
            bool zeroForOne = isBuy == imdIsCurrency0;
            limit = zeroForOne ? price - price / 20_000 : price + price / 20_000;
        }
        int256 specified = exactIn ? -int256(amount) : int256(amount);

        int256 imdBefore = int256(_imdBalance(address(this)));
        int256 managerBefore = int256(_imdBalance(address(manager)));
        if (isBuy) _buy(specified, limit);
        else _sell(specified, limit);

        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        // Wallet change is negative on buys, positive on sells, except a tiny exact-output sell fill (see README).
        int256 walletChange = int256(_imdBalance(address(this))) - imdBefore;
        int256 managerChange = int256(_imdBalance(address(manager))) - managerBefore;
        assertEq(managerChange, -walletChange, "conservation");
        // Pool-side IMD: what the swapper paid or received, corrected for the claims left in the manager.
        int256 poolImdSigned = isBuy ? -walletChange - int256(fee + refund) : walletChange + int256(fee + refund);
        assertGe(poolImdSigned, 0);
        uint256 poolImd = uint256(poolImdSigned);
        assertEq(fee, poolImd * rate / BPS, "fee == rate x pool IMD amount");
        assertEq(hook.pending(), fee);
        bool pairedSpecified = isBuy == exactIn;
        if (!pairedSpecified) assertEq(refund, 0, "no refund on the unspecified side");
        if (!limited && pairedSpecified) assertLe(refund, 2, "full fill leaves only rounding dust");
    }
}

/// @notice A launch-like pool: fresh manager seeded with SPONGEBOT only, no IMD inside the manager.
contract SpongeBotHookTokenOnlySeedTest is HookTestBase {
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

    function test_firstBuyOnTokenOnlyPoolSucceedsAndSweeps() public {
        assertEq(_imdBalance(address(manager)), 0, "no IMD in the manager before the first buy");
        uint256 rate = hook.feeBps();
        uint256 amountIn = 100 ether;
        _buy(-int256(amountIn), 0);
        uint256 fee = manager.balanceOf(address(hook), IMD_ID);
        uint256 refund = manager.balanceOf(address(swapRouter), IMD_ID);
        assertEq(fee, (amountIn - fee - refund) * rate / 10_000);
        assertGt(token.balanceOf(address(this)), 1e27 - 1_000_000 ether, "received tokens");

        uint256 anti = hook.pendingAntiSnipe();
        uint256 staking = hook.pendingStaking();
        hook.sweep();
        assertEq(_imdBalance(hook.HACKATHON_VAULT()), anti);
        assertEq(_imdBalance(address(vault)), staking);
        assertEq(anti + staking, fee);
    }

    function test_firstExactOutputBuyOnTokenOnlyPoolSucceeds() public {
        _buy(int256(10 ether), 0);
        assertGt(hook.pending(), 0);
        // A sell right after works too: the IMD the buy brought in backs the claims.
        _sell(-1 ether, 0);
        hook.sweep();
        assertEq(hook.pending(), 0);
    }
}
