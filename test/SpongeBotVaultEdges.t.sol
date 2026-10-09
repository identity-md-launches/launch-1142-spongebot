// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SPONGEBOT} from "../src/SPONGEBOT.sol";
import {SpongeBotVault} from "../src/SpongeBotVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {QuirkyERC20} from "./mocks/QuirkyERC20.sol";

/// @notice Vault edge cases against the streaming reward-per-token accumulator: empty and repeated calls, the
/// paused stream while nothing is staked, zero notifications, accounts that never interacted, lazy versus active
/// settlement, rounding at the extremes, odd tokens, donations, and the flash-stake shapes around a distribution.
contract SpongeBotVaultEdgesTest is Test {
    uint256 constant PRECISION = 1e30;

    SPONGEBOT token;
    MockERC20 imd;
    SpongeBotVault vault;
    uint256 D;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.roll(1_000);
        token = new SPONGEBOT();
        imd = new MockERC20("IMD", "IMD", 0);
        vault = new SpongeBotVault(address(token), address(imd), address(this));
        D = vault.REWARD_DURATION();
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
        _reward(D * 1 ether);
        _roll(D);
        vm.startPrank(alice);
        assertEq(vault.claim(), D * 1 ether);
        assertEq(vault.claim(), 0);
        vault.exit();
        vault.exit();
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), D * 1 ether);
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    function test_stakingAgainDoesNotForfeitOrDoubleCountRewards() public {
        _stake(alice, 100 ether);
        _reward(D * 1 ether);
        _roll(10);
        assertEq(vault.earned(alice), 10 ether);
        _stake(alice, 100 ether);
        assertEq(vault.earned(alice), 10 ether, "earned carried over");
        _roll(10);
        assertEq(vault.earned(alice), 20 ether, "same rate: alice is still the only staker");
    }

    function test_partialUnstakeThenRewardIsProRataOnTheRemainder() public {
        _stake(alice, 300 ether);
        _stake(bob, 100 ether);
        vm.prank(alice);
        vault.unstake(200 ether);
        _reward(D * 2 ether);
        _roll(10);
        assertEq(vault.earned(alice), 10 ether);
        assertEq(vault.earned(bob), 10 ether);
    }

    function test_lateStakerEarnsNothingFromBlocksBeforeItJoined() public {
        _stake(alice, 100 ether);
        _reward(D * 1 ether);
        _roll(10);
        _stake(bob, 1_000 ether);
        assertEq(vault.earned(bob), 0);
        assertEq(vault.earned(alice), 10 ether);
        _roll(11);
        assertEq(vault.earned(bob), 10 ether, "10/11 of eleven blocks");
        assertEq(vault.earned(alice), 11 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // The paused stream: rewards while nothing is staked
    // ---------------------------------------------------------------------------------------------

    function test_rewardsWhileEmptyAreSharedByWhoeverStakesNextProRata() public {
        _reward(D * 9 ether);
        _stake(alice, 100 ether);
        _stake(bob, 200 ether);
        assertEq(vault.earned(alice), 0, "nothing in the block of the stake");
        _roll(D);
        assertEq(vault.earned(alice), D * 3 ether);
        assertEq(vault.earned(bob), D * 6 ether);
        assertEq(vault.unstreamedRewards(), 0);
    }

    function test_pausedStreamSurvivesStakersComingAndGoing() public {
        _reward(5 ether);
        _stake(alice, 10 ether);
        vm.prank(alice);
        vault.unstake(10 ether);
        assertApproxEqAbs(vault.unstreamedRewards(), 5 ether, 1, "nothing streamed in zero blocks");
        _roll(100);
        _reward(1 ether);
        assertApproxEqAbs(vault.unstreamedRewards(), 6 ether, 1, "still empty: folded into a fresh stream");
        assertEq(vault.streamEnd(), block.number + D);
        _stake(bob, 1);
        _reward(0);
        assertApproxEqAbs(vault.unstreamedRewards(), 6 ether, 1, "a zero notification keeps the sum");
        assertEq(vault.earned(bob), 0);
        _roll(D);
        assertApproxEqAbs(vault.earned(bob), 6 ether, 2, "the next staker gets it all over the window");
        assertEq(vault.unstreamedRewards(), 0);
    }

    /// @notice Documented behaviour, pinned: the first staker, however small, takes everything that arrived while
    /// the vault was empty, provided it stays the only staker for the whole window.
    function test_firstStakerOfOneWeiTakesEverythingOverTheWindow() public {
        _reward(100 ether);
        _roll(123_456);
        _stake(alice, 1);
        assertEq(vault.streamEnd(), block.number + D, "the pause pushed the end to a full window from now");
        _roll(D);
        assertApproxEqAbs(vault.earned(alice), 100 ether, 1);
    }

    function test_pausedStreamIsNotShortenedByIdleBlocks() public {
        _stake(alice, 100 ether);
        _reward(D * 1 ether);
        _roll(100);
        vm.prank(alice);
        vault.unstake(100 ether);
        assertEq(vault.remainingStreamBlocks(), D - 100);
        _roll(1_000_000);
        assertEq(vault.remainingStreamBlocks(), D - 100, "frozen while empty");
        assertEq(vault.unstreamedRewards(), (D - 100) * 1 ether);
        _stake(bob, 1 ether);
        assertEq(vault.remainingStreamBlocks(), D - 100);
        _roll(D - 100);
        assertEq(vault.earned(bob), (D - 100) * 1 ether);
        assertEq(vault.remainingStreamBlocks(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Zero and same-block notifications
    // ---------------------------------------------------------------------------------------------

    function test_notifyZeroMidStreamRestartsTheWindowWithTheLeftover() public {
        _stake(alice, 10 ether);
        _reward(D * 1 ether);
        _roll(D / 2);
        assertEq(vault.earned(alice), D / 2 * 1 ether);
        uint256 unstreamed = vault.unstreamedRewards();
        _reward(0);
        assertEq(vault.earned(alice), D / 2 * 1 ether, "nothing changes for what was already streamed");
        assertEq(vault.unstreamedRewards(), unstreamed, "the leftover is kept in full");
        assertEq(vault.streamEnd(), block.number + D, "but now over a full window");
        assertEq(vault.rewardRate(), unstreamed * PRECISION / D, "at half the rate");
        _roll(D);
        assertEq(vault.earned(alice), D * 1 ether);
    }

    function test_notifyInTheStakersBlockPaysNothingInThatBlock() public {
        _stake(alice, 10 ether);
        _reward(1 ether);
        assertEq(vault.earned(alice), 0);
        vm.prank(alice);
        assertEq(vault.claim(), 0);
        _roll(1);
        assertEq(vault.earned(alice), 1 ether / D);
    }

    function test_twoNotificationsInOneBlockAddUp() public {
        _stake(alice, 10 ether);
        _reward(D * 1 ether);
        _reward(D * 2 ether);
        assertEq(vault.unstreamedRewards(), D * 3 ether);
        _roll(1);
        assertEq(vault.earned(alice), 3 ether);
    }

    function test_directDonationIsNeitherDistributedNorBlocking() public {
        _stake(alice, 10 ether);
        imd.mint(address(vault), 100 ether);
        _roll(D);
        assertEq(vault.earned(alice), 0, "unnotified IMD is not a reward");
        _reward(D * 1 ether);
        _roll(D);
        assertEq(vault.earned(alice), D * 1 ether);
        vm.prank(alice);
        vault.exit();
        assertEq(imd.balanceOf(alice), D * 1 ether);
        assertEq(imd.balanceOf(address(vault)), 100 ether, "donation stays in the vault");
    }

    // ---------------------------------------------------------------------------------------------
    // Accounts that never interacted, and accounts that left long ago
    // ---------------------------------------------------------------------------------------------

    function test_viewsAndCallsOnAnUntouchedAccountAfterManyStreams() public {
        _stake(alice, 10 ether);
        for (uint256 i = 0; i < 5; i++) {
            _roll(3);
            _reward(1 ether);
        }
        assertEq(vault.earned(carol), 0);
        assertEq(vault.userRewardPerTokenPaid(carol), 0);
        vm.startPrank(carol);
        assertEq(vault.claim(), 0);
        vault.exit();
        vm.stopPrank();
        // Joining now catches carol up to the accumulator: she owes nothing from the past and earns from here.
        _stake(carol, 10 ether);
        assertEq(vault.userRewardPerTokenPaid(carol), vault.rewardPerToken());
        _roll(D);
        uint256 total = vault.earned(alice) + vault.earned(carol);
        assertApproxEqAbs(total + vault.unstreamedRewards(), 5 ether, 10, "conservation");
        assertGt(vault.earned(alice), vault.earned(carol), "alice was alone for the first 15 blocks");
        // The gap is what alice streamed alone: 15 blocks at under 5 ether per window.
        assertLe(vault.earned(alice) - vault.earned(carol), 15 * 5 ether / D + 10);
        assertGt(vault.earned(carol), 2 ether, "carol gets nearly half of what was left");
    }

    function test_fullyUnstakedAccountKeepsItsRewardsThroughLaterStreams() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        _reward(D * 2 ether);
        _roll(10);
        vm.prank(bob);
        vault.unstake(100 ether); // bob: 10 blocks at half the stream = 10 ether
        assertEq(vault.earned(bob), 10 ether);
        for (uint256 i = 0; i < 4; i++) {
            _roll(D);
            _reward(5 ether); // alice alone from here on
        }
        assertEq(vault.earned(bob), 10 ether, "old rewards survive later streams untouched");
        vm.prank(bob);
        assertEq(vault.claim(), 10 ether);
        // Staking again after the gap starts clean at the current accumulator.
        _stake(bob, 100 ether);
        assertEq(vault.earned(bob), 0);
        _roll(D);
        assertApproxEqAbs(vault.earned(bob), 2.5 ether, 2, "half of the last distribution");
    }

    // ---------------------------------------------------------------------------------------------
    // Flash stakes around a distribution
    // ---------------------------------------------------------------------------------------------

    function test_flashStakeThenNotifyThenExitInOneBlockEarnsNothing() public {
        _stake(alice, 100 ether);
        _roll(100_000);
        _stake(bob, 1_000 ether);
        _reward(100 ether);
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(bob), 0);
        _roll(D);
        assertApproxEqAbs(vault.earned(alice), 100 ether, 1);
    }

    function test_notifyThenFlashStakeThenExitInOneBlockEarnsNothing() public {
        _stake(alice, 100 ether);
        _roll(100_000);
        _reward(100 ether);
        _stake(bob, 1_000 ether);
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(bob), 0);
        _roll(D);
        assertApproxEqAbs(vault.earned(alice), 100 ether, 1);
    }

    /// @notice A bot holding 99% of the stake for exactly one block around a distribution gets one block's share
    /// of the window (99% of 1/7200), never the backlog.
    function test_oneBlockWhaleGetsOneWindowBlockOnly() public {
        _stake(alice, 100 ether);
        _roll(1_000);
        token.transfer(bob, 8_900 ether);
        _reward(D * 100 ether); // 100 per block
        _stake(bob, 9_900 ether);
        _roll(1);
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(bob), 99 ether, "its stake-share of exactly one block");
        assertEq(vault.earned(alice), 1 ether);
        _roll(D);
        assertEq(vault.earned(alice), (D - 1) * 100 ether + 1 ether);
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
        _roll(D);
        assertLe(vault.earned(alice), amount);
        assertGe(vault.earned(alice) + 2, amount);
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_shortStakeEarnsAtMostItsBlocksOfTheWindow(uint128 bag, uint128 reward, uint16 held) public {
        uint256 bot = bound(uint256(bag), 1, 1_000 ether);
        uint256 amount = bound(uint256(reward), 1, 1e24);
        uint256 heldBlocks = bound(uint256(held), 0, 2 * D);
        _stake(alice, 1); // the smallest possible incumbent: the bot holds nearly all the stake
        _roll(10);
        _reward(amount);
        _stake(bob, bot);
        _roll(heldBlocks);
        vm.prank(bob);
        vault.exit();
        uint256 cap = heldBlocks >= D ? amount : amount * heldBlocks / D + 1;
        assertLe(imd.balanceOf(bob), cap, "at most its blocks of the window");
    }

    // ---------------------------------------------------------------------------------------------
    // Lazy versus active settlement
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_lazyAndActiveStakersEarnTheSame(uint8 roundsN, uint128 r, uint16 gap, uint128 stakeB) public {
        uint256 n = bound(uint256(roundsN), 1, 12);
        uint256 reward = bound(uint256(r), 1, 1e24);
        uint256 blocks = bound(uint256(gap), 1, 2 * D);
        uint256 stake = bound(uint256(stakeB), 1, 1_000 ether);
        _stake(alice, stake);
        _stake(bob, stake);
        uint256 bobPaid;
        for (uint256 i = 0; i < n; i++) {
            _reward(reward);
            _roll(blocks);
            vm.prank(bob);
            bobPaid += vault.claim(); // bob settles every round; alice never does
        }
        uint256 aliceEarned = vault.earned(alice);
        assertLe(aliceEarned, bobPaid + n, "lazy settlement never earns more than one wei per round over active");
        assertLe(bobPaid, aliceEarned + n, "nor less");
        vm.prank(alice);
        assertEq(vault.claim(), aliceEarned);
    }

    // ---------------------------------------------------------------------------------------------
    // Rounding at the extremes
    // ---------------------------------------------------------------------------------------------

    function test_subWindowRewardWithWholeSupplyStakedIsPaidWithinDust() public {
        // Everything that exists is staked by one account. A 7 wei reward streams at 7e30 / 7200 = 9.7e26 per
        // block against 1e27 staked: under one accumulator unit per block, so every per-block settlement floors
        // it away, while a single settlement after the window keeps all but the rate's own rounding.
        token.transfer(alice, token.balanceOf(address(this)));
        vm.prank(bob);
        token.transfer(alice, 1_000 ether);
        vm.prank(carol);
        token.transfer(alice, 1_000 ether);
        _stake(alice, 1e27);
        assertEq(vault.totalStaked(), token.totalSupply());

        _reward(7);
        _roll(D);
        assertEq(vault.earned(alice), 6, "settled once: one wei lost to the rate floor");
        vm.prank(alice);
        assertEq(vault.claim(), 6);

        _reward(7);
        for (uint256 i = 0; i < 10; i++) {
            _roll(1);
            vm.prank(alice);
            assertEq(vault.claim(), 0, "settled every block: 0.97 per block floors to nothing");
        }
        _roll(D);
        assertLe(vault.earned(alice), 6, "what the per-block floors lost is gone for good");

        _reward(1e9 - 1);
        _roll(D);
        assertApproxEqAbs(vault.earned(alice), 1e9 - 1 + 6, 1);
        _reward(7e18 + 123);
        _roll(D);
        assertApproxEqAbs(vault.earned(alice), 7e18 + 123 + 1e9 - 1 + 6, 2, "conservation within dust");
        uint256 earned = vault.earned(alice);
        vm.prank(alice);
        assertEq(vault.claim(), earned);
        assertLe(imd.balanceOf(address(vault)), 20, "only dust remains");
    }

    function test_largeRewardOnTinyStakeDoesNotOverflowLaterWhales() public {
        _stake(alice, 1);
        _reward(1e27); // rate 1e57 / 7200 per block on one wei of stake: rewardPerToken reaches 1e57
        _roll(D);
        assertApproxEqAbs(vault.earned(alice), 1e27, 1);
        _stake(bob, 1_000 ether);
        _reward(1e27);
        _roll(D);
        assertApproxEqAbs(vault.earned(alice) + vault.earned(bob), 2e27, 4);
        assertLe(vault.earned(alice), 1e27 + 1e27 / 1_000 + 1, "one wei against 1000 ether earns about a thousandth");
        uint256 expected = vault.earned(alice);
        vm.prank(alice);
        assertEq(vault.claim(), expected);

        // A whale holding nearly the whole supply joins after the 1e57 accumulator: its settlement multiplies a
        // 1e27 stake by the accumulator growth since it joined and must neither revert nor overpay.
        address whale = makeAddr("whale");
        uint256 whaleStake = token.balanceOf(address(this));
        token.transfer(whale, whaleStake);
        vm.startPrank(whale);
        token.approve(address(vault), type(uint256).max);
        vault.stake(whaleStake);
        vm.stopPrank();
        _reward(1e24);
        _roll(D);
        uint256 whaleEarned = vault.earned(whale);
        assertLe(whaleEarned, 1e24);
        assertGt(whaleEarned, 1e24 * 999 / 1_000, "the whale holds almost all the stake");
        vm.prank(whale);
        assertEq(vault.claim(), whaleEarned);
        assertGe(vault.rewardPerTokenStored(), 1e57, "the accumulator is monotonic and huge");
    }

    function test_threeStakersAcrossRoundsConserveRewards() public {
        _stake(alice, 100 ether);
        _reward(D * 30 ether);
        _roll(D);
        _stake(bob, 200 ether);
        _reward(D * 30 ether);
        _roll(D);
        _stake(carol, 300 ether);
        _reward(D * 60 ether);
        _roll(D);
        vm.prank(alice);
        vault.exit();
        _reward(D * 50 ether);
        _roll(D);

        assertEq(imd.balanceOf(alice), D * (30 ether + 10 ether + 10 ether));
        assertEq(vault.earned(bob), D * (20 ether + 20 ether + 20 ether));
        assertEq(vault.earned(carol), D * (30 ether + 30 ether));
        assertEq(imd.balanceOf(alice) + vault.earned(bob) + vault.earned(carol), D * 170 ether);
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
        oddReward.mint(address(v), D * 1 ether);
        v.notifyReward(D * 1 ether);
        _roll(D);
        vm.prank(alice);
        v.exit();
        assertEq(oddStake.balanceOf(alice), 10 ether);
        assertEq(oddReward.balanceOf(alice), D * 1 ether);
    }

    function test_rewardTokenTransferFailureRevertsClaimButKeepsTheCredit() public {
        QuirkyERC20 oddReward = new QuirkyERC20();
        SpongeBotVault v = new SpongeBotVault(address(token), address(oddReward), address(this));
        vm.startPrank(alice);
        token.approve(address(v), type(uint256).max);
        v.stake(10 ether);
        vm.stopPrank();
        oddReward.mint(address(v), D * 1 ether);
        v.notifyReward(D * 1 ether);
        _roll(D);
        oddReward.setMode(QuirkyERC20.Mode.ReturnFalse);
        vm.prank(alice);
        vm.expectRevert(SpongeBotVault.TransferFailed.selector);
        v.claim();
        assertEq(v.earned(alice), D * 1 ether, "credit intact after a failed payout");
        oddReward.setMode(QuirkyERC20.Mode.Normal);
        vm.prank(alice);
        assertEq(v.claim(), D * 1 ether);
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
        uint16 gap
    ) public {
        uint256 stakeA = bound(a, 1, 1_000 ether);
        uint256 stakeB = bound(b, 1, 1_000 ether);
        uint256 reward = bound(r, 0, 1e24);
        uint256 n = bound(uint256(rounds), 1, 6);
        uint256 blocks = bound(uint256(gap), 0, 2 * D);
        _stake(alice, stakeA);
        for (uint256 i = 0; i < n; i++) {
            _roll(blocks);
            _reward(reward);
            if (i == 0) _stake(bob, stakeB);
        }
        _roll(blocks);
        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(token.balanceOf(alice), 1_000 ether, "alice got her stake back exactly");
        assertEq(token.balanceOf(bob), 1_000 ether, "bob too");
        assertEq(vault.totalStaked(), 0);
        uint256 paid = imd.balanceOf(alice) + imd.balanceOf(bob);
        assertLe(paid + vault.unstreamedRewards(), reward * n, "cannot pay more than received");
        assertLe(imd.balanceOf(address(vault)) - vault.unstreamedRewards(), 4 * n + 4, "unclaimable dust is a few wei");
    }
}
