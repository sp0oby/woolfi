// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMarketHoursOracle} from "../interfaces/IMarketHoursOracle.sol";

/// @title NyseHoursOracle
/// @notice A pure on-chain {IMarketHoursOracle} for NYSE regular hours: 9:30 AM – 4:00 PM ET,
///         Mon–Fri, excluding hardcoded holidays. No off-chain feed, no keeper, no LINK.
/// @dev Why this exists: NYSE regular hours are deterministic and publicly known. A real-time
///      oracle (Chainlink Data Streams / Automation / a multisig flag) adds operational surface
///      for zero accuracy gain over a correctly-implemented calendar.
///
///      What this DOESN'T cover:
///        - Early-close days (day after Thanksgiving, Christmas Eve etc, which close at 1 PM ET).
///          The mechanic stays "on" until 4 PM ET on those days, which is a benign
///          ~3-hour overshoot — risk of the asymmetric fee acting on a thin-volume tape, accepted.
///        - Unscheduled closures (Sandy 2012, 9/11 etc). Governance can add a one-off holiday via
///          `setHoliday`.
///        - Changes to DST rules. The Sunshine Protection Act has been floated; if Congress
///          eliminates DST, the multisig calls `setDstWindow` to clear or shift transitions.
///
///      Anyone can `addHolidaysBulk` / `setHoliday` if owner — the owner is the WoolFi multisig
///      so calendar maintenance is a normal governance op, not a sysadmin task.
contract NyseHoursOracle is IMarketHoursOracle, Ownable {
    // ---------------------------------------------------------------------- //
    //                            STORAGE / EVENTS                            //
    // ---------------------------------------------------------------------- //

    /// @notice Days (as days-since-Unix-epoch UTC) on which NYSE is closed despite being a weekday.
    mapping(uint256 dayIndexUtc => bool isHoliday) public holiday;

    /// @notice DST transition windows, sorted ascending. Each entry: `[startTs, endTs)` of EDT
    ///         (UTC-4). Outside any window the contract assumes EST (UTC-5).
    DstWindow[] public dstWindows;

    struct DstWindow {
        uint64 startTs; // start of EDT (DST begins, 2 AM local "spring forward")
        uint64 endTs; //   start of EST (DST ends,   2 AM local "fall back")
    }

    event HolidaySet(uint256 indexed dayIndexUtc, bool isHoliday);
    event DstWindowSet(uint256 indexed index, uint64 startTs, uint64 endTs);
    event DstWindowsCleared();

    // ---------------------------------------------------------------------- //
    //                                CONSTANTS                               //
    // ---------------------------------------------------------------------- //

    uint256 private constant SECONDS_PER_DAY = 86400;
    // 9:30 AM ET → 34_200 seconds past midnight ET. 4:00 PM ET → 57_600.
    uint256 private constant OPEN_SECONDS_ET = 9 * 3600 + 30 * 60;
    uint256 private constant CLOSE_SECONDS_ET = 16 * 3600;

    // ---------------------------------------------------------------------- //
    //                              CONSTRUCTOR                               //
    // ---------------------------------------------------------------------- //

    /// @param initialOwner Multisig that maintains the holiday list and DST table going forward.
    constructor(address initialOwner) Ownable(initialOwner) {
        // --- NYSE 2026 holidays (10 dates) -------------------------------- //
        _setHoliday(_utcDay(2026, 1, 1), true); // New Year's Day (Thu)
        _setHoliday(_utcDay(2026, 1, 19), true); // MLK Jr Day (3rd Mon)
        _setHoliday(_utcDay(2026, 2, 16), true); // Presidents' Day (3rd Mon)
        _setHoliday(_utcDay(2026, 4, 3), true); // Good Friday
        _setHoliday(_utcDay(2026, 5, 25), true); // Memorial Day (last Mon)
        _setHoliday(_utcDay(2026, 6, 19), true); // Juneteenth (Fri)
        _setHoliday(_utcDay(2026, 7, 3), true); // July 4 falls Sat → observed Fri Jul 3
        _setHoliday(_utcDay(2026, 9, 7), true); // Labor Day (1st Mon)
        _setHoliday(_utcDay(2026, 11, 26), true); // Thanksgiving (4th Thu)
        _setHoliday(_utcDay(2026, 12, 25), true); // Christmas (Fri)

        // --- NYSE 2027 holidays (10 dates) -------------------------------- //
        _setHoliday(_utcDay(2027, 1, 1), true); // New Year's Day (Fri)
        _setHoliday(_utcDay(2027, 1, 18), true); // MLK Jr Day
        _setHoliday(_utcDay(2027, 2, 15), true); // Presidents' Day
        _setHoliday(_utcDay(2027, 3, 26), true); // Good Friday
        _setHoliday(_utcDay(2027, 5, 31), true); // Memorial Day
        _setHoliday(_utcDay(2027, 6, 18), true); // Juneteenth (Sat → observed Fri Jun 18)
        _setHoliday(_utcDay(2027, 7, 5), true); // July 4 falls Sun → observed Mon Jul 5
        _setHoliday(_utcDay(2027, 9, 6), true); // Labor Day
        _setHoliday(_utcDay(2027, 11, 25), true); // Thanksgiving
        _setHoliday(_utcDay(2027, 12, 24), true); // Christmas falls Sat → observed Fri Dec 24

        // --- DST transitions 2026–2030 (US: 2nd Sun Mar → 1st Sun Nov) ---- //
        // Each window: [DST-start UTC ts, DST-end UTC ts). DST starts 2 AM EST = 07:00 UTC.
        // DST ends 2 AM EDT = 06:00 UTC.
        dstWindows.push(DstWindow(_utcTs(2026, 3, 8, 7, 0), _utcTs(2026, 11, 1, 6, 0)));
        dstWindows.push(DstWindow(_utcTs(2027, 3, 14, 7, 0), _utcTs(2027, 11, 7, 6, 0)));
        dstWindows.push(DstWindow(_utcTs(2028, 3, 12, 7, 0), _utcTs(2028, 11, 5, 6, 0)));
        dstWindows.push(DstWindow(_utcTs(2029, 3, 11, 7, 0), _utcTs(2029, 11, 4, 6, 0)));
        dstWindows.push(DstWindow(_utcTs(2030, 3, 10, 7, 0), _utcTs(2030, 11, 3, 6, 0)));
    }

    // ---------------------------------------------------------------------- //
    //                          IMarketHoursOracle                            //
    // ---------------------------------------------------------------------- //

    /// @inheritdoc IMarketHoursOracle
    function isMarketOpen() external view returns (bool) {
        return _currentSessionStart(block.timestamp) != 0;
    }

    /// @inheritdoc IMarketHoursOracle
    function currentSessionStart() external view returns (uint256) {
        return _currentSessionStart(block.timestamp);
    }

    function _currentSessionStart(uint256 nowTs) internal view returns (uint256) {
        // Convert UTC → ET. Subtract 4h during DST, 5h otherwise.
        uint256 etOffset = _isDst(nowTs) ? 4 hours : 5 hours;
        if (nowTs <= etOffset) return 0; // before unix epoch in ET, sanity guard
        uint256 etTs = nowTs - etOffset;

        // Weekend check: Unix epoch 1970-01-01 was a Thursday (dow=4). Mon=1, Sat=6, Sun=0.
        uint256 dayIndexEt = etTs / SECONDS_PER_DAY;
        uint256 dow = (dayIndexEt + 4) % 7;
        if (dow == 0 || dow == 6) return 0;

        // Time-of-day check: 9:30 AM ≤ ET < 4:00 PM.
        // (Doing this BEFORE the holiday check means the holiday lookup only matters during
        // actual trading hours — when UTC date == ET date and we don't need to worry about
        // day-boundary aliasing across the 5h offset.)
        uint256 secondsOfDay = etTs % SECONDS_PER_DAY;
        if (secondsOfDay < OPEN_SECONDS_ET) return 0;
        if (secondsOfDay >= CLOSE_SECONDS_ET) return 0;

        // Holiday check. During trading hours (9:30 ET – 16:00 ET = 13:30–21:00 UTC in EST,
        // 14:30–20:00 UTC in EDT) the UTC calendar date equals the ET calendar date, so the
        // UTC day index is the same key off-chain callers use when populating the holiday list.
        uint256 dayIndexUtc = nowTs / SECONDS_PER_DAY;
        if (holiday[dayIndexUtc]) return 0;

        return dayIndexEt * SECONDS_PER_DAY + OPEN_SECONDS_ET + etOffset;
    }

    /// @notice Off-chain monitoring hook: timestamp of the most recent change to the calendar.
    /// @dev Mirrors the `lastUpdate` field on `MultisigMarketHours` so the frontend banner code
    ///      that surfaces "updated Xh ago" works against either oracle.
    uint64 public lastUpdate;

    // ---------------------------------------------------------------------- //
    //                              GOVERNANCE                                //
    // ---------------------------------------------------------------------- //

    /// @notice Add or remove a holiday by its UTC day index (days since Unix epoch).
    function setHoliday(uint256 dayIndexUtc, bool isHoliday) external onlyOwner {
        _setHoliday(dayIndexUtc, isHoliday);
    }

    /// @notice Bulk-set holidays (e.g. extending the calendar into 2028+).
    function setHolidays(uint256[] calldata daysUtc, bool isHoliday) external onlyOwner {
        for (uint256 i; i < daysUtc.length; ++i) {
            _setHoliday(daysUtc[i], isHoliday);
        }
    }

    /// @notice Append a DST window (use when extending the table past 2030).
    function appendDstWindow(uint64 startTs, uint64 endTs) external onlyOwner {
        require(startTs < endTs, "NyseHours: bad window");
        if (dstWindows.length > 0) {
            require(dstWindows[dstWindows.length - 1].endTs <= startTs, "NyseHours: out of order");
        }
        dstWindows.push(DstWindow(startTs, endTs));
        emit DstWindowSet(dstWindows.length - 1, startTs, endTs);
        lastUpdate = uint64(block.timestamp);
    }

    /// @notice Replace the entire DST table — only needed if Congress changes DST rules.
    function replaceDstWindows(DstWindow[] calldata windows) external onlyOwner {
        delete dstWindows;
        emit DstWindowsCleared();
        for (uint256 i; i < windows.length; ++i) {
            DstWindow calldata w = windows[i];
            require(w.startTs < w.endTs, "NyseHours: bad window");
            if (i > 0) require(windows[i - 1].endTs <= w.startTs, "NyseHours: out of order");
            dstWindows.push(w);
            emit DstWindowSet(i, w.startTs, w.endTs);
        }
        lastUpdate = uint64(block.timestamp);
    }

    /// @notice Pre-computed day index for `(year, month, day)` UTC. Convenience for off-chain
    ///         callers writing `setHolidays`.
    function utcDay(uint256 year, uint256 month, uint256 day) external pure returns (uint256) {
        return _utcDay(year, month, day);
    }

    /// @notice How many DST windows are currently configured.
    function dstWindowCount() external view returns (uint256) {
        return dstWindows.length;
    }

    // ---------------------------------------------------------------------- //
    //                                INTERNALS                               //
    // ---------------------------------------------------------------------- //

    function _setHoliday(uint256 dayIndexUtc, bool isHoliday) internal {
        holiday[dayIndexUtc] = isHoliday;
        emit HolidaySet(dayIndexUtc, isHoliday);
        lastUpdate = uint64(block.timestamp);
    }

    function _isDst(uint256 ts) internal view returns (bool) {
        // Linear scan — N is small (5 windows / 5 years) and growing slowly.
        uint256 n = dstWindows.length;
        for (uint256 i; i < n; ++i) {
            DstWindow memory w = dstWindows[i];
            if (ts >= w.startTs && ts < w.endTs) return true;
            if (ts < w.startTs) return false; // sorted; can short-circuit
        }
        return false;
    }

    // --- Date math ------------------------------------------------------- //

    /// @dev Days since Unix epoch (1970-01-01 UTC) for the given UTC calendar date.
    ///      Uses the standard "Howard Hinnant" days-from-civil algorithm, valid for any date
    ///      after 0000-03-01 with proleptic Gregorian.
    function _utcDay(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        if (month <= 2) {
            year -= 1;
        }
        uint256 era = year / 400;
        uint256 yoe = year - era * 400;
        uint256 doy = month > 2 ? (153 * (month - 3) + 2) / 5 + day - 1 : (153 * (month + 9) + 2) / 5 + day - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        // Days from Unix epoch = era * 146097 + doe - 719468
        // 719468 = days from 0000-03-01 to 1970-01-01.
        return era * 146097 + doe - 719468;
    }

    function _utcTs(uint256 year, uint256 month, uint256 day, uint256 hour, uint256 minute)
        internal
        pure
        returns (uint64)
    {
        return uint64(_utcDay(year, month, day) * SECONDS_PER_DAY + hour * 3600 + minute * 60);
    }
}
