// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SPONGEBOT} from "../src/SPONGEBOT.sol";
import {SpongeBotVault} from "../src/SpongeBotVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {QuirkyERC20} from "./mocks/QuirkyERC20.sol";

/// @notice Vault edge cases: empty claims, repeated calls, rounding at the extremes, odd tokens, donations.
contract SpongeBotVaultEdgesTest is Test {
    SPONGEBOT token;
    MockERC20 imd;
    SpongeBotVault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
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
        vm.prank(alice);
        vault.stake(10 ether);
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
        vm.prank(alice);
        vault.stake(100 ether);
        _reward(10 ether);
        vm.prank(alice);
        vault.stake(100 ether);
        assertEq(vault.earned(alice), 10 ether, "earned carried over");
        _reward(10 ether);
        assertEq(vault.earned(alice), 20 ether);
    }

    function test_partialUnstakeThenRewardIsProRataOnTheRemainder() public {
        vm.prank(alice);
        vault.stake(300 ether);
        vm.prank(bob);
        vault.stake(100 ether);
        vm.prank(alice);
        vault.unstake(200 ether);
        _reward(20 ether);
        assertEq(vault.earned(alice), 10 ether);
        assertEq(vault.earned(bob), 10 ether);
    }

    function test_lateStakerEarnsNothingFromEarlierDistributions() public {
        vm.prank(alice);
        vault.stake(100 ether);
        _reward(10 ether);
        vm.prank(bob);
        vault.stake(1_000 ether);
        assertEq(vault.earned(bob), 0);
        assertEq(vault.earned(alice), 10 ether);
    }

    function test_rewardsQueuedWhileEmptyGoToTheNextDistributionNotTheNextStakerAlone() public {
        _reward(9 ether);
        vm.prank(alice);
        vault.stake(100 ether);
        vm.prank(bob);
        vault.stake(200 ether);
        assertEq(vault.earned(alice), 0, "queued rewards wait for a notification");
        _reward(3 ether);
        assertEq(vault.earned(alice), 4 ether);
        assertEq(vault.earned(bob), 8 ether);
        assertEq(vault.queuedRewards(), 0);
    }

    function test_queueSurvivesStakersComingAndGoing() public {
        _reward(5 ether);
        vm.prank(alice);
        vault.stake(10 ether);
        vm.prank(alice);
        vault.unstake(10 ether);
        assertEq(vault.queuedRewards(), 5 ether, "nobody was notified while staked");
        _reward(1 ether);
        assertEq(vault.queuedRewards(), 6 ether, "still empty: keeps queueing");
        vm.prank(bob);
        vault.stake(1);
        _reward(0);
        assertEq(vault.earned(bob), 6 ether, "a zero notification with stakers flushes the queue");
    }

    function test_notifyZeroWithStakersChangesNothing() public {
        vm.prank(alice);
        vault.stake(10 ether);
        uint256 rpt = vault.rewardPerTokenStored();
        _reward(0);
        assertEq(vault.rewardPerTokenStored(), rpt);
        assertEq(vault.earned(alice), 0);
    }

    function test_directDonationIsNeitherDistributedNorBlocking() public {
        vm.prank(alice);
        vault.stake(10 ether);
        imd.mint(address(vault), 100 ether);
        assertEq(vault.earned(alice), 0, "unnotified IMD is not a reward");
        _reward(1 ether);
        assertEq(vault.earned(alice), 1 ether);
        vm.prank(alice);
        vault.exit();
        assertEq(imd.balanceOf(alice), 1 ether);
        assertEq(imd.balanceOf(address(vault)), 100 ether, "donation stays in the vault");
    }

    function test_rewardSmallerThanPrecisionWithWholeSupplyStakedIsNotOverpaid() public {
        // Everything that exists is staked by one account: the accumulator step is reward x 1e18 / 1e27.
        token.transfer(alice, token.balanceOf(address(this)));
        vm.prank(bob);
        token.transfer(alice, 1_000 ether);
        vm.prank(carol);
        token.transfer(alice, 1_000 ether);
        vm.prank(alice);
        vault.stake(1e27);
        assertEq(vault.totalStaked(), 1e27);

        _reward(1e9 - 1);
        assertEq(vault.earned(alice), 0, "below one accumulator unit: nothing distributable");
        assertEq(vault.queuedRewards(), 0, "and not queued either: it is rounding dust");
        _reward(1e9);
        assertEq(vault.earned(alice), 1e9, "one unit distributes exactly");
        _reward(7e18 + 123);
        uint256 earned = vault.earned(alice);
        assertLe(earned, 1e9 + 7e18 + 123);
        assertGe(earned + 1e9, 1e9 + 7e18 + 123, "dust per distribution is under totalStaked / 1e18");
        vm.prank(alice);
        vault.claim();
        assertEq(imd.balanceOf(alice), earned);
    }

    function test_largeRewardOnTinyStakeDoesNotOverflow() public {
        vm.prank(alice);
        vault.stake(1);
        _reward(1e27);
        assertEq(vault.earned(alice), 1e27);
        vm.prank(bob);
        vault.stake(1_000 ether);
        _reward(1e27);
        assertApproxEqAbs(vault.earned(alice) + vault.earned(bob), 2e27, 1_000 ether / 1e18 + 2);
        uint256 expected = vault.earned(alice);
        vm.prank(alice);
        assertEq(vault.claim(), expected);
        assertEq(imd.balanceOf(alice), expected);
        assertLe(expected, 1e27 + 1e27 / 1_000 + 1, "one wei of stake against 1000 ether earns about a thousandth");
    }

    function test_threeStakersAcrossRoundsConserveRewards() public {
        vm.prank(alice);
        vault.stake(100 ether);
        _reward(30 ether);
        vm.prank(bob);
        vault.stake(200 ether);
        _reward(30 ether);
        vm.prank(carol);
        vault.stake(300 ether);
        _reward(60 ether);
        vm.prank(alice);
        vault.exit();
        _reward(50 ether);

        assertEq(imd.balanceOf(alice), 30 ether + 10 ether + 10 ether);
        assertEq(vault.earned(bob), 20 ether + 20 ether + 20 ether);
        assertEq(vault.earned(carol), 30 ether + 30 ether);
        assertEq(imd.balanceOf(alice) + vault.earned(bob) + vault.earned(carol), 170 ether);
    }

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

    /// forge-config: default.fuzz.runs = 500
    function testFuzz_anyStakerCanAlwaysLeaveWithExactlyTheirStake(uint256 a, uint256 b, uint256 r, uint8 rounds)
        public
    {
        uint256 stakeA = bound(a, 1, 1_000 ether);
        uint256 stakeB = bound(b, 1, 1_000 ether);
        uint256 reward = bound(r, 0, 1e24);
        uint256 n = bound(uint256(rounds), 1, 6);
        vm.prank(alice);
        vault.stake(stakeA);
        for (uint256 i = 0; i < n; i++) {
            _reward(reward);
            if (i == 0) {
                vm.prank(bob);
                vault.stake(stakeB);
            }
        }
        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(token.balanceOf(alice), 1_000 ether, "alice got her stake back exactly");
        assertEq(token.balanceOf(bob), 1_000 ether, "bob too");
        assertEq(vault.totalStaked(), 0);
        assertLe(imd.balanceOf(alice) + imd.balanceOf(bob), reward * n, "cannot pay more than received");
        assertLe(imd.balanceOf(address(vault)), n * ((stakeA + stakeB) / 1e18 + 1) + 4, "dust only");
    }
}
