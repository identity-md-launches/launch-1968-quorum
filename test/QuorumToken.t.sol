// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {QuorumToken} from "../src/QuorumToken.sol";

contract QuorumTokenTest is Test {
    QuorumToken token;
    address deployer = address(0xD0);
    address alice = address(0xA1);
    address bob = address(0xB0);

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new QuorumToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Quorum");
        assertEq(token.symbol(), "QRM");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(deployer), 1_000_000_000e18);
    }

    function test_constructorEmitsMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, 1_000_000_000e18);
        vm.prank(alice);
        new QuorumToken();
    }

    function test_transfer() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 100));
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(deployer), token.totalSupply() - 100);
    }

    function test_transferInsufficientReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        token.approve(alice, 50);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 30);
        assertEq(token.balanceOf(bob), 30);
        assertEq(token.allowance(deployer, alice), 20);
    }

    function test_infiniteAllowanceNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 30);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromOverAllowanceReverts() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientAllowance.selector, alice, 10, 11));
        token.transferFrom(deployer, bob, 11);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_noMintFunction() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, token.totalSupply());
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), token.totalSupply());
    }
}
