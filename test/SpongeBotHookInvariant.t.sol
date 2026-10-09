// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {SPONGEBOT} from "../src/SPONGEBOT.sol";
import {SpongeBotHook} from "../src/SpongeBotHook.sol";
import {SpongeBotVault} from "../src/SpongeBotVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookTestBase} from "./utils/HookTestBase.sol";

/// @notice Drives the real PoolManager with random swaps of every kind, block advances, sweeps and staking, and
/// records what every swap charged so the invariants can compare the hook's books with the chain's.
contract HookHandler is Test {
    using StateLibrary for IPoolManager;

    uint256 constant BPS = 10_000;

    IPoolManager immutable manager;
    SPONGEBOT immutable token;
    SpongeBotHook immutable hook;
    SpongeBotVault immutable vault;
    PoolSwapTest immutable router;
    PoolId immutable poolId;
    address immutable imd;
    uint256 immutable imdId;
    bool immutable imdIsCurrency0;
    PoolKey key;
    address[] actors;

    // Ghost accounting
    uint256 public totalFeeAccrued;
    uint256 public totalPoolImd;
    uint256 public antiSwept;
    uint256 public stakingSwept;
    uint256 public claimed;
    uint256 public maxDust;
    uint256 public violations;
    uint256 public swaps;
    uint256 public partialFills;
    uint256 public sweeps;
    uint256 public tokensGivenToActors;

    constructor(
        IPoolManager manager_,
        SPONGEBOT token_,
        SpongeBotHook hook_,
        PoolSwapTest router_,
        PoolKey memory key_,
        bool imdIsCurrency0_,
        address[] memory actors_
    ) {
        manager = manager_;
        token = token_;
        hook = hook_;
        vault = hook_.vault();
        router = router_;
        key = key_;
        poolId = key_.toId();
        imd = hook_.PAIRED_CURRENCY();
        imdId = uint256(uint160(imd));
        imdIsCurrency0 = imdIsCurrency0_;
        actors = actors_;
        token.approve(address(router), type(uint256).max);
        IERC20Minimal(imd).approve(address(router), type(uint256).max);
        for (uint256 i = 0; i < actors_.length; i++) {
            vm.prank(actors_[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @param mode 0 exact-input buy, 1 exact-output buy, 2 exact-input sell, 3 exact-output sell
    /// @param limitBps 0 for no limit, else stop after this many bps of sqrt-price movement
    function swap(uint256 amount, uint8 mode, uint16 limitBps) external {
        amount = bound(amount, 1e9, 2_000 ether);
        mode %= 4;
        bool isBuy = mode < 2;
        bool exactIn = mode % 2 == 0;
        bool zeroForOne = isBuy == imdIsCurrency0;
        (uint160 price,,,) = manager.getSlot0(poolId);
        uint256 cut = bound(uint256(limitBps), 0, 2_000);
        uint160 limit;
        if (cut == 0) {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        } else {
            limit =
                zeroForOne ? uint160(price - uint256(price) * cut / BPS) : uint160(price + uint256(price) * cut / BPS);
            if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
            if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        }
        // Fund generously: exact-output costs are unknown in advance and a tiny exact-output sell fill can leave
        // the swapper owing IMD (see README "Known edge").
        MockERC20(imd).mint(address(this), amount * 4);

        uint256 rate = hook.feeBps();
        int256 walletBefore = int256(IERC20Minimal(imd).balanceOf(address(this)));
        uint256 hookClaimsBefore = manager.balanceOf(address(hook), imdId);
        uint256 routerClaimsBefore = manager.balanceOf(address(router), imdId);
        uint256 antiBefore = hook.pendingAntiSnipe();
        uint256 stakingBefore = hook.pendingStaking();

        router.swap(
            key,
            SwapParams(zeroForOne, exactIn ? -int256(amount) : int256(amount), limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        uint256 fee = manager.balanceOf(address(hook), imdId) - hookClaimsBefore;
        uint256 refund = manager.balanceOf(address(router), imdId) - routerClaimsBefore;
        int256 walletChange = int256(IERC20Minimal(imd).balanceOf(address(this))) - walletBefore;
        int256 poolImdSigned = isBuy ? -walletChange - int256(fee + refund) : walletChange + int256(fee + refund);
        if (poolImdSigned < 0) {
            violations++;
            return;
        }
        uint256 poolImd = uint256(poolImdSigned);
        if (fee != poolImd * rate / BPS) violations++;
        if (hook.pendingStaking() - stakingBefore != poolImd * 100 / BPS) violations++;
        if (hook.pendingAntiSnipe() - antiBefore != fee - poolImd * 100 / BPS) violations++;
        bool pairedSpecified = isBuy == exactIn;
        if (!pairedSpecified && refund != 0) violations++;
        if (cut == 0 && pairedSpecified && refund > 2) violations++;
        if (refund > 2) partialFills++;

        totalFeeAccrued += fee;
        totalPoolImd += poolImd;
        swaps++;
    }

    function roll(uint8 blocks) external {
        vm.roll(vm.getBlockNumber() + bound(uint256(blocks), 1, 4));
    }

    function sweep(uint256 seed) external {
        uint256 anti = hook.pendingAntiSnipe();
        uint256 staking = hook.pendingStaking();
        if (anti + staking == 0) {
            vm.prank(_actor(seed));
            (bool ok,) = address(hook).call(abi.encodeCall(SpongeBotHook.sweep, ()));
            if (ok) violations++;
            return;
        }
        uint256 pointsTotal = vault.currentTotalPoints();
        uint256 epochBefore = vault.currentEpoch();
        uint256 total = staking + vault.queuedRewards();
        vm.prank(_actor(seed));
        hook.sweep();
        antiSwept += anti;
        stakingSwept += staking;
        sweeps++;
        if (staking > 0) {
            // Replay the vault's own arithmetic: no stake-blocks queues everything; otherwise the epoch closes and
            // only the part the floored rate cannot represent is re-queued.
            if (pointsTotal == 0) {
                if (vault.queuedRewards() != total) violations++;
                if (vault.currentEpoch() != epochBefore) violations++;
            } else {
                uint256 rate = total * 1e18 / pointsTotal;
                uint256 distributed = (rate * pointsTotal + 1e18 - 1) / 1e18;
                if (vault.queuedRewards() != total - distributed) violations++;
                if (vault.currentEpoch() != epochBefore + 1) violations++;
                maxDust += 1;
            }
        } else if (vault.currentEpoch() != epochBefore) {
            violations++; // nothing notified: the vault must not have been touched
        }
        if (hook.pending() != 0) violations++;
    }

    /// @dev The reopened finding through the real hook: stake, sweep and exit in one block earns nothing.
    function flashStakeAroundSweep(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        if (vault.stakedBalance(who) != 0 || vault.points(who) != 0) return;
        if (hook.pendingStaking() == 0) return;
        amount = bound(amount, 1, 50_000 ether);
        if (token.balanceOf(address(this)) < amount + 1_000_000 ether) return;
        token.transfer(who, amount);
        tokensGivenToActors += amount;
        uint256 owedBefore = vault.earned(who);
        uint256 imdBefore = IERC20Minimal(imd).balanceOf(who);
        vm.prank(who);
        vault.stake(amount);
        this.sweep(seed);
        vm.prank(who);
        vault.exit();
        if (IERC20Minimal(imd).balanceOf(who) - imdBefore != owedBefore) violations++;
        claimed += owedBefore;
        maxDust += 3;
    }

    function stake(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 50_000 ether);
        if (token.balanceOf(address(this)) < amount + 1_000_000 ether) return;
        token.transfer(who, amount);
        tokensGivenToActors += amount;
        vm.prank(who);
        vault.stake(amount);
        maxDust += 1;
    }

    function unstake(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 staked = vault.stakedBalance(who);
        if (staked == 0) return;
        amount = bound(amount, 1, staked);
        vm.prank(who);
        vault.unstake(amount);
        maxDust += 1;
    }

    function claim(uint256 seed) external {
        address who = _actor(seed);
        uint256 expected = vault.earned(who);
        vm.prank(who);
        uint256 paid = vault.claim();
        if (paid != expected) violations++;
        claimed += paid;
        maxDust += 1;
    }
}

/// @notice Invariants over random swap / roll / sweep / stake sequences on a fresh PoolManager.
contract SpongeBotHookInvariantTest is HookTestBase {
    HookHandler handler;
    address[] actors;
    uint256 openBlock;

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
        openBlock = hook.poolOpenBlock();
        for (uint256 i = 0; i < 4; i++) {
            actors.push(makeAddr(string(abi.encodePacked("staker", i))));
        }
        handler = new HookHandler(manager, token, hook, swapRouter, key, imdIsCurrency0, actors);
        token.transfer(address(handler), 5e26);
        targetContract(address(handler));
    }

    function _sumEarned() internal view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += vault.earned(actors[i]);
        }
    }

    function _sumActorImd() internal view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += _imdBalance(actors[i]);
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_pendingEqualsClaimsHeld() public view {
        uint256 claims = manager.balanceOf(address(hook), IMD_ID);
        assertEq(hook.pending(), claims, "pending() is exactly the hook's IMD claim");
        assertEq(hook.pending(), hook.pendingAntiSnipe() + hook.pendingStaking());
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "never a claim on the token");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyFeeIsEitherPendingOrSwept() public view {
        assertEq(handler.totalFeeAccrued(), hook.pending() + handler.antiSwept() + handler.stakingSwept());
        assertEq(_imdBalance(hook.HACKATHON_VAULT()), handler.antiSwept(), "hackathon vault got exactly the anti-snipe");
        assertEq(
            _imdBalance(address(vault)), handler.stakingSwept() - handler.claimed(), "vault got exactly the staking fee"
        );
        // The hook charged at most the opening rate on everything that moved through the pool.
        assertLe(handler.totalFeeAccrued(), handler.totalPoolImd() * 3_100 / 10_000 + handler.swaps());
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_hookHoldsNothingDirectlyAndClaimsAreBacked() public view {
        assertEq(_imdBalance(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        uint256 claims = manager.balanceOf(address(hook), IMD_ID) + manager.balanceOf(address(swapRouter), IMD_ID)
            + manager.balanceOf(address(handler), IMD_ID);
        assertGe(_imdBalance(address(manager)), claims, "manager holds the IMD behind every claim");
        // IMD never leaves the system: every unit minted is in a wallet, the manager, or a vault.
        uint256 supply = MockERC20(IMD).totalSupply();
        uint256 located = _imdBalance(address(this)) + _imdBalance(address(handler)) + _imdBalance(address(manager))
            + _imdBalance(hook.HACKATHON_VAULT()) + _imdBalance(address(vault)) + _sumActorImd();
        assertEq(located, supply, "IMD conservation");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_vaultOwesNoMoreThanItHolds() public view {
        uint256 owed = _sumEarned() + vault.queuedRewards();
        assertGe(_imdBalance(address(vault)), owed);
        assertLe(handler.stakingSwept() - handler.claimed() - owed, handler.maxDust(), "only rounding dust unassigned");
        assertEq(token.balanceOf(address(vault)), vault.totalStaked());
        assertEq(token.totalSupply(), 1e27);
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feeScheduleFollowsTheBlock() public view {
        uint256 elapsed = block.number - openBlock;
        uint256 expected = elapsed >= 10 ? 0 : 3_000 * (10 - elapsed) / 10;
        assertEq(hook.antiSnipeBps(), expected);
        assertEq(hook.feeBps(), expected + 100);
        assertEq(hook.poolOpenBlock(), openBlock, "the opening block never changes");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_handlerSawNoViolation() public view {
        assertEq(handler.violations(), 0, "a per-swap or per-sweep property failed inside the handler");
    }
}
