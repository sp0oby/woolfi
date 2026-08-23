// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {NyseHoursOracle} from "../../src/oracle/NyseHoursOracle.sol";

/// @notice Calendar correctness for the on-chain NYSE-hours oracle. Every assertion is a real
///         date/time the user could check on a calendar; if a test fails, the calendar is the
///         source of truth.
contract NyseHoursOracleTest is Test {
    NyseHoursOracle oracle;
    address constant OWNER = address(0xABCD);

    function setUp() public {
        oracle = new NyseHoursOracle(OWNER);
    }

    // ====================================================================== //
    //                              Trading window                            //
    // ====================================================================== //

    function test_open_tueMidMorningEDT() public {
        // Tuesday 2026-04-14, 10:00 EDT = 14:00 UTC.
        vm.warp(_ts(2026, 4, 14, 14, 0));
        assertTrue(oracle.isMarketOpen(), "Tue 10am EDT should be open");
    }

    function test_open_wedAfternoonEST() public {
        // Wednesday 2026-01-14, 3:30 PM EST = 20:30 UTC.
        vm.warp(_ts(2026, 1, 14, 20, 30));
        assertTrue(oracle.isMarketOpen(), "Wed 3:30pm EST should be open");
    }

    function test_open_exactly_atOpen() public {
        // 9:30:00 ET on a regular Wednesday in March 2026 (after DST start).
        // 2026-03-11 (Wed) 9:30 EDT = 13:30 UTC.
        vm.warp(_ts(2026, 3, 11, 13, 30));
        assertTrue(oracle.isMarketOpen(), "open at exactly 9:30 ET");
        assertEq(oracle.currentSessionStart(), block.timestamp);
    }

    function test_currentSessionStart_isStableThroughoutSession() public {
        uint256 openTs = _ts(2026, 4, 14, 13, 30);
        vm.warp(openTs + 2 hours);
        assertEq(oracle.currentSessionStart(), openTs);
        vm.warp(_ts(2026, 4, 14, 20, 0));
        assertEq(oracle.currentSessionStart(), 0);
    }

    function test_closed_oneSecondBeforeOpen() public {
        // 9:29:59 ET → closed.
        vm.warp(_ts(2026, 3, 11, 13, 30) - 1);
        assertFalse(oracle.isMarketOpen(), "closed at 9:29:59 ET");
    }

    function test_closed_atExactlyClose() public {
        // 16:00:00 ET → closed (half-open right boundary).
        vm.warp(_ts(2026, 3, 11, 20, 0));
        assertFalse(oracle.isMarketOpen(), "closed at 4:00 PM ET (boundary)");
    }

    function test_closed_oneSecondBeforeClose() public {
        // 15:59:59 ET → still open.
        vm.warp(_ts(2026, 3, 11, 20, 0) - 1);
        assertTrue(oracle.isMarketOpen(), "open at 3:59:59 PM ET");
    }

    // ====================================================================== //
    //                                Weekends                                //
    // ====================================================================== //

    function test_closed_saturday() public {
        // Sat 2026-01-17, 11 AM EST = 16:00 UTC. Saturday.
        vm.warp(_ts(2026, 1, 17, 16, 0));
        assertFalse(oracle.isMarketOpen(), "Saturday should be closed");
    }

    function test_closed_sunday() public {
        // Sun 2026-01-18, 11 AM EST = 16:00 UTC. Sunday.
        vm.warp(_ts(2026, 1, 18, 16, 0));
        assertFalse(oracle.isMarketOpen(), "Sunday should be closed");
    }

    // ====================================================================== //
    //                                Holidays                                //
    // ====================================================================== //

    function test_closed_mlkDay2026() public {
        // Mon 2026-01-19, 11 AM EST = 16:00 UTC. MLK Day.
        vm.warp(_ts(2026, 1, 19, 16, 0));
        assertFalse(oracle.isMarketOpen(), "MLK Day 2026 should be closed");
    }

    function test_closed_thanksgiving2026() public {
        // Thu 2026-11-26, 11 AM EST = 16:00 UTC. Thanksgiving (post-DST).
        vm.warp(_ts(2026, 11, 26, 16, 0));
        assertFalse(oracle.isMarketOpen(), "Thanksgiving 2026 should be closed");
    }

    function test_closed_christmas2027() public {
        // Fri 2027-12-24, 11 AM EST = 16:00 UTC. Christmas observed (Dec 25 = Sat).
        vm.warp(_ts(2027, 12, 24, 16, 0));
        assertFalse(oracle.isMarketOpen(), "Christmas observed 2027 should be closed");
    }

    function test_open_dayAfterHoliday() public {
        // Tue 2026-01-20, 11 AM EST = 16:00 UTC. Day after MLK Day, normal session.
        vm.warp(_ts(2026, 1, 20, 16, 0));
        assertTrue(oracle.isMarketOpen(), "Day after MLK should be open");
    }

    // ====================================================================== //
    //                                   DST                                  //
    // ====================================================================== //

    function test_dst_estJustBeforeSpringForward() public {
        // Sun 2026-03-08 06:59 UTC = Sat 2026-03-08 01:59 EST. Sunday, closed by weekend anyway.
        // Use a weekday-adjacent timestamp where the offset matters: 11am ET on Fri 2026-03-06.
        // In EST that's 16:00 UTC.
        vm.warp(_ts(2026, 3, 6, 16, 0));
        assertTrue(oracle.isMarketOpen(), "Fri before DST: 11am EST should be open");
    }

    function test_dst_edtAfterSpringForward() public {
        // Mon 2026-03-09 (first weekday after DST start) 11 AM EDT = 15:00 UTC.
        // If we wrongly used EST offset, 15:00 UTC - 5h = 10:00 ET, still open by accident.
        // Test the *boundary*: at 14:00 UTC = 10am EDT vs 9am EST.
        // 10am EDT → open. 9am EST → closed (before 9:30).
        vm.warp(_ts(2026, 3, 9, 14, 0));
        assertTrue(oracle.isMarketOpen(), "Mon after DST: 10am EDT (14:00 UTC) should be open");
    }

    function test_dst_estAfterFallBack() public {
        // Mon 2026-11-02 (first weekday after DST ends) 10 AM EST = 15:00 UTC.
        // If we wrongly used EDT offset, 15:00 UTC - 4h = 11am ET, also open. So pick boundary:
        // 13:30 UTC = 8:30 EST (closed) vs 9:30 EDT (open). After Nov 1 we're back on EST.
        vm.warp(_ts(2026, 11, 2, 13, 30));
        assertFalse(oracle.isMarketOpen(), "Mon after fall-back: 8:30am EST should be closed");
        // And 14:30 UTC = 9:30 EST → open.
        vm.warp(_ts(2026, 11, 2, 14, 30));
        assertTrue(oracle.isMarketOpen(), "Mon after fall-back: 9:30am EST should be open");
    }

    // ====================================================================== //
    //                               Governance                               //
    // ====================================================================== //

    function test_governance_addHoliday() public {
        // Pick a normal trading day in 2028 that's not pre-populated as a holiday.
        // Tue 2028-04-04, 11 AM EDT = 15:00 UTC.
        vm.warp(_ts(2028, 4, 4, 15, 0));
        assertTrue(oracle.isMarketOpen(), "Tue 2028-04-04 should be open by default");

        // Precompute the day index BEFORE the prank — otherwise the external `utcDay` call
        // consumes the prank and `setHoliday` runs without it.
        uint256 dayIndex = oracle.utcDay(2028, 4, 4);
        vm.prank(OWNER);
        oracle.setHoliday(dayIndex, true);
        assertFalse(oracle.isMarketOpen(), "after setHoliday, closed");
    }

    function testRevert_setHoliday_notOwner() public {
        uint256 dayIndex = oracle.utcDay(2028, 4, 4);
        vm.expectRevert();
        oracle.setHoliday(dayIndex, true);
    }

    function test_governance_bulkAddHolidays() public {
        uint256[] memory daysUtc = new uint256[](2);
        daysUtc[0] = oracle.utcDay(2028, 1, 17); // MLK Day 2028
        daysUtc[1] = oracle.utcDay(2028, 7, 4); // July 4 2028 (Tue)

        vm.prank(OWNER);
        oracle.setHolidays(daysUtc, true);

        vm.warp(_ts(2028, 1, 17, 16, 0));
        assertFalse(oracle.isMarketOpen(), "bulk MLK 2028 closed");
        vm.warp(_ts(2028, 7, 4, 16, 0));
        assertFalse(oracle.isMarketOpen(), "bulk July 4 2028 closed");
    }

    function test_governance_extendDstTable() public {
        // Initial table covers through 2030. Append 2031.
        // 2031 DST: starts Sun Mar 9, ends Sun Nov 2.
        uint64 startTs = uint64(_ts(2031, 3, 9, 7, 0));
        uint64 endTs = uint64(_ts(2031, 11, 2, 6, 0));

        uint256 countBefore = oracle.dstWindowCount();
        vm.prank(OWNER);
        oracle.appendDstWindow(startTs, endTs);
        assertEq(oracle.dstWindowCount(), countBefore + 1, "DST count incremented");

        // 2031-03-10 (Mon) 10am EDT = 14:00 UTC → should be open after DST kicks in.
        vm.warp(_ts(2031, 3, 10, 14, 0));
        assertTrue(oracle.isMarketOpen(), "2031 DST-period weekday open");
    }

    // ====================================================================== //
    //                                   Util                                 //
    // ====================================================================== //

    /// @dev Pure UTC timestamp from a calendar date+hh:mm. Mirrors the Solidity helper so
    ///      tests don't drift from the contract's date math.
    function _ts(uint256 year, uint256 month, uint256 day, uint256 hour, uint256 minute)
        internal
        pure
        returns (uint256)
    {
        // Replicate the Hinnant days-from-civil algorithm.
        if (month <= 2) year -= 1;
        uint256 era = year / 400;
        uint256 yoe = year - era * 400;
        uint256 doy = month > 2 ? (153 * (month - 3) + 2) / 5 + day - 1 : (153 * (month + 9) + 2) / 5 + day - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        uint256 daysSinceEpoch = era * 146097 + doe - 719468;
        return daysSinceEpoch * 86400 + hour * 3600 + minute * 60;
    }
}
