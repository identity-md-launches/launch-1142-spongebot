// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SPONGEBOT} from "../src/SPONGEBOT.sol";
import {SpongeBotVault} from "../src/SpongeBotVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Random stake / unstake / claim / exit / notify / donate / roll / flash-stake sequences from several actors,
/// with the handler standing in for the hook and keeping an exact model of the vault's queue.
contract VaultHandler is Test {
    uint256 constant PRECISION = 1e18;

    SPONGEBOT public immutable token;
    MockERC20 public immutable imd;
    SpongeBotVault public immutable vault;
    address[] public actors;

    // Ghost accounting
    uint256 public totalNotified;
    uint256 public totalDonated;
    uint256 public totalClaimed;
    uint256 public distributions;
    uint256 public settlements;
    uint256 public expectedQueued;
    uint256 public lastEpoch;
    uint256 public lastCumulativeRate;
    uint256 public violations;
    uint256 public calls;
    mapping(address => uint256) public netStaked;

    constructor(SPONGEBOT token_, MockERC20 imd_, SpongeBotVault vault_, address[] memory actors_) {
        token = token_;
        imd = imd_;
        vault = vault_;
        actors = actors_;
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

    function _cumulativeRate() internal view returns (uint256 cumulative) {
        (, cumulative,) = vault.epochs(vault.currentEpoch());
    }

    function _track() internal {
        calls++;
        uint256 epoch = vault.currentEpoch();
        uint256 cumulative = _cumulativeRate();
        if (epoch < lastEpoch) violations++;
        if (cumulative < lastCumulativeRate) violations++;
        if (vault.queuedRewards() != expectedQueued) violations++;
        if (vault.lastUpdateBlock() > block.number) violations++;
        lastEpoch = epoch;
        lastCumulativeRate = cumulative;
    }

    function roll(uint8 blocks) external {
        vm.roll(vm.getBlockNumber() + bound(uint256(blocks), 1, 20));
        _track();
    }

    function stake(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1, 10_000 ether);
        if (token.balanceOf(address(this)) < amount) return;
        token.transfer(who, amount);
        uint256 earnedBefore = vault.earned(who);
        vm.prank(who);
        vault.stake(amount);
        if (vault.earned(who) != earnedBefore) violations++; // staking must not change what is already earned
        netStaked[who] += amount;
        settlements++;
        _track();
    }

    function unstake(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 staked = vault.stakedBalance(who);
        if (staked == 0) return;
        amount = bound(amount, 1, staked);
        uint256 earnedBefore = vault.earned(who);
        uint256 pointsBefore = vault.points(who);
        vm.prank(who);
        vault.unstake(amount);
        if (vault.earned(who) != earnedBefore) violations++; // unstaking keeps earned rewards
        if (vault.points(who) != pointsBefore) violations++; // and the stake-blocks accrued so far
        netStaked[who] -= amount;
        settlements++;
        _track();
    }

    function claim(uint256 seed) external {
        address who = _actor(seed);
        uint256 expected = vault.earned(who);
        uint256 before = imd.balanceOf(who);
        vm.prank(who);
        uint256 paid = vault.claim();
        if (paid != expected || imd.balanceOf(who) - before != paid) violations++;
        if (vault.earned(who) != 0) violations++;
        totalClaimed += paid;
        settlements++;
        _track();
    }

    function exit(uint256 seed) external {
        address who = _actor(seed);
        uint256 expected = vault.earned(who);
        uint256 staked = vault.stakedBalance(who);
        uint256 tokenBefore = token.balanceOf(who);
        uint256 before = imd.balanceOf(who);
        vm.prank(who);
        vault.exit();
        if (imd.balanceOf(who) - before != expected) violations++;
        if (token.balanceOf(who) - tokenBefore != staked) violations++;
        if (vault.stakedBalance(who) != 0 || vault.earned(who) != 0) violations++;
        totalClaimed += expected;
        netStaked[who] = 0;
        settlements += 2;
        _track();
    }

    /// @dev What the hook does in sweep(): transfer, then notify. Replays the vault's own arithmetic on the model.
    function notify(uint256 amount) external {
        amount = bound(amount, 0, 100_000 ether);
        imd.mint(address(vault), amount);
        uint256 pointsTotal = vault.currentTotalPoints();
        uint256 epochBefore = vault.currentEpoch();
        uint256 total = amount + expectedQueued;
        vault.notifyReward(amount);
        totalNotified += amount;
        if (pointsTotal == 0) {
            expectedQueued = total;
            if (vault.currentEpoch() != epochBefore) violations++;
        } else {
            uint256 rate = total * PRECISION / pointsTotal;
            uint256 distributed = (rate * pointsTotal + PRECISION - 1) / PRECISION;
            expectedQueued = total - distributed;
            distributions++;
            if (vault.currentEpoch() != epochBefore + 1) violations++;
            if (vault.currentTotalPoints() != 0) violations++;
        }
        _track();
    }

    /// @dev Stake, notify and exit in one block from an account with no open-epoch stake-blocks: must earn nothing.
    function flashStake(uint256 seed, uint256 amount, uint256 reward) external {
        address who = _actor(seed);
        if (vault.stakedBalance(who) != 0 || vault.points(who) != 0) return;
        amount = bound(amount, 1, 10_000 ether);
        if (token.balanceOf(address(this)) < amount) return;
        reward = bound(reward, 0, 100_000 ether);
        token.transfer(who, amount);
        uint256 owedBefore = vault.earned(who);
        uint256 imdBefore = imd.balanceOf(who);
        vm.startPrank(who);
        vault.stake(amount);
        vm.stopPrank();
        this.notify(reward);
        vm.prank(who);
        vault.exit();
        if (imd.balanceOf(who) - imdBefore != owedBefore) violations++; // nothing from this distribution
        if (token.balanceOf(who) < amount) violations++;
        totalClaimed += owedBefore;
        settlements += 3;
        _track();
    }

    /// @dev IMD sent without a notification: must never be distributed or break accounting.
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        imd.mint(address(vault), amount);
        totalDonated += amount;
        _track();
    }

    function intruderCannotNotify(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        vm.prank(who);
        (bool ok,) = address(vault).call(abi.encodeCall(SpongeBotVault.notifyReward, (amount)));
        if (ok) violations++;
        _track();
    }

    function intruderCannotUnstakeOthers(uint256 seed, uint256 victimSeed) external {
        address who = _actor(seed);
        address victim = _actor(victimSeed);
        if (who == victim) return;
        uint256 victimStake = vault.stakedBalance(victim);
        uint256 ownStake = vault.stakedBalance(who);
        if (victimStake <= ownStake) return;
        vm.prank(who);
        (bool ok,) = address(vault).call(abi.encodeCall(SpongeBotVault.unstake, (victimStake)));
        if (ok) violations++;
        _track();
    }
}

contract SpongeBotVaultInvariantTest is Test {
    SPONGEBOT token;
    MockERC20 imd;
    SpongeBotVault vault;
    VaultHandler handler;
    address[] actors;

    function setUp() public {
        vm.roll(1_000);
        token = new SPONGEBOT();
        imd = new MockERC20("IMD", "IMD", 0);
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
        // The handler plays the hook: it is the only notifier. It is deployed right after the vault, so its
        // address is this contract's next-but-one CREATE address.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vault = new SpongeBotVault(address(token), address(imd), predicted);
        handler = new VaultHandler(token, imd, vault, actors);
        assertEq(vault.hook(), address(handler), "handler is the vault's hook");
        token.transfer(address(handler), 1e26);
        targetContract(address(handler));
    }

    function _sumStaked() internal view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += vault.stakedBalance(actors[i]);
        }
    }

    function _sumEarned() internal view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += vault.earned(actors[i]);
        }
    }

    function _sumPoints() internal view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += vault.points(actors[i]);
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_stakedTokensAreExactlyAccounted() public view {
        assertEq(token.balanceOf(address(vault)), vault.totalStaked(), "vault holds exactly the total stake");
        assertEq(_sumStaked(), vault.totalStaked(), "total is the sum of balances");
        for (uint256 i = 0; i < actors.length; i++) {
            assertEq(vault.stakedBalance(actors[i]), handler.netStaked(actors[i]), "per-actor stake");
        }
        assertEq(token.totalSupply(), 1e27, "supply fixed");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_rewardsAreConservedUpToRoundingDust() public view {
        uint256 owed = _sumEarned() + vault.queuedRewards();
        uint256 inVault = imd.balanceOf(address(vault));
        assertGe(inVault, owed, "vault can always pay what it owes");
        assertEq(inVault, handler.totalNotified() + handler.totalDonated() - handler.totalClaimed(), "balance ledger");
        uint256 accounted = owed + handler.totalClaimed();
        assertLe(accounted, handler.totalNotified(), "never owes more than was notified");
        // One wei per distribution (the ceiling of the booked amount) plus one wei per settlement (each floors).
        assertLe(
            handler.totalNotified() - accounted,
            handler.distributions() + handler.settlements(),
            "only rounding dust is lost"
        );
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_stakeBlocksSumAcrossStakers() public view {
        // The open epoch's total stake-blocks are exactly the sum of every staker's, so nobody is weighted twice.
        assertEq(_sumPoints(), vault.currentTotalPoints(), "stake-blocks sum");
        assertEq(vault.queuedRewards(), handler.expectedQueued(), "queue matches the model");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_handlerSawNoViolation() public view {
        assertEq(handler.violations(), 0, "a per-call property failed inside the handler");
    }
}
