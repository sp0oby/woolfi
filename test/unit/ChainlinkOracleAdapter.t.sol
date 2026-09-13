// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";

contract ChainlinkOracleAdapterTest is Test {
    uint256 constant START = 1_700_000_000;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant MAX_STALENESS = HEARTBEAT * 2; // 7200

    MockChainlinkFeed feed;
    ChainlinkOracleAdapter adapter;

    function setUp() public {
        vm.warp(START);
        // cbBTC-style feed: 8 decimals, $100,000
        feed = new MockChainlinkFeed(8, 100_000e8, block.timestamp);
        adapter = new ChainlinkOracleAdapter(address(feed), HEARTBEAT);
    }

    // -----------------------------------------------------------------
    // normalization
    // -----------------------------------------------------------------

    function test_getPrice_normalizes8Decimals() public view {
        assertEq(adapter.getPrice(), 100_000e18);
    }

    function test_getPriceData_returnsValidatedTimestamp() public view {
        (uint256 price, uint256 updatedAt) = adapter.getPriceData();
        assertEq(price, 100_000e18);
        assertEq(updatedAt, START);
    }

    function test_getPrice_normalizes18Decimals() public {
        MockChainlinkFeed f = new MockChainlinkFeed(18, 400e18, block.timestamp);
        ChainlinkOracleAdapter a = new ChainlinkOracleAdapter(address(f), HEARTBEAT);
        assertEq(a.getPrice(), 400e18);
    }

    function test_getPrice_normalizes0Decimals() public {
        MockChainlinkFeed f = new MockChainlinkFeed(0, 7, block.timestamp);
        ChainlinkOracleAdapter a = new ChainlinkOracleAdapter(address(f), HEARTBEAT);
        assertEq(a.getPrice(), 7e18);
    }

    function testFuzz_getPrice_normalizes(uint8 dec, uint256 answer) public {
        dec = uint8(bound(dec, 0, 18));
        answer = bound(answer, 1, 1e12);
        MockChainlinkFeed f = new MockChainlinkFeed(dec, int256(answer), block.timestamp);
        ChainlinkOracleAdapter a = new ChainlinkOracleAdapter(address(f), HEARTBEAT);
        assertEq(a.getPrice(), answer * (10 ** (18 - uint256(dec))));
    }

    // -----------------------------------------------------------------
    // staleness
    // -----------------------------------------------------------------

    function test_getPrice_freshAtBoundary() public {
        // age exactly == 2x heartbeat is still acceptable (boundary is inclusive)
        feed.setAnswer(100_000e8, block.timestamp - MAX_STALENESS);
        assertEq(adapter.getPrice(), 100_000e18);
    }

    function testRevert_getPrice_staleOneSecondPastBoundary() public {
        feed.setAnswer(100_000e8, block.timestamp - MAX_STALENESS - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracleAdapter.StalePrice.selector, block.timestamp - MAX_STALENESS - 1, MAX_STALENESS
            )
        );
        adapter.getPrice();
    }

    function testRevert_getPrice_incompleteRound() public {
        feed.setAnswer(100_000e8, 0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.StalePrice.selector, 0, MAX_STALENESS));
        adapter.getPrice();
    }

    function testRevert_getPrice_rejectsUnansweredRound() public {
        feed.setRoundIds(4, 3);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.IncompleteRound.selector, uint80(4), uint80(3)));
        adapter.getPrice();
    }

    function test_requireRuntimeGuards_allowsStaleButValidPrint() public {
        feed.setAnswer(100_000e8, block.timestamp - MAX_STALENESS - 1);
        adapter.requireRuntimeGuards();
    }

    function testRevert_requireRuntimeGuards_invalidAnswer() public {
        feed.setAnswer(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.InvalidPrice.selector, int256(0)));
        adapter.requireRuntimeGuards();
    }

    // -----------------------------------------------------------------
    // invalid price
    // -----------------------------------------------------------------

    function testRevert_getPrice_zeroAnswer() public {
        feed.setAnswer(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.InvalidPrice.selector, int256(0)));
        adapter.getPrice();
    }

    function testRevert_getPrice_negativeAnswer() public {
        feed.setAnswer(-5, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.InvalidPrice.selector, int256(-5)));
        adapter.getPrice();
    }

    // -----------------------------------------------------------------
    // constructor guards
    // -----------------------------------------------------------------

    function testRevert_constructor_zeroFeed() public {
        vm.expectRevert(ChainlinkOracleAdapter.ZeroAddress.selector);
        new ChainlinkOracleAdapter(address(0), HEARTBEAT);
    }

    function testRevert_constructor_zeroHeartbeat() public {
        vm.expectRevert(ChainlinkOracleAdapter.ZeroHeartbeat.selector);
        new ChainlinkOracleAdapter(address(feed), 0);
    }

    function testRevert_constructor_unsupportedDecimals() public {
        MockChainlinkFeed f = new MockChainlinkFeed(19, 1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracleAdapter.UnsupportedDecimals.selector, uint8(19)));
        new ChainlinkOracleAdapter(address(f), HEARTBEAT);
    }

    // -----------------------------------------------------------------
    // immutables
    // -----------------------------------------------------------------

    function test_constructor_setsImmutables() public view {
        assertEq(address(adapter.feed()), address(feed));
        assertEq(adapter.heartbeat(), HEARTBEAT);
        assertEq(adapter.feedDecimals(), 8);
    }
}
