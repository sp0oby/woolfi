// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RobinhoodStockOracleAdapter} from "../../src/oracle/RobinhoodStockOracleAdapter.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";

contract MockRobinhoodStockToken {
    bool public oraclePaused;

    function setOraclePaused(bool paused) external {
        oraclePaused = paused;
    }
}

contract RobinhoodStockOracleAdapterTest is Test {
    uint256 constant START = 1_700_000_000;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant GRACE_PERIOD = 1 hours;

    MockRobinhoodStockToken stock;
    MockChainlinkFeed priceFeed;
    MockChainlinkFeed sequencerFeed;
    RobinhoodStockOracleAdapter adapter;

    function setUp() public {
        vm.warp(START);
        stock = new MockRobinhoodStockToken();
        priceFeed = new MockChainlinkFeed(8, 250e8, block.timestamp);
        sequencerFeed = new MockChainlinkFeed(0, 0, block.timestamp - GRACE_PERIOD - 1);
        adapter = _deploy(stock, priceFeed, sequencerFeed, HEARTBEAT, GRACE_PERIOD);
    }

    function test_getPrice_normalizesPrice() public view {
        assertEq(adapter.getPrice(), 250e18);
    }

    function test_getPriceData_returnsValidatedTimestamp() public view {
        (uint256 price, uint256 updatedAt) = adapter.getPriceData();
        assertEq(price, 250e18);
        assertEq(updatedAt, START);
    }

    function testFuzz_getPrice_normalizesSupportedDecimals(uint8 decimals_, uint96 answer) public {
        decimals_ = uint8(bound(decimals_, 0, 18));
        answer = uint96(bound(answer, 1, type(uint96).max));
        MockChainlinkFeed feed = new MockChainlinkFeed(decimals_, int256(uint256(answer)), block.timestamp);
        RobinhoodStockOracleAdapter candidate = _deploy(stock, feed, sequencerFeed, HEARTBEAT, GRACE_PERIOD);
        assertEq(candidate.getPrice(), uint256(answer) * (10 ** (18 - decimals_)));
    }

    function test_getPrice_acceptsStalenessBoundary() public {
        priceFeed.setAnswer(250e8, block.timestamp - (2 * HEARTBEAT));
        assertEq(adapter.getPrice(), 250e18);
    }

    function testRevert_getPrice_rejectsStalePrice() public {
        uint256 updatedAt = block.timestamp - (2 * HEARTBEAT) - 1;
        priceFeed.setAnswer(250e8, updatedAt);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodStockOracleAdapter.StalePrice.selector, updatedAt, 2 * HEARTBEAT)
        );
        adapter.getPrice();
    }

    function testRevert_getPrice_rejectsZeroAndNegativePrice() public {
        priceFeed.setAnswer(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleAdapter.InvalidPrice.selector, int256(0)));
        adapter.getPrice();

        priceFeed.setAnswer(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleAdapter.InvalidPrice.selector, int256(-1)));
        adapter.getPrice();
    }

    function testRevert_getPrice_rejectsIncompleteRound() public {
        priceFeed.setRoundIds(2, 1);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodStockOracleAdapter.IncompleteRound.selector, uint80(2), uint80(1))
        );
        adapter.getPrice();
    }

    function testRevert_getPrice_rejectsInvalidPriceTimestamps() public {
        priceFeed.setAnswer(250e8, 0);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodStockOracleAdapter.InvalidTimestamp.selector, address(priceFeed), 0)
        );
        adapter.getPrice();

        priceFeed.setAnswer(250e8, block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RobinhoodStockOracleAdapter.InvalidTimestamp.selector, address(priceFeed), block.timestamp + 1
            )
        );
        adapter.getPrice();
    }

    function testRevert_getPrice_rejectsCorporateActionPause() public {
        stock.setOraclePaused(true);
        vm.expectRevert(RobinhoodStockOracleAdapter.OraclePaused.selector);
        adapter.getPrice();
    }

    function test_requireRuntimeGuards_allowsStalePrice() public {
        uint256 updatedAt = block.timestamp - (2 * HEARTBEAT) - 1;
        priceFeed.setAnswer(250e8, updatedAt);
        adapter.requireRuntimeGuards();
    }

    function testRevert_requireRuntimeGuards_rejectsSequencerDown() public {
        sequencerFeed.setRoundData(1, block.timestamp - GRACE_PERIOD - 1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleAdapter.SequencerDown.selector, int256(1)));
        adapter.requireRuntimeGuards();
    }

    function testRevert_requireRuntimeGuards_rejectsOraclePaused() public {
        stock.setOraclePaused(true);
        vm.expectRevert(RobinhoodStockOracleAdapter.OraclePaused.selector);
        adapter.requireRuntimeGuards();
    }

    function testRevert_getPrice_rejectsAnySequencerNonzeroAnswer() public {
        sequencerFeed.setRoundData(1, block.timestamp - GRACE_PERIOD - 1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleAdapter.SequencerDown.selector, int256(1)));
        adapter.getPrice();

        sequencerFeed.setRoundData(-1, block.timestamp - GRACE_PERIOD - 1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleAdapter.SequencerDown.selector, int256(-1)));
        adapter.getPrice();
    }

    function testRevert_getPrice_rejectsInvalidSequencerUpdatedAt() public {
        sequencerFeed.setRoundData(0, block.timestamp - GRACE_PERIOD - 1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodStockOracleAdapter.InvalidTimestamp.selector, address(sequencerFeed), 0)
        );
        adapter.getPrice();
    }

    function testRevert_getPrice_rejectsInvalidSequencerStartedAt() public {
        sequencerFeed.setRoundData(0, 0, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodStockOracleAdapter.InvalidTimestamp.selector, address(sequencerFeed), 0)
        );
        adapter.getPrice();
    }

    function testRevert_getPrice_enforcesGracePeriodBoundary() public {
        uint256 startedAt = block.timestamp - GRACE_PERIOD;
        sequencerFeed.setRoundData(0, startedAt, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(RobinhoodStockOracleAdapter.GracePeriodActive.selector, startedAt, GRACE_PERIOD)
        );
        adapter.getPrice();
    }

    function test_getPrice_acceptsOneSecondAfterGracePeriod() public {
        sequencerFeed.setRoundData(0, block.timestamp - GRACE_PERIOD - 1, block.timestamp);
        assertEq(adapter.getPrice(), 250e18);
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(adapter.stockToken()), address(stock));
        assertEq(address(adapter.feed()), address(priceFeed));
        assertEq(address(adapter.sequencerUptimeFeed()), address(sequencerFeed));
        assertEq(adapter.heartbeat(), HEARTBEAT);
        assertEq(adapter.gracePeriod(), GRACE_PERIOD);
        assertEq(adapter.feedDecimals(), 8);
    }

    function testRevert_constructor_rejectsZeroAddress() public {
        vm.expectRevert(RobinhoodStockOracleAdapter.ZeroAddress.selector);
        new RobinhoodStockOracleAdapter(address(0), address(priceFeed), address(sequencerFeed), HEARTBEAT, GRACE_PERIOD);
    }

    function testRevert_constructor_rejectsAddressWithoutCode() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleAdapter.NotContract.selector, eoa));
        new RobinhoodStockOracleAdapter(eoa, address(priceFeed), address(sequencerFeed), HEARTBEAT, GRACE_PERIOD);
    }

    function testRevert_constructor_rejectsInvalidConfiguration() public {
        vm.expectRevert(RobinhoodStockOracleAdapter.InvalidHeartbeat.selector);
        _deploy(stock, priceFeed, sequencerFeed, 0, GRACE_PERIOD);

        vm.expectRevert(RobinhoodStockOracleAdapter.ZeroGracePeriod.selector);
        _deploy(stock, priceFeed, sequencerFeed, HEARTBEAT, 0);

        MockChainlinkFeed unsupported = new MockChainlinkFeed(19, 1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodStockOracleAdapter.UnsupportedDecimals.selector, uint8(19)));
        _deploy(stock, unsupported, sequencerFeed, HEARTBEAT, GRACE_PERIOD);
    }

    function _deploy(
        MockRobinhoodStockToken stock_,
        MockChainlinkFeed priceFeed_,
        MockChainlinkFeed sequencerFeed_,
        uint256 heartbeat_,
        uint256 gracePeriod_
    ) private returns (RobinhoodStockOracleAdapter) {
        return new RobinhoodStockOracleAdapter(
            address(stock_), address(priceFeed_), address(sequencerFeed_), heartbeat_, gracePeriod_
        );
    }
}
