// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SPONGEBOT} from "../src/SPONGEBOT.sol";
import {SpongeBotVault} from "../src/SpongeBotVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {QuirkyERC20} from "./mocks/QuirkyERC20.sol";

/// @notice Vault edge cases against the time-weighted (epoch) accumulator: empty claims, repeated calls, rounding at
/// the extremes, accounts that never interacted, lazy versus active settlement, odd tokens, donations, and the
/// flash-stake shapes the reopened finding described.
contract SpongeBotVaultEdgesTest is Test {
    uint256 constant PRECISION = 1e18;

    SPONGEBOT token;
    MockERC20 imd;
    SpongeBotVault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.roll(1_000);
        token = new SPONGEBOT();
        imd = new MockERC20("IMD", "IMD", 0);
        vault = new SpongeBotVault(address(token), address(imd), address(this));
        token.transfer(alice, 1_000 ether);
        token.transfer(bob, 1_000 ether);
        token.transfer(carol, 1_000 ether);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.prank(carol);
        token.approve(address(vault), type(uint256).max);
    }

    function _reward(uint256 amount) internal {
        imd.mint(address(vault), amount);
        vault.notifyReward(amount);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        vault.stake(amount);
    }

    function _roll(uint256 blocks) internal {
        vm.roll(vm.getBlockNumber() + blocks);
    }

    function _cumulativeRate() internal view returns (uint256 cumulative) {
        (, cumulative,) = vault.epochs(vault.currentEpoch());
    }

    // ---------------------------------------------------------------------------------------------
    // Repeated and empty calls
    // ---------------------------------------------------------------------------------------------

    function test_claimAndExitWithNothingStakedDoNothing() public {
        vm.startPrank(alice);
        assertEq(vault.claim(), 0);
        vault.exit();
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(imd.balanceOf(alice), 0);
        assertEq(vault.totalStaked(), 0);
    }

    function test_claimTwiceAndExitTwicePayNothingMore() public {
        _stake(alice, 10 ether);
        _roll(1);
        _reward(5 ether);
        vm.startPrank(alice);
        assertEq(vault.claim(), 5 ether);
        assertEq(vault.claim(), 0);
        vault.exit();
        vault.exit();
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), 5 ether);
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    function test_stakingAgainDoesNotForfeitOrDoubleCountRewards() public {
        _stake(alice, 100 ether);
        _roll(1);
        _reward(10 ether);
        _stake(alice, 100 ether);
        assertEq(vault.earned(alice), 10 ether, "earned carried over");
        _roll(1);
        _reward(10 ether);
        assertEq(vault.earned(alice), 20 ether);
    }

    function test_partialUnstakeThenRewardIsProRataOnTheRemainder() public {
        _stake(alice, 300 ether);
        _stake(bob, 100 ether);
        vm.prank(alice);
        vault.unstake(200 ether);
        _roll(1);
        _reward(20 ether);
        assertEq(vault.earned(alice), 10 ether);
        assertEq(vault.earned(bob), 10 ether);
    }

    function test_lateStakerEarnsNothingFromEarlierDistributions() public {
        _stake(alice, 100 ether);
        _roll(1);
        _reward(10 ether);
        _stake(bob, 1_000 ether);
        assertEq(vault.earned(bob), 0);
        assertEq(vault.earned(alice), 10 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Queue semantics
    // ---------------------------------------------------------------------------------------------

    function test_rewardsQueuedWhileEmptyGoToTheNextDistributionNotTheNextStakerAlone() public {
        _reward(9 ether);
        _stake(alice, 100 ether);
        _stake(bob, 200 ether);
        assertEq(vault.earned(alice), 0, "queued rewards wait for a notification");
        _roll(1);
        _reward(3 ether);
        assertEq(vault.earned(alice), 4 ether);
        assertEq(vault.earned(bob), 8 ether);
        assertEq(vault.queuedRewards(), 0);
    }

    function test_queueSurvivesStakersComingAndGoing() public {
        _reward(5 ether);
        _stake(alice, 10 ether);
        vm.prank(alice);
        vault.unstake(10 ether);
        assertEq(vault.queuedRewards(), 5 ether, "nobody was notified while staked");
        _reward(1 ether);
        assertEq(vault.queuedRewards(), 6 ether, "still empty: keeps queueing");
        _stake(bob, 1);
        _reward(0);
        assertEq(vault.queuedRewards(), 6 ether, "a stake with zero stake-blocks does not flush the queue");
        assertEq(vault.earned(bob), 0);
        _roll(1);
        _reward(0);
        assertEq(vault.earned(bob), 6 ether, "a zero notification with stake-blocks flushes the queue");
        assertEq(vault.queuedRewards(), 0);
    }

    /// @notice Documented behaviour, pinned: the first staker, however small, takes everything queued while the vault
    /// was empty, provided it is staked for at least one block. The spec keeps such rewards "for the next stakers".
    function test_firstStakerOfOneWeiTakesTheQueueAfterOneBlock() public {
        _reward(100 ether);
        _stake(alice, 1);
        _roll(1);
        _reward(0);
        assertEq(vault.earned(alice), 100 ether);
    }

    function test_notifyZeroWithStakeBlocksClosesAnEpochWithoutChangingTheAccumulator() public {
        _stake(alice, 10 ether);
        _roll(1);
        uint256 epoch = vault.currentEpoch();
        uint256 cumulative = _cumulativeRate();
        _reward(0);
        assertEq(vault.currentEpoch(), epoch + 1, "an epoch closes even on a zero distribution");
        assertEq(_cumulativeRate(), cumulative, "rate zero adds nothing");
        assertEq(vault.earned(alice), 0);
        assertEq(vault.currentTotalPoints(), 0, "stake-blocks reset");
    }

    function test_notifyInTheStakersBlockDoesNotCloseAnEpoch() public {
        _stake(alice, 10 ether);
        uint256 epoch = vault.currentEpoch();
        _reward(1 ether);
        assertEq(vault.currentEpoch(), epoch, "no stake-blocks: nothing to close");
        assertEq(vault.queuedRewards(), 1 ether);
    }

    function test_directDonationIsNeitherDistributedNorBlocking() public {
        _stake(alice, 10 ether);
        imd.mint(address(vault), 100 ether);
        _roll(1);
        assertEq(vault.earned(alice), 0, "unnotified IMD is not a reward");
        _reward(1 ether);
        assertEq(vault.earned(alice), 1 ether);
        vm.prank(alice);
        vault.exit();
        assertEq(imd.balanceOf(alice), 1 ether);
        assertEq(imd.balanceOf(address(vault)), 100 ether, "donation stays in the vault");
    }

    // ---------------------------------------------------------------------------------------------
    // Accounts that never interacted, and accounts that left long ago
    // ---------------------------------------------------------------------------------------------

    function test_viewsAndCallsOnAnUntouchedAccountAfterManyEpochs() public {
        _stake(alice, 10 ether);
        for (uint256 i = 0; i < 5; i++) {
            _roll(3);
            _reward(1 ether);
        }
        assertEq(vault.currentEpoch(), 5);
        // carol never touched the vault: her account is at epoch 0 with lastBlock 0 < every epoch start.
        assertEq(vault.earned(carol), 0);
        assertEq(vault.points(carol), 0);
        vm.startPrank(carol);
        assertEq(vault.claim(), 0);
        vault.exit();
        vm.stopPrank();
        // Joining now puts her cleanly into the open epoch.
        _stake(carol, 10 ether);
        _roll(1);
        _reward(20 ether);
        // Each 1-ether round over 30e18 stake-blocks re-queued 10 wei; those 50 wei ride into this split.
        assertApproxEqAbs(vault.earned(carol), 10 ether, 50);
        assertApproxEqAbs(vault.earned(alice), 5 ether + 10 ether, 50);
        assertGe(vault.earned(carol), 10 ether, "carol never earns less than half of what she was present for");
    }

    function test_fullyUnstakedAccountIsPaidItsOldStakeBlocksManyEpochsLater() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        _roll(10);
        vm.prank(bob);
        vault.unstake(100 ether); // bob: 1000 stake-blocks in the open epoch, stake now zero
        _roll(10);
        _reward(30 ether); // alice 2000, bob 1000 -> 20 / 10
        for (uint256 i = 0; i < 4; i++) {
            _roll(5);
            _reward(5 ether); // alice alone
        }
        assertEq(vault.earned(bob), 10 ether, "old stake-blocks survive later epochs untouched");
        assertEq(vault.earned(alice), 20 ether + 20 ether);
        vm.prank(bob);
        assertEq(vault.claim(), 10 ether);
        // Staking again after the gap starts clean in the open epoch.
        _stake(bob, 100 ether);
        _roll(1);
        _reward(2 ether);
        assertEq(vault.earned(bob), 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Flash stakes around a distribution (the reopened finding)
    // ---------------------------------------------------------------------------------------------

    function test_flashStakeThenNotifyThenExitInOneBlockEarnsNothing() public {
        _stake(alice, 100 ether);
        _roll(100_000);
        _stake(bob, 1_000 ether);
        _reward(100 ether);
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(bob), 0);
        assertEq(vault.earned(alice), 100 ether);
    }

    function test_notifyThenFlashStakeThenExitInOneBlockEarnsNothing() public {
        _stake(alice, 100 ether);
        _roll(100_000);
        _reward(100 ether);
        _stake(bob, 1_000 ether);
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(bob), 0);
        assertEq(vault.earned(alice), 100 ether);
    }

    /// @notice A bot that closes the epoch itself (a zero notification stands in for a dust sweep) right before
    /// staking cannot touch what accrued before it: that is paid to the incumbents at the reset.
    function test_resetBeforeStakingDoesNotCaptureEarlierRewards() public {
        _stake(alice, 100 ether);
        _roll(1_000);
        uint256 beforeBot = 100 ether;
        _reward(beforeBot); // the reset: everything so far goes to alice
        token.transfer(bob, 8_900 ether);
        _stake(bob, 9_900 ether);
        _roll(1);
        _reward(10 ether); // one block of both: 100 vs 9900
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(bob), 9.9 ether, "only its stake-share of the block it was staked in");
        assertEq(vault.earned(alice), beforeBot + 0.1 ether);
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_flashStakeNeverEarnsWhateverTheOrderAndSize(uint128 bag, uint64 wait, uint128 reward, bool first)
        public
    {
        uint256 bot = bound(uint256(bag), 1, 1_000 ether);
        uint256 blocks = bound(uint256(wait), 1, 5_000_000);
        uint256 amount = bound(uint256(reward), 0, 1e24);
        _stake(alice, 100 ether);
        _roll(blocks);
        if (first) _stake(bob, bot);
        _reward(amount);
        if (!first) _stake(bob, bot);
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(bob), 0);
        assertEq(token.balanceOf(bob), 1_000 ether);
        assertLe(vault.earned(alice) + vault.queuedRewards(), amount);
        assertGe(vault.earned(alice) + vault.queuedRewards() + 1, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Lazy versus active settlement
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_lazyAndActiveStakersEarnTheSame(uint8 epochsN, uint128 r, uint8 gap, uint128 stakeB) public {
        uint256 n = bound(uint256(epochsN), 1, 12);
        uint256 reward = bound(uint256(r), 1, 1e24);
        uint256 blocks = bound(uint256(gap), 1, 200);
        uint256 stake = bound(uint256(stakeB), 1, 1_000 ether);
        _stake(alice, stake);
        _stake(bob, stake);
        uint256 bobPaid;
        for (uint256 i = 0; i < n; i++) {
            _roll(blocks);
            _reward(reward);
            vm.prank(bob);
            bobPaid += vault.claim(); // bob settles every epoch; alice never does
        }
        uint256 aliceEarned = vault.earned(alice);
        assertLe(aliceEarned, bobPaid + n, "lazy settlement never earns more than one wei per epoch over active");
        assertLe(bobPaid, aliceEarned + n, "nor less");
        vm.prank(alice);
        assertEq(vault.claim(), aliceEarned);
    }

    // ---------------------------------------------------------------------------------------------
    // Rounding at the extremes
    // ---------------------------------------------------------------------------------------------

    function test_subUnitRewardWithWholeSupplyStakedIsRequeuedNotLost() public {
        // Everything that exists is staked by one account for one block: 1e27 stake-blocks, so the rate is
        // reward / 1e9 and anything under one gwei cannot be represented.
        token.transfer(alice, token.balanceOf(address(this)));
        vm.prank(bob);
        token.transfer(alice, 1_000 ether);
        vm.prank(carol);
        token.transfer(alice, 1_000 ether);
        _stake(alice, 1e27);
        _roll(1);

        _reward(1e9 - 1);
        assertEq(vault.earned(alice), 0, "rate floors to zero");
        assertEq(vault.queuedRewards(), 1e9 - 1, "re-queued, not stranded");
        assertEq(vault.currentEpoch(), 1, "the epoch still closes");
        _roll(1);
        _reward(1e9);
        assertEq(vault.earned(alice), 1e9, "one unit distributes exactly");
        assertEq(vault.queuedRewards(), 1e9 - 1);
        _roll(1);
        _reward(7e18 + 123);
        assertEq(vault.earned(alice) + vault.queuedRewards(), (1e9 - 1) + 1e9 + 7e18 + 123, "exact conservation");
        assertEq(vault.queuedRewards(), 122);
        vm.prank(alice);
        vault.claim();
        assertEq(imd.balanceOf(alice), 7e18 + 2e9);
        assertEq(imd.balanceOf(address(vault)), 122, "only the queue remains");
    }

    function test_largeRewardOnTinyStakeDoesNotOverflow() public {
        _stake(alice, 1);
        _roll(1);
        _reward(1e27); // rate = 1e45 per stake-block
        assertEq(vault.earned(alice), 1e27);
        _stake(bob, 1_000 ether);
        _roll(1);
        _reward(1e27);
        assertApproxEqAbs(vault.earned(alice) + vault.earned(bob), 2e27, 1_000 ether / PRECISION + 2);
        assertLe(vault.earned(alice), 1e27 + 1e27 / 1_000 + 1, "one wei against 1000 ether earns about a thousandth");
        uint256 expected = vault.earned(alice);
        vm.prank(alice);
        assertEq(vault.claim(), expected);

        // A whale holding nearly the whole supply joins after the 1e45-rate epoch: its settlement multiplies a
        // 1e27 stake by the cumulative rate difference and must neither revert nor overpay.
        address whale = makeAddr("whale");
        uint256 whaleStake = token.balanceOf(address(this));
        token.transfer(whale, whaleStake);
        vm.startPrank(whale);
        token.approve(address(vault), type(uint256).max);
        vault.stake(whaleStake);
        vm.stopPrank();
        _roll(1_000);
        _reward(1e24);
        uint256 whaleEarned = vault.earned(whale);
        assertLe(whaleEarned, 1e24);
        assertGt(whaleEarned, 1e24 * 999 / 1_000, "the whale holds almost all stake-blocks");
        vm.prank(whale);
        assertEq(vault.claim(), whaleEarned);
    }

    function test_threeStakersAcrossRoundsConserveRewards() public {
        _stake(alice, 100 ether);
        _roll(1);
        _reward(30 ether);
        _stake(bob, 200 ether);
        _roll(1);
        _reward(30 ether);
        _stake(carol, 300 ether);
        _roll(1);
        _reward(60 ether);
        vm.prank(alice);
        vault.exit();
        _roll(1);
        _reward(50 ether);

        assertEq(imd.balanceOf(alice), 30 ether + 10 ether + 10 ether);
        assertEq(vault.earned(bob), 20 ether + 20 ether + 20 ether);
        assertEq(vault.earned(carol), 30 ether + 30 ether);
        assertEq(imd.balanceOf(alice) + vault.earned(bob) + vault.earned(carol), 170 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Odd tokens
    // ---------------------------------------------------------------------------------------------

    function test_stakingTokenThatReturnsFalseIsRefused() public {
        QuirkyERC20 odd = new QuirkyERC20();
        SpongeBotVault v = new SpongeBotVault(address(odd), address(imd), address(this));
        odd.mint(alice, 10 ether);
        vm.prank(alice);
        odd.approve(address(v), type(uint256).max);
        odd.setMode(QuirkyERC20.Mode.ReturnFalse);
        vm.prank(alice);
        vm.expectRevert(SpongeBotVault.TransferFailed.selector);
        v.stake(1 ether);
        assertEq(v.totalStaked(), 0, "no phantom stake");
    }

    function test_tokensThatReturnNothingStillWork() public {
        QuirkyERC20 oddStake = new QuirkyERC20();
        QuirkyERC20 oddReward = new QuirkyERC20();
        oddStake.setMode(QuirkyERC20.Mode.NoReturn);
        oddReward.setMode(QuirkyERC20.Mode.NoReturn);
        SpongeBotVault v = new SpongeBotVault(address(oddStake), address(oddReward), address(this));
        oddStake.mint(alice, 10 ether);
        vm.startPrank(alice);
        oddStake.approve(address(v), type(uint256).max);
        v.stake(10 ether);
        vm.stopPrank();
        _roll(1);
        oddReward.mint(address(v), 4 ether);
        v.notifyReward(4 ether);
        vm.prank(alice);
        v.exit();
        assertEq(oddStake.balanceOf(alice), 10 ether);
        assertEq(oddReward.balanceOf(alice), 4 ether);
    }

    function test_rewardTokenTransferFailureRevertsClaimButKeepsTheCredit() public {
        QuirkyERC20 oddReward = new QuirkyERC20();
        SpongeBotVault v = new SpongeBotVault(address(token), address(oddReward), address(this));
        vm.startPrank(alice);
        token.approve(address(v), type(uint256).max);
        v.stake(10 ether);
        vm.stopPrank();
        _roll(1);
        oddReward.mint(address(v), 4 ether);
        v.notifyReward(4 ether);
        oddReward.setMode(QuirkyERC20.Mode.ReturnFalse);
        vm.prank(alice);
        vm.expectRevert(SpongeBotVault.TransferFailed.selector);
        v.claim();
        assertEq(v.earned(alice), 4 ether, "credit intact after a failed payout");
        oddReward.setMode(QuirkyERC20.Mode.Normal);
        vm.prank(alice);
        assertEq(v.claim(), 4 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: stake always comes back exactly; rewards never exceed what was received
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_anyStakerCanAlwaysLeaveWithExactlyTheirStake(
        uint256 a,
        uint256 b,
        uint256 r,
        uint8 rounds,
        uint8 gap
    ) public {
        uint256 stakeA = bound(a, 1, 1_000 ether);
        uint256 stakeB = bound(b, 1, 1_000 ether);
        uint256 reward = bound(r, 0, 1e24);
        uint256 n = bound(uint256(rounds), 1, 6);
        uint256 blocks = bound(uint256(gap), 0, 50);
        _stake(alice, stakeA);
        for (uint256 i = 0; i < n; i++) {
            _roll(blocks);
            _reward(reward);
            if (i == 0) _stake(bob, stakeB);
        }
        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(token.balanceOf(alice), 1_000 ether, "alice got her stake back exactly");
        assertEq(token.balanceOf(bob), 1_000 ether, "bob too");
        assertEq(vault.totalStaked(), 0);
        uint256 paid = imd.balanceOf(alice) + imd.balanceOf(bob);
        assertLe(paid + vault.queuedRewards(), reward * n, "cannot pay more than received");
        assertLe(imd.balanceOf(address(vault)) - vault.queuedRewards(), n + 4, "unclaimable dust is a few wei");
    }
}
