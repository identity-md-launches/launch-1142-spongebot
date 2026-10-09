// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SPONGEBOT} from "../src/SPONGEBOT.sol";

contract SPONGEBOTTest is Test {
    SPONGEBOT token;

    function setUp() public {
        token = new SPONGEBOT();
    }

    function test_metadata() public view {
        assertEq(token.name(), "SpongeBot");
        assertEq(token.symbol(), "SPONGEBOT");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_transfer() public {
        address bob = makeAddr("bob");
        assertTrue(token.transfer(bob, 5 ether));
        assertEq(token.balanceOf(bob), 5 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 5 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        address bob = makeAddr("bob");
        vm.prank(bob);
        vm.expectRevert(SPONGEBOT.InsufficientBalance.selector);
        token.transfer(address(this), 1);
    }

    function test_transferFromRespectsAllowance() public {
        address spender = makeAddr("spender");
        address bob = makeAddr("bob");
        token.approve(spender, 10 ether);
        vm.prank(spender);
        vm.expectRevert(SPONGEBOT.InsufficientAllowance.selector);
        token.transferFrom(address(this), bob, 11 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, 10 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        address spender = makeAddr("spender");
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), spender, 1 ether);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
    }

    function test_noMintOrAdminFunctions() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], address(this), uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, 1e27);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }
}
