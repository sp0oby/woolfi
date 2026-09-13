// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Probe whether Robinhood Chain tokens can be moved on a fork after Foundry's `deal`.
/// @dev deal() writes the balance slot but does NOT bypass transfer-side gates in the token
///      contract (allowlists, geo/sanction hooks, issuer pauses). If deal-then-transfer works,
///      the full-protocol fork test can use it. If it reverts, we need whale-prank or must
///      document the swap gap for real. Skips cleanly without ROBINHOOD_RPC_URL.
contract TokenTransferProbeForkTest is Test {
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;

    // Canonical Robinhood Chain assets (see script/robinhood_catalog.py).
    address private constant TOK_MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address private constant TOK_COIN = 0x6330D8C3178a418788dF01a47479c0ce7CCF450b;
    address private constant TOK_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address private constant TOK_SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address private constant TOK_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address private constant TOK_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    modifier onlyOnFork() {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "wrong chain forked");
        _;
    }

    function _probeToken(address token, string memory label) private {
        address alice = makeAddr(string.concat("alice_", label));
        address bob = makeAddr(string.concat("bob_", label));
        uint8 dec = IERC20Metadata(token).decimals();
        uint256 amount = 100 * (10 ** dec);

        // 1. deal writes storage: does the reported balance actually change?
        deal(token, alice, amount);
        uint256 aliceBalance = IERC20(token).balanceOf(alice);
        emit log_named_uint(string.concat(label, " balance after deal"), aliceBalance);
        if (aliceBalance != amount) {
            emit log_named_string(label, "deal did not set balance (proxy/rebalancing token?) - cannot probe");
            return;
        }

        // 2. Can Alice transfer to Bob?
        vm.prank(alice);
        (bool ok, bytes memory reason) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, bob, amount / 2));
        if (ok) {
            emit log_named_string(label, "transfer(alice->bob) OK");
            uint256 bobBalance = IERC20(token).balanceOf(bob);
            emit log_named_uint(string.concat(label, " bob balance"), bobBalance);
        } else {
            emit log_named_string(label, "transfer(alice->bob) REVERTED");
            emit log_named_bytes(string.concat(label, " revert reason"), reason);
        }

        // 3. Can Alice approve + can a third party transferFrom?
        address router = makeAddr(string.concat("router_", label));
        vm.prank(alice);
        (bool approveOk,) = token.call(abi.encodeWithSelector(IERC20.approve.selector, router, amount));
        emit log_named_string(string.concat(label, " approve"), approveOk ? "OK" : "REVERTED");
        if (!approveOk) return;

        vm.prank(router);
        (bool tfOk, bytes memory tfReason) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, alice, bob, amount / 4));
        if (tfOk) {
            emit log_named_string(label, "transferFrom(router, alice->bob) OK");
        } else {
            emit log_named_string(label, "transferFrom(router, alice->bob) REVERTED");
            emit log_named_bytes(string.concat(label, " transferFrom reason"), tfReason);
        }
    }

    function test_fork_probeMstr() public onlyOnFork {
        _probeToken(TOK_MSTR, "MSTR");
    }

    function test_fork_probeCoin() public onlyOnFork {
        _probeToken(TOK_COIN, "COIN");
    }

    function test_fork_probeNvda() public onlyOnFork {
        _probeToken(TOK_NVDA, "NVDA");
    }

    function test_fork_probeSpy() public onlyOnFork {
        _probeToken(TOK_SPY, "SPY");
    }

    function test_fork_probeWeth() public onlyOnFork {
        _probeToken(TOK_WETH, "WETH");
    }

    function test_fork_probeUsdg() public onlyOnFork {
        _probeToken(TOK_USDG, "USDG");
    }
}
