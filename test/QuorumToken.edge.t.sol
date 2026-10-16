// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {QuorumToken} from "../src/QuorumToken.sol";

/// @notice Edge cases and failure paths of Quorum (QRM): zero amounts, exact balances, one wei over,
/// self-transfers, allowance boundaries, the absent admin surface, and refused ETH.
/// @dev Builds on `QuorumToken.t.sol`, which covers the main paths; nothing here repeats it.
/// forge-config: default.fuzz.runs = 1000
contract QuorumTokenEdgeTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    QuorumToken token;
    address deployer = address(0xD0);
    address alice = address(0xA1);
    address bob = address(0xB0);
    address carol = address(0xC0);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new QuorumToken();
    }

    // ---------------------------------------------------------------- supply and metadata

    function test_constantMatchesMintedSupply() public view {
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
        assertEq(token.balanceOf(address(0)), 0, "nothing minted to the zero address");
        assertEq(token.balanceOf(address(token)), 0, "nothing minted to the token itself");
    }

    function test_decimalsIsEighteen() public view {
        assertEq(uint256(token.decimals()), 18);
        assertEq(SUPPLY, 1_000_000_000 * 10 ** uint256(token.decimals()));
    }

    /// @dev Two deployments are independent: each mints the whole supply to its own deployer and
    /// neither sees the other's balances.
    function test_secondDeploymentIsIndependent() public {
        vm.prank(alice);
        QuorumToken other = new QuorumToken();
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);

        vm.prank(alice);
        other.transfer(bob, 1);
        assertEq(token.balanceOf(bob), 0, "a transfer on one token leaked into the other");
    }

    // ---------------------------------------------------------------- transfer edges

    function test_transferZeroFromEmptyAccountSucceedsAndEmits() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferZeroToZeroAddressStillReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_transferExactBalanceDrainsToZero() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);

        // Now the deployer is empty and even one wei fails with the exact error.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferOneWeiOverBalanceReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientBalance.selector, alice, 100, 101));
        token.transfer(bob, 101);
        assertEq(token.balanceOf(alice), 100, "a reverted transfer changed a balance");
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferMaxUintReverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(QuorumToken.InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_selfTransferLeavesBalanceUnchanged() public {
        vm.prank(deployer);
        token.transfer(alice, 1000);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(alice, alice, 1000);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 1000));
        assertEq(token.balanceOf(alice), 1000, "self-transfer of the full balance changed it");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferOverBalanceReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 1000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientBalance.selector, alice, 1000, 1001));
        token.transfer(alice, 1001);
    }

    function test_transferToTokenContractIsAllowedAndStuck() public {
        // Nothing forbids sending to the token itself; the tokens are simply unrecoverable, since the
        // token has no function that moves its own balance. Documented, not a defect of a plain ERC-20.
        vm.prank(deployer);
        token.transfer(address(token), 5);
        assertEq(token.balanceOf(address(token)), 5);
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", deployer, 5));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 5);
    }

    function test_transferEmitsExactEvent() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, alice, 123);
        vm.prank(deployer);
        token.transfer(alice, 123);
    }

    function test_sameTransferTwiceMovesTwice() public {
        vm.startPrank(deployer);
        token.transfer(alice, 7);
        token.transfer(alice, 7);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 14);
        assertEq(token.balanceOf(deployer), SUPPLY - 14);
    }

    // ---------------------------------------------------------------- approve edges

    function test_approveEmitsApproval() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(deployer, alice, 42);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 42));
        assertEq(token.allowance(deployer, alice), 42);
    }

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(deployer);
        token.approve(alice, 100);
        token.approve(alice, 30);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 30, "approve must overwrite, not accumulate");
    }

    function test_approveZeroResetsAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 100);
        token.approve(alice, 0);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_approveDoesNotRequireBalance() public {
        // An empty account may approve more than exists; the balance check happens at transferFrom.
        vm.prank(alice);
        assertTrue(token.approve(bob, SUPPLY + 1));
        assertEq(token.allowance(alice, bob), SUPPLY + 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    function test_approveSelfIsAllowed() public {
        vm.startPrank(deployer);
        token.approve(deployer, 10);
        assertTrue(token.transferFrom(deployer, alice, 10));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    function test_approveZeroSpenderWithZeroValueStillReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
    }

    function test_allowanceIsDirectional() public {
        vm.prank(deployer);
        token.approve(alice, 50);
        assertEq(token.allowance(alice, deployer), 0, "allowance leaked in the reverse direction");
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    // ---------------------------------------------------------------- transferFrom edges

    function test_transferFromWithoutApprovalReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromOwnBalanceWithoutSelfApprovalReverts() public {
        // transferFrom does not exempt the owner: without a self-approval, it fails like any spender.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function test_transferFromZeroWithoutApprovalSucceeds() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, bob, 0);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromExactAllowanceConsumesItFully() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.startPrank(alice);
        assertTrue(token.transferFrom(deployer, bob, 10));
        assertEq(token.allowance(deployer, alice), 0);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 10);
    }

    function test_transferFromOneUnderMaxAllowanceIsDecremented() public {
        // Only exactly type(uint256).max is infinite; max - 1 is an ordinary allowance.
        uint256 almost = type(uint256).max - 1;
        vm.prank(deployer);
        token.approve(alice, almost);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 5);
        assertEq(token.allowance(deployer, alice), almost - 5);
    }

    function test_transferFromInfiniteAllowanceStillChecksBalance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, carol, 1);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_transferFromInfiniteAllowanceCanDrainFullBalance() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, alice, SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromToZeroRevertsAndKeepsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 5);
        assertEq(token.allowance(deployer, alice), 10, "a reverted transferFrom consumed allowance");
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFromOverBalanceRevertsAndKeepsAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100);
        vm.prank(alice);
        token.approve(bob, 1000);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientBalance.selector, alice, 100, 101));
        token.transferFrom(alice, carol, 101);
        assertEq(token.allowance(alice, bob), 1000, "a reverted transferFrom consumed allowance");
        assertEq(token.balanceOf(alice), 100);
    }

    function test_transferFromAllowanceCheckPrecedesBalanceCheck() public {
        // Empty owner, allowance 5, request 10: the allowance error is reported, not the balance one.
        vm.prank(alice);
        token.approve(bob, 5);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientAllowance.selector, bob, 5, 10));
        token.transferFrom(alice, carol, 10);
    }

    function test_transferFromEmitsTransferFromOwnerNotSpender() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, bob, 10);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 10);
    }

    function test_transferFromToSelfBySpenderIsAllowed() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(alice);
        token.transferFrom(deployer, alice, 10);
        assertEq(token.balanceOf(alice), 10);
    }

    function test_transferFromRoundTripOwnerToOwner() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(alice);
        token.transferFrom(deployer, deployer, 10);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, alice), 0, "the self-transfer did not spend allowance");
    }

    // ---------------------------------------------------------------- no admin surface, no ETH

    function test_tokenRefusesEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "the token accepted ETH");
        assertEq(address(token).balance, 0);

        vm.prank(alice);
        (ok,) = address(token).call{value: 1}(abi.encodeWithSelector(token.transfer.selector, bob, 0));
        assertFalse(ok, "a non-payable function accepted ETH");
    }

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        (ok,) = address(token).call(hex"");
        assertFalse(ok, "the token has a fallback");
    }

    /// @dev Every common privileged call reverts, from a stranger and from the deployer, and none of
    /// them changes supply or any balance.
    function test_noAdminFunctionExists() public {
        vm.prank(deployer);
        token.transfer(alice, 1000);
        uint256 supplyBefore = token.totalSupply();
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 deployerBefore = token.balanceOf(deployer);

        string[22] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burn(address,uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "paused()",
            "blacklist(address)",
            "setBlacklist(address,bool)",
            "freeze(address)",
            "seize(address)",
            "setFee(uint256)",
            "setTaxRate(uint256)",
            "excludeFromFee(address)",
            "setTransfersEnabled(bool)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        address[2] memory callers = [address(0xBEEF), deployer];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], alice, 1);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(token.balanceOf(deployer), deployerBefore);
        assertEq(token.balanceOf(address(0xBEEF)), 0);
    }

    /// @dev Mirrors the launch floor's opcode scan: no DELEGATECALL, CALLCODE or SELFDESTRUCT.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------- fuzz: arithmetic at the edges

    function testFuzz_transferWithinBalanceMovesExactly(address to, uint256 seed, uint256 amount) public {
        to = _nonZero(to);
        uint256 give = bound(seed, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, give);
        amount = bound(amount, 0, give);

        uint256 toBefore = token.balanceOf(to);
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        assertTrue(token.transfer(to, amount));
        if (to == alice) {
            assertEq(token.balanceOf(alice), aliceBefore);
        } else {
            assertEq(token.balanceOf(alice), aliceBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferOverBalanceRevertsWithExactArgs(address to, uint256 balance, uint256 over) public {
        to = _nonZero(to);
        balance = bound(balance, 0, SUPPLY - 1);
        over = bound(over, balance + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, balance);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientBalance.selector, alice, balance, over));
        token.transfer(to, over);
        assertEq(token.balanceOf(alice), balance);
    }

    function testFuzz_selfTransferIsIdentity(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, 0, balance);
        vm.prank(deployer);
        token.transfer(alice, balance);
        vm.prank(alice);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(deployer), SUPPLY - balance);
    }

    function testFuzz_approveIsIdempotentAndOverwrites(address spender, uint256 a, uint256 b) public {
        spender = _nonZero(spender);
        vm.startPrank(deployer);
        token.approve(spender, a);
        token.approve(spender, a);
        assertEq(token.allowance(deployer, spender), a);
        token.approve(spender, b);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), b);
        if (spender != deployer) assertEq(token.allowance(spender, deployer), 0);
    }

    function testFuzz_finiteAllowanceDecrementsExactly(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        amount = bound(amount, 0, allowed < SUPPLY ? allowed : SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        token.transferFrom(deployer, bob, amount);
        assertEq(token.allowance(deployer, alice), allowed - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
    }

    function testFuzz_transferFromOverAllowanceRevertsWithExactArgs(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 2);
        amount = bound(amount, allowed + 1, type(uint256).max - 1);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuorumToken.InsufficientAllowance.selector, alice, allowed, amount));
        token.transferFrom(deployer, bob, amount);
        assertEq(token.allowance(deployer, alice), allowed);
    }

    function testFuzz_infiniteAllowanceNeverDecrements(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, amount);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), amount);
    }

    /// @dev A chain of hops through several holders ends with the supply exactly where the hops say.
    function testFuzz_multiHopConservesSupply(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(carol, c);
        assertEq(token.balanceOf(deployer), SUPPLY - a);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(carol), c);
        assertEq(
            token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol), SUPPLY
        );
    }

    function testFuzz_roundTripRestoresBalances(address other, uint256 amount) public {
        other = _nonZero(other);
        if (other == deployer) other = alice;
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(other, amount);
        vm.prank(other);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(other), 0);
    }

    function _nonZero(address a) private pure returns (address) {
        return a == address(0) ? address(1) : a;
    }
}
