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

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new SPONGEBOT();
        imd = new MockERC20("IMD", "IMD", 0);
        vault = new SpongeBotVault(address(token), address(imd), address(this));
        token.transfer(alice, 1_000 ether);
        token.transfer(bob, 3_000 ether);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
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
        assertEq(vault.currentEpoch(), 0);
        (uint256 start,,) = vault.epochs(0);
        assertEq(start, block.number);
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

    function test_rewardsProRataToStake() public {
        _stake(alice, 100 ether);
        _stake(bob, 300 ether);
        _roll(10);
        _reward(40 ether);
        assertEq(vault.earned(alice), 10 ether);
        assertEq(vault.earned(bob), 30 ether);

        vm.prank(alice);
        uint256 paid = vault.claim();
        assertEq(paid, 10 ether);
        assertEq(imd.balanceOf(alice), 10 ether);
        assertEq(vault.earned(alice), 0);
        // Claiming twice pays nothing more.
        vm.prank(alice);
        assertEq(vault.claim(), 0);
    }

    function test_rewardsProRataToTime() public {
        // Same stake, bob held it for a quarter of the epoch: he earns a quarter of what alice does.
        _stake(alice, 100 ether);
        _roll(30);
        _stake(bob, 100 ether);
        _roll(10);
        _reward(50 ether);
        assertEq(vault.earned(alice), 40 ether);
        assertEq(vault.earned(bob), 10 ether);
    }

    function test_rewardsProRataToStakeAndTime() public {
        // alice: 100 x 40 blocks = 4000 stake-blocks; bob: 300 x 10 blocks = 3000 stake-blocks.
        _stake(alice, 100 ether);
        _roll(30);
        _stake(bob, 300 ether);
        _roll(10);
        _reward(70 ether);
        assertEq(vault.earned(alice), 40 ether);
        assertEq(vault.earned(bob), 30 ether);
    }

    /// @notice The reopened finding: a stake that exists for zero blocks around a distribution earns nothing.
    function test_flashStakeAroundNotifyEarnsNothing() public {
        _stake(alice, 100 ether);
        _roll(100_000);

        // The bot stakes, the sweep notifies, the bot exits, all in one block.
        _stake(bob, 3_000 ether);
        _reward(100 ether);
        vm.prank(bob);
        vault.exit();

        assertEq(token.balanceOf(bob), 3_000 ether, "bot has its stake back");
        assertEq(imd.balanceOf(bob), 0, "zero blocks staked earns nothing");
        assertEq(vault.earned(alice), 100 ether, "the long-term staker gets the whole distribution");
    }

    function test_flashStakeOneBlockEarnsOneBlockShare() public {
        _stake(alice, 100 ether);
        _roll(999);
        _stake(bob, 3_000 ether);
        _roll(1);
        // alice: 100 x 1000 = 100_000 stake-blocks; bob: 3000 x 1 = 3_000.
        _reward(103 ether);
        assertEq(vault.earned(alice), 100 ether);
        assertEq(vault.earned(bob), 3 ether);
    }

    function test_stakeMidEpochThenUnstakeStillEarnsItsStakeBlocks() public {
        _stake(alice, 100 ether);
        _roll(10);
        _stake(bob, 100 ether);
        _roll(10);
        vm.prank(bob);
        vault.unstake(100 ether);
        _roll(10);
        // alice: 100 x 30; bob: 100 x 10.
        _reward(40 ether);
        assertEq(vault.earned(alice), 30 ether);
        assertEq(vault.earned(bob), 10 ether);
        assertEq(vault.stakedBalance(bob), 0);
        vm.prank(bob);
        vault.claim();
        assertEq(imd.balanceOf(bob), 10 ether);
    }

    function test_unstakeKeepsEarnedRewards() public {
        _stake(alice, 100 ether);
        _roll(5);
        _reward(7 ether);
        vm.prank(alice);
        vault.unstake(100 ether);
        assertEq(vault.earned(alice), 7 ether);
        _roll(5);
        _reward(0); // nothing staked: queued
        vm.prank(alice);
        vault.claim();
        assertEq(imd.balanceOf(alice), 7 ether);
    }

    function test_rewardsWhileNothingStakedAreKeptForNextStakers() public {
        _reward(5 ether);
        assertEq(vault.queuedRewards(), 5 ether);
        assertEq(vault.currentEpoch(), 0);

        _stake(bob, 50 ether);
        assertEq(vault.earned(bob), 0);
        _roll(3);
        _reward(1 ether);
        assertEq(vault.queuedRewards(), 0);
        assertEq(vault.currentEpoch(), 1);
        assertEq(vault.earned(bob), 6 ether);
    }

    function test_rewardInTheStakingBlockIsQueuedNotDistributed() public {
        _stake(alice, 100 ether);
        _reward(5 ether); // zero stake-blocks so far
        assertEq(vault.queuedRewards(), 5 ether);
        assertEq(vault.earned(alice), 0);
        _roll(1);
        _reward(1 ether);
        assertEq(vault.earned(alice), 6 ether);
    }

    function test_lazySettlementAcrossManyEpochs() public {
        // alice never touches the vault while bob comes and goes over several distributions.
        _stake(alice, 100 ether);
        _roll(10);
        _reward(10 ether); // epoch 0: alice alone -> 10
        _stake(bob, 100 ether);
        _roll(10);
        _reward(10 ether); // epoch 1: split -> 5 / 5
        vm.prank(bob);
        vault.exit();
        _roll(10);
        _reward(10 ether); // epoch 2: alice alone -> 10
        _stake(bob, 300 ether);
        _roll(10);
        _reward(40 ether); // epoch 3: 100 vs 300 -> 10 / 30
        _roll(10); // open epoch 4, nothing distributed yet

        assertEq(vault.currentEpoch(), 4);
        assertEq(vault.earned(alice), 35 ether);
        assertEq(vault.earned(bob), 30 ether, "bob's 5 from epoch 1 was paid at his exit");
        assertEq(imd.balanceOf(bob), 5 ether);

        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(alice), 35 ether);
        assertEq(imd.balanceOf(bob), 35 ether);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_pointsViewsTrackStakeBlocks() public {
        _stake(alice, 100 ether);
        _roll(4);
        assertEq(vault.points(alice), 400 ether);
        assertEq(vault.currentTotalPoints(), 400 ether);
        _stake(bob, 50 ether);
        _roll(2);
        assertEq(vault.points(alice), 600 ether);
        assertEq(vault.points(bob), 100 ether);
        assertEq(vault.currentTotalPoints(), 700 ether);
        _reward(7 ether);
        assertEq(vault.points(alice), 0);
        assertEq(vault.currentTotalPoints(), 0);
        _roll(1);
        assertEq(vault.points(alice), 100 ether);
        assertEq(vault.points(bob), 50 ether);
    }

    function test_rateRoundingRemainderIsQueued() public {
        _stake(alice, 3 ether);
        _roll(1);
        // 3e18 stake-blocks, 10 wei: rate = floor(10e18 / 3e18) = 3, distributes 9, queues 1.
        _reward(10);
        assertEq(vault.earned(alice), 9);
        assertEq(vault.queuedRewards(), 1);
        _roll(1);
        _reward(2); // 1 queued + 2 = 3 over 3e18 stake-blocks: exact
        assertEq(vault.earned(alice), 12);
        assertEq(vault.queuedRewards(), 0);
    }

    function test_subWeiRemainderStaysInVaultNotQueued() public {
        _stake(alice, 3);
        _roll(1);
        // 3 stake-blocks, 10 wei: rate = floor(10e18 / 3), exact share 9.999...; booked ceil = 10, nothing queued,
        // alice's floor is 9 and the last wei is unclaimable dust rather than something owed twice.
        _reward(10);
        assertEq(vault.earned(alice), 9);
        assertEq(vault.queuedRewards(), 0);
        vm.prank(alice);
        vault.claim();
        assertEq(imd.balanceOf(address(vault)), 1);
    }

    /// @notice Claims can never exceed what the vault holds, even when remainders are re-queued over many epochs.
    function test_solventAcrossRequeuedRemainders() public {
        _stake(alice, 3);
        _stake(bob, 3);
        for (uint256 i = 0; i < 20; i++) {
            _roll(1);
            _reward(10 + i);
        }
        uint256 owed = vault.earned(alice) + vault.earned(bob);
        assertLe(owed + vault.queuedRewards(), imd.balanceOf(address(vault)));
        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), owed);
    }

    function test_wholeSupplyStakedForLongIsNotOverpaid() public {
        address whale = makeAddr("whale");
        token.transfer(whale, token.balanceOf(address(this)));
        vm.startPrank(whale);
        token.approve(address(vault), type(uint256).max);
        vault.stake(token.balanceOf(whale));
        vm.stopPrank();
        _roll(2_500_000);
        _reward(1e9 - 1);
        assertLe(vault.earned(whale), 1e9 - 1);
        assertEq(vault.earned(whale) + vault.queuedRewards(), 1e9 - 1);
        _roll(1);
        _reward(1_000 ether);
        assertLe(vault.earned(whale), 1_000 ether + 1e9 - 1);
        vm.prank(whale);
        vault.claim();
        assertEq(imd.balanceOf(whale) + vault.queuedRewards(), 1_000 ether + 1e9 - 1);
    }

    function test_exitUnstakesAndClaims() public {
        _stake(alice, 100 ether);
        _roll(1);
        _reward(3 ether);
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
    function testFuzz_rewardsConserved(uint128 a, uint128 b, uint128 r1, uint128 r2, uint8 t1, uint8 t2) public {
        uint256 stakeA = bound(uint256(a), 1, 1_000 ether);
        uint256 stakeB = bound(uint256(b), 1, 3_000 ether);
        uint256 rewardOne = bound(uint256(r1), 0, 1e24);
        uint256 rewardTwo = bound(uint256(r2), 0, 1e24);

        _stake(alice, stakeA);
        _roll(t1);
        _reward(rewardOne);
        _stake(bob, stakeB);
        _roll(t2);
        _reward(rewardTwo);

        uint256 owed = vault.earned(alice) + vault.earned(bob);
        uint256 received = rewardOne + rewardTwo;
        assertLe(owed + vault.queuedRewards(), received, "cannot owe more than received");
        // Under one wei per distribution plus one wei per account per settlement; the rate's remainder is queued.
        assertGe(owed + vault.queuedRewards() + 8, received, "dust bounded");

        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(address(vault)), 0, "all stake returned");
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), owed);
    }

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_zeroBlockStakeNeverEarns(uint128 bag, uint64 wait, uint128 reward) public {
        uint256 bot = bound(uint256(bag), 1, 3_000 ether);
        uint256 blocks = bound(uint256(wait), 1, 1_000_000);
        uint256 amount = bound(uint256(reward), 1, 1e24);

        _stake(alice, 100 ether);
        _roll(blocks);
        _stake(bob, bot);
        _reward(amount);
        vm.prank(bob);
        vault.exit();
        assertEq(imd.balanceOf(bob), 0);
        assertEq(vault.earned(bob), 0);
        assertLe(vault.earned(alice) + vault.queuedRewards(), amount);
        assertGe(vault.earned(alice) + vault.queuedRewards() + 2, amount);
    }
}
