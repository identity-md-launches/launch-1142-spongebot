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

    function test_immutables() public view {
        assertEq(address(vault.stakingToken()), address(token));
        assertEq(address(vault.rewardToken()), address(imd));
        assertEq(vault.hook(), address(this));
    }

    function test_stakeUnstakeMovesTokens() public {
        vm.prank(alice);
        vault.stake(400 ether);
        assertEq(vault.totalStaked(), 400 ether);
        assertEq(vault.stakedBalance(alice), 400 ether);
        assertEq(token.balanceOf(address(vault)), 400 ether);

        vm.prank(alice);
        vault.unstake(150 ether);
        assertEq(vault.totalStaked(), 250 ether);
        assertEq(token.balanceOf(alice), 750 ether);
    }

    function test_rewardsProRataToStake() public {
        vm.prank(alice);
        vault.stake(100 ether);
        vm.prank(bob);
        vault.stake(300 ether);
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
        vm.prank(alice);
        vault.stake(100 ether);
        _reward(10 ether); // alice alone
        vm.prank(bob);
        vault.stake(100 ether);
        _reward(10 ether); // split
        assertEq(vault.earned(alice), 15 ether);
        assertEq(vault.earned(bob), 5 ether);
    }

    function test_unstakeKeepsEarnedRewards() public {
        vm.prank(alice);
        vault.stake(100 ether);
        _reward(7 ether);
        vm.prank(alice);
        vault.unstake(100 ether);
        assertEq(vault.earned(alice), 7 ether);
        _reward(0); // nothing staked: queued
        vm.prank(alice);
        vault.claim();
        assertEq(imd.balanceOf(alice), 7 ether);
    }

    function test_rewardsWhileNothingStakedAreKeptForNextStakers() public {
        _reward(5 ether);
        assertEq(vault.queuedRewards(), 5 ether);
        assertEq(vault.rewardPerTokenStored(), 0);

        vm.prank(bob);
        vault.stake(50 ether);
        assertEq(vault.earned(bob), 0);
        _reward(1 ether);
        assertEq(vault.queuedRewards(), 0);
        assertEq(vault.earned(bob), 6 ether);
    }

    function test_exitUnstakesAndClaims() public {
        vm.prank(alice);
        vault.stake(100 ether);
        _reward(3 ether);
        vm.prank(alice);
        vault.exit();
        assertEq(vault.stakedBalance(alice), 0);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(imd.balanceOf(alice), 3 ether);
    }

    function test_cannotUnstakeMoreThanStaked() public {
        vm.prank(alice);
        vault.stake(10 ether);
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
    function testFuzz_rewardsConserved(uint128 a, uint128 b, uint128 r1, uint128 r2) public {
        uint256 stakeA = bound(uint256(a), 1, 1_000 ether);
        uint256 stakeB = bound(uint256(b), 1, 3_000 ether);
        uint256 rewardOne = bound(uint256(r1), 0, 1e24);
        uint256 rewardTwo = bound(uint256(r2), 0, 1e24);

        vm.prank(alice);
        vault.stake(stakeA);
        _reward(rewardOne);
        vm.prank(bob);
        vault.stake(stakeB);
        _reward(rewardTwo);

        uint256 owed = vault.earned(alice) + vault.earned(bob);
        assertLe(owed, rewardOne + rewardTwo, "cannot owe more than received");
        // Each distribution loses under totalStaked / 1e18 wei to accumulator rounding, plus one wei per staker.
        uint256 maxDust = 2 * (vault.totalStaked() / 1e18 + 2);
        assertGe(owed + maxDust, rewardOne + rewardTwo, "dust bounded");

        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(address(vault)), 0, "all stake returned");
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), owed);
    }
}
