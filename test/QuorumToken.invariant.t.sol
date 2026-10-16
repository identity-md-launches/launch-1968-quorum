// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {QuorumToken} from "../src/QuorumToken.sol";

/// @notice Drives Quorum (QRM) with random call sequences from a closed set of actors and keeps a
/// ghost ledger of what every balance and allowance should be. Successful calls are bounded so they
/// never revert; the failure paths are exercised deliberately and must revert with the exact error.
contract QuorumHandler is Test {
    QuorumToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    mapping(address => uint256) public ghostSent;
    mapping(address => uint256) public ghostReceived;

    uint256 public transfers;
    uint256 public transfersFrom;
    uint256 public approvals;
    uint256 public expectedReverts;
    uint256 public totalMoved;

    constructor(QuorumToken token_, address deployer, address[] memory others) {
        token = token_;
        actors.push(deployer);
        for (uint256 i; i < others.length; ++i) {
            actors.push(others[i]);
        }
        ghostBalance[deployer] = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------- successful paths

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        _recordMove(from, to, amount);
        transfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");

        ghostAllowance[owner][spender] = amount;
        approvals++;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 cap = token.balanceOf(from);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        bool ok = token.transferFrom(from, to, amount);
        assertTrue(ok, "transferFrom returned false");

        if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        _recordMove(from, to, amount);
        transfersFrom++;
    }

    // ---------------------------------------------------------------- failure paths, must revert

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - bal);
        uint256 amount = bal + excess;

        vm.prank(from);
        try token.transfer(to, amount) {
            assertTrue(false, "transfer over balance did not revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(QuorumToken.InsufficientBalance.selector, from, bal, amount));
        }
        expectedReverts++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        try token.transfer(address(0), amount) {
            assertTrue(false, "transfer to the zero address did not revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(QuorumToken.InvalidReceiver.selector, address(0)));
        }
        expectedReverts++;
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[from][spender];
        if (allowed == type(uint256).max) {
            // Infinite allowance cannot be exceeded; shrink it first so the failure path is reachable.
            allowed = bound(excess, 0, token.totalSupply());
            vm.prank(from);
            token.approve(spender, allowed);
            ghostAllowance[from][spender] = allowed;
            approvals++;
        }
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;

        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            assertTrue(false, "transferFrom over allowance did not revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(QuorumToken.InsufficientAllowance.selector, spender, allowed, amount));
        }
        expectedReverts++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            assertTrue(false, "approve of the zero spender did not revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(QuorumToken.InvalidSpender.selector, address(0)));
        }
        expectedReverts++;
    }

    /// @dev A stranger with no balance and no allowance can never move anything.
    function strangerCannotMove(uint256 victimSeed, uint256 amount) external {
        address victim = _actor(victimSeed);
        address stranger = address(uint160(uint256(keccak256(abi.encode("stranger", amount)))));
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(stranger);
        try token.transferFrom(victim, stranger, amount) {
            assertTrue(false, "a stranger moved a holder's balance");
        } catch {}
        vm.prank(stranger);
        try token.transfer(victim, amount) {
            assertTrue(false, "a stranger with no balance transferred");
        } catch {}
        expectedReverts += 2;
    }

    // ---------------------------------------------------------------- internals

    function _recordMove(address from, address to, uint256 amount) private {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        totalMoved += amount;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }
}

/// @notice Invariants over random call sequences driven by `QuorumHandler`.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract QuorumTokenInvariantTest is StdInvariant, Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    QuorumToken token;
    QuorumHandler handler;
    address deployer = address(0xD0);

    function setUp() public {
        vm.prank(deployer);
        token = new QuorumToken();

        address[] memory others = new address[](5);
        others[0] = address(0xA1);
        others[1] = address(0xB0);
        others[2] = address(0xC0);
        others[3] = address(0xDA);
        others[4] = address(0xE0);
        handler = new QuorumHandler(token, deployer, others);

        targetContract(address(handler));
    }

    /// @dev The supply is fixed at deployment and nothing can change it.
    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// @dev What the actors hold together is exactly the supply: nothing is created or lost.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "balances do not sum to the supply");
    }

    /// @dev Every balance matches the ghost ledger built from the successful moves.
    function invariant_balancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance drifted from the ledger");
            assertLe(token.balanceOf(a), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev Each actor holds what it started with plus what it received minus what it sent.
    function invariant_flowsReconcile() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            uint256 initial = a == deployer ? SUPPLY : 0;
            assertEq(initial + handler.ghostReceived(a) - handler.ghostSent(a), token.balanceOf(a));
            assertLe(handler.ghostSent(a), initial + handler.ghostReceived(a), "an actor sent more than it had");
        }
    }

    /// @dev Every allowance matches the ghost ledger: approvals overwrite, finite spends decrement,
    /// the infinite allowance never moves, and reverted calls leave allowances untouched.
    function invariant_allowancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender));
            }
        }
    }

    /// @dev Nothing is ever sent to the zero address, nor is anything held by the token itself.
    function invariant_zeroAddressAndTokenHoldNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// @dev Metadata is constant across every sequence.
    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "Quorum");
        assertEq(token.symbol(), "QRM");
        assertEq(uint256(token.decimals()), 18);
    }
}

/// @notice Open-world invariants: the fuzzer calls the token directly with arbitrary senders and
/// arguments, reverts allowed. Whatever anyone does, the supply does not move and the zero address
/// holds nothing.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
contract QuorumTokenOpenInvariantTest is StdInvariant, Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    QuorumToken token;
    address deployer = address(0xD0);

    function setUp() public {
        vm.prank(deployer);
        token = new QuorumToken();
        targetContract(address(token));
    }

    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_zeroAddressNeverHoldsTokens() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev Only the deployer was minted to, so nobody can hold more than the supply.
    function invariant_deployerNeverExceedsSupply() public view {
        assertLe(token.balanceOf(deployer), SUPPLY);
    }
}
