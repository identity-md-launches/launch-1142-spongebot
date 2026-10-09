// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SPONGEBOT} from "../src/SPONGEBOT.sol";
import {SpongeBotVault} from "../src/SpongeBotVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Unit tests of the staking vault with the test contract standing in for the hook.
contract SpongeBotVaultTest is Test {
    SPONGEBOT token;
    MockERC20 imd;
    SpongeBotVault vault;
    uint256 DURATION;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new SPONGEBOT();
        imd = new MockERC20("IMD", "IMD", 0);
        vault = new SpongeBotVault(address(token), address(imd), address(this));
        DURATION = vault.REWARD_DURATION();
        token.transfer(alice, 1_000 ether);
        token.transfer(bob, 3_000 ether);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.roll(1_000);
    }

    /// @dev Mirrors what the hook does in sweep(): transfer, then notify.
    function _reward(uint256 amount) internal {
        imd.mint(address(vault), amount);
        vault.notifyReward(amount);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        vault.stake(amount);
    }

    function _roll(uint256 blocks) internal {
        vm.roll(block.number + blocks);
    }

    function test_immutables() public view {
        assertEq(address(vault.stakingToken()), address(token));
        assertEq(address(vault.rewardToken()), address(imd));
        assertEq(vault.hook(), address(this));
        assertEq(vault.REWARD_DURATION(), 7_200);
        assertEq(vault.rewardRate(), 0);
        assertEq(vault.streamEnd(), 0);
    }

    function test_stakeUnstakeMovesTokens() public {
        _stake(alice, 400 ether);
        assertEq(vault.totalStaked(), 400 ether);
        assertEq(vault.stakedBalance(alice), 400 ether);
        assertEq(token.balanceOf(address(vault)), 400 ether);

        vm.prank(alice);
        vault.unstake(150 ether);
        assertEq(vault.totalStaked(), 250 ether);
        assertEq(token.balanceOf(alice), 750 ether);
    }

    function test_rewardStreamsOverDuration() public {
        _stake(alice, 100 ether);
        _reward(DURATION * 1 ether);
        assertEq(vault.earned(alice), 0, "nothing is paid in the distribution block");
        assertEq(vault.unstreamedRewards(), DURATION * 1 ether);
        assertEq(vault.streamEnd(), block.number + DURATION);

        _roll(1);
        assertEq(vault.earned(alice), 1 ether, "one block of the stream");
        _roll(DURATION / 2 - 1);
        assertEq(vault.earned(alice), DURATION / 2 * 1 ether, "half way");
        _roll(DURATION);
        assertEq(vault.earned(alice), DURATION * 1 ether, "the stream ends and pays no more");
        assertEq(vault.unstreamedRewards(), 0);

        vm.prank(alice);
        uint256 paid = vault.claim();
        assertEq(paid, DURATION * 1 ether);
        assertEq(imd.balanceOf(alice), DURATION * 1 ether);
        assertEq(vault.earned(alice), 0);
        vm.prank(alice);
        assertEq(vault.claim(), 0, "claiming twice pays nothing more");
    }

    function test_rewardsProRataToStake() public {
        _stake(alice, 100 ether);
        _stake(bob, 300 ether);
        _reward(DURATION * 4 ether);
        _roll(10);
        assertEq(vault.earned(alice), 10 ether);
        assertEq(vault.earned(bob), 30 ether);
    }

    function test_rewardsProRataToTime() public {
        // Same stake, bob joins a quarter of the way through: he earns a quarter of what alice does.
        _stake(alice, 100 ether);
        _reward(DURATION * 1 ether);
        _roll(30);
        _stake(bob, 100 ether);
        _roll(10);
        assertEq(vault.earned(alice), 35 ether);
        assertEq(vault.earned(bob), 5 ether);
    }

    function test_rewardsProRataToStakeAndTime() public {
        _stake(alice, 100 ether);
        _reward(DURATION * 4 ether);
        _roll(30); // alice alone: 120
        _stake(bob, 300 ether);
        _roll(10); // 40 split 1:3 -> 10 / 30
        assertEq(vault.earned(alice), 130 ether);
        assertEq(vault.earned(bob), 30 ether);
    }

    /// @notice The reopened finding: a large stake held one block around a distribution captures only one
    /// block of the stream, not the backlog that accrued while others were the only stakers.
    function test_oneBlockWhaleStakeCapturesOneBlockOnly() public {
        address whale = makeAddr("whale");
        token.transfer(whale, 900_000 ether);
        vm.prank(whale);
        token.approve(address(vault), type(uint256).max);

        _stake(alice, 100 ether);
        _roll(1_000); // 1000 IMD of fees accrue in the hook meanwhile, nobody swept
        _stake(whale, 900_000 ether);
        _roll(1);
        _reward(1_000 ether);
        vm.prank(whale);
        vault.exit();

        assertEq(imd.balanceOf(whale), 0, "exit in the distribution block earns nothing");
        assertEq(token.balanceOf(whale), 900_000 ether);
        _roll(DURATION);
        assertApproxEqAbs(vault.earned(alice), 1_000 ether, 1, "alice receives the whole distribution");
    }

    function test_oneBlockWhaleStakeAfterDistributionEarnsOneBlockShare() public {
        address whale = makeAddr("whale");
        token.transfer(whale, 900_000 ether);
        vm.prank(whale);
        token.approve(address(vault), type(uint256).max);

        _stake(alice, 100 ether);
        _roll(1_000);
        _reward(1_000 ether);
        _stake(whale, 900_000 ether);
        _roll(1);
        vm.prank(whale);
        vault.exit();

        // One block of the stream (1000 / 7200) at a 9000:1 weight: about 0.139 IMD of 1000.
        uint256 perBlock = 1_000 ether / DURATION;
        assertApproxEqAbs(imd.balanceOf(whale), perBlock * 9_000 / 9_001, 1e6);
        assertLe(imd.balanceOf(whale), 1_000 ether / DURATION);
        _roll(DURATION);
        assertApproxEqAbs(vault.earned(alice) + imd.balanceOf(whale), 1_000 ether, 1e6);
    }

    function test_flashStakeAroundNotifyEarnsNothing() public {
        _stake(alice, 100 ether);
        _roll(100_000);
        _stake(bob, 3_000 ether);
        _reward(100 ether);
        vm.prank(bob);
        vault.exit();
        assertEq(token.balanceOf(bob), 3_000 ether, "bot has its stake back");
        assertEq(imd.balanceOf(bob), 0, "zero blocks staked earns nothing");
        _roll(DURATION);
        assertApproxEqAbs(vault.earned(alice), 100 ether, 1, "the long-term staker gets the whole distribution");
    }

    function test_stakeMidStreamThenUnstakeEarnsItsBlocks() public {
        _stake(alice, 100 ether);
        _reward(DURATION * 2 ether);
        _roll(10);
        _stake(bob, 100 ether);
        _roll(10);
        vm.prank(bob);
        vault.unstake(100 ether);
        _roll(10);
        // alice: 20 alone + 10 shared = 30; bob: 10 shared.
        assertEq(vault.earned(alice), 50 ether);
        assertEq(vault.earned(bob), 10 ether);
        assertEq(vault.stakedBalance(bob), 0);
        vm.prank(bob);
        vault.claim();
        assertEq(imd.balanceOf(bob), 10 ether);
    }

    function test_unstakeKeepsEarnedRewards() public {
        _stake(alice, 100 ether);
        _reward(DURATION * 1 ether);
        _roll(5);
        vm.prank(alice);
        vault.unstake(100 ether);
        assertEq(vault.earned(alice), 5 ether);
        _roll(5);
        assertEq(vault.earned(alice), 5 ether, "nothing earned while unstaked");
        vm.prank(alice);
        vault.claim();
        assertEq(imd.balanceOf(alice), 5 ether);
    }

    /// @notice Rewards that arrive while nothing is staked are kept for the next stakers: the stream pauses.
    function test_rewardsWhileNothingStakedAreKeptForNextStakers() public {
        _reward(DURATION * 1 ether);
        assertEq(vault.unstreamedRewards(), DURATION * 1 ether);
        _roll(50_000); // far beyond the nominal stream end, nobody staked
        assertEq(vault.unstreamedRewards(), DURATION * 1 ether, "nothing streamed to nobody");

        _stake(bob, 50 ether);
        assertEq(vault.streamEnd(), block.number + DURATION, "the stream resumes in full");
        assertEq(vault.earned(bob), 0);
        _roll(3);
        assertEq(vault.earned(bob), 3 ether);
        _roll(DURATION);
        assertEq(vault.earned(bob), DURATION * 1 ether, "bob gets everything, no further call needed");
    }

    function test_streamPausesWhenEveryoneLeavesAndResumes() public {
        _stake(alice, 100 ether);
        _reward(DURATION * 1 ether);
        _roll(100);
        vm.prank(alice);
        vault.exit();
        assertEq(imd.balanceOf(alice), 100 ether);
        assertEq(vault.unstreamedRewards(), (DURATION - 100) * 1 ether);
        _roll(10_000);
        assertEq(vault.unstreamedRewards(), (DURATION - 100) * 1 ether, "paused");
        _stake(bob, 1);
        _roll(DURATION);
        assertEq(vault.earned(bob), (DURATION - 100) * 1 ether, "the rest goes to the next staker");
    }

    /// @notice The queue variant of the finding: a 1 wei stake for one block takes one block of the stream.
    function test_tinyStakeAfterIdleRewardsTakesOneBlockOnly() public {
        _reward(5_000 ether);
        _stake(bob, 1);
        _roll(1);
        _reward(1);
        assertApproxEqAbs(vault.earned(bob), 5_000 ether / DURATION, 1);
        assertLt(vault.earned(bob), 1 ether);
    }

    function test_notifyMidStreamRollsLeftoverIntoNewStream() public {
        _stake(alice, 100 ether);
        _reward(DURATION * 1 ether);
        _roll(DURATION / 2);
        assertEq(vault.earned(alice), DURATION / 2 * 1 ether);
        _reward(DURATION / 2 * 1 ether);
        // Leftover half plus the new half: one per block again, over a fresh full window.
        assertEq(vault.streamEnd(), block.number + DURATION);
        assertEq(vault.unstreamedRewards(), DURATION * 1 ether);
        _roll(DURATION);
        assertEq(vault.earned(alice), DURATION / 2 * 1 ether + DURATION * 1 ether);
    }

    function test_rewardsConservedAcrossManyStreams() public {
        _stake(alice, 100 ether);
        _roll(10);
        _reward(10 ether);
        _stake(bob, 100 ether);
        _roll(10);
        _reward(10 ether);
        vm.prank(bob);
        vault.exit();
        _roll(10);
        _reward(10 ether);
        _stake(bob, 300 ether);
        _roll(10);
        _reward(40 ether);
        _roll(2 * DURATION);

        uint256 owed = vault.earned(alice) + vault.earned(bob) + imd.balanceOf(bob);
        assertApproxEqAbs(owed, 70 ether, 10, "everything streamed within dust");
        assertLe(owed, 70 ether);
        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), owed);
        assertLe(imd.balanceOf(address(vault)), 10, "only dust stays");
    }

    function test_wholeSupplyStakedForLongIsNotOverpaid() public {
        address whale = makeAddr("whale");
        token.transfer(whale, token.balanceOf(address(this)));
        vm.startPrank(whale);
        token.approve(address(vault), type(uint256).max);
        vault.stake(token.balanceOf(whale));
        vm.stopPrank();
        _reward(1e9 - 1);
        _roll(2_500_000);
        assertLe(vault.earned(whale), 1e9 - 1);
        assertApproxEqAbs(vault.earned(whale), 1e9 - 1, 1);
        _reward(1_000 ether);
        _roll(DURATION);
        assertLe(vault.earned(whale), 1_000 ether + 1e9 - 1);
        vm.prank(whale);
        vault.claim();
        assertApproxEqAbs(imd.balanceOf(whale), 1_000 ether + 1e9 - 1, 2);
    }

    function test_exitUnstakesAndClaims() public {
        _stake(alice, 100 ether);
        _reward(DURATION * 1 ether);
        _roll(3);
        vm.prank(alice);
        vault.exit();
        assertEq(vault.stakedBalance(alice), 0);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(imd.balanceOf(alice), 3 ether);
    }

    function test_cannotUnstakeMoreThanStaked() public {
        _stake(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(SpongeBotVault.InsufficientStake.selector);
        vault.unstake(11 ether);
        // Nobody else can move alice's stake.
        vm.prank(bob);
        vm.expectRevert(SpongeBotVault.InsufficientStake.selector);
        vault.unstake(1);
    }

    function test_zeroAmountsRevert() public {
        vm.prank(alice);
        vm.expectRevert(SpongeBotVault.ZeroAmount.selector);
        vault.stake(0);
        vm.prank(alice);
        vm.expectRevert(SpongeBotVault.ZeroAmount.selector);
        vault.unstake(0);
    }

    function test_onlyHookNotifies() public {
        vm.prank(alice);
        vm.expectRevert(SpongeBotVault.NotHook.selector);
        vault.notifyReward(1);
    }

    function test_stakeWithoutApprovalReverts() public {
        address carol = makeAddr("carol");
        token.transfer(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert(SpongeBotVault.TransferFailed.selector);
        vault.stake(1 ether);
    }

    function test_noAdminFunctions() public {
        string[5] memory sigs = [
            "transferOwnership(address)",
            "setHook(address)",
            "withdraw(address,uint256)",
            "recoverERC20(address,uint256)",
            "pause()"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(vault).call(abi.encodeWithSignature(sigs[i], address(this), uint256(1)));
            assertFalse(ok, sigs[i]);
        }
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_rewardsConserved(uint128 a, uint128 b, uint128 r1, uint128 r2, uint16 t1, uint16 t2) public {
        uint256 stakeA = bound(uint256(a), 1, 1_000 ether);
        uint256 stakeB = bound(uint256(b), 1, 3_000 ether);
        uint256 rewardOne = bound(uint256(r1), 0, 1e24);
        uint256 rewardTwo = bound(uint256(r2), 0, 1e24);

        _stake(alice, stakeA);
        _reward(rewardOne);
        _roll(t1);
        _stake(bob, stakeB);
        _reward(rewardTwo);
        _roll(t2);

        uint256 owed = vault.earned(alice) + vault.earned(bob);
        uint256 received = rewardOne + rewardTwo;
        assertLe(owed + vault.unstreamedRewards(), received, "cannot owe more than received");
        assertGe(owed + vault.unstreamedRewards() + 4, received, "dust bounded");

        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(address(vault)), 0, "all stake returned");
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), owed);
        assertGe(imd.balanceOf(address(vault)), vault.unstreamedRewards(), "the rest is still held");
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_shortStakeEarnsAtMostItsBlocks(uint128 bag, uint64 wait, uint128 reward, uint8 held) public {
        uint256 bot = bound(uint256(bag), 1, 3_000 ether);
        uint256 blocks = bound(uint256(wait), 1, 1_000_000);
        uint256 amount = bound(uint256(reward), 1, 1e24);
        uint256 heldBlocks = bound(uint256(held), 0, 10);

        _stake(alice, 100 ether);
        _roll(blocks);
        _stake(bob, bot);
        _roll(heldBlocks);
        _reward(amount);
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(bob), 0, "exit in the distribution block earns nothing from it");

        _stake(bob, bot);
        _roll(heldBlocks);
        vm.prank(bob);
        vault.exit();
        // At most `heldBlocks` blocks of the stream, whatever the bag.
        assertLe(imd.balanceOf(bob), amount * heldBlocks / DURATION + 1);
        _roll(DURATION);
        assertLe(vault.earned(alice) + imd.balanceOf(bob), amount);
        assertGe(vault.earned(alice) + imd.balanceOf(bob) + 4, amount);
    }
}
