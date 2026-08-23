// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MultisigMarketHours} from "../../src/oracle/MultisigMarketHours.sol";

contract MultisigMarketHoursTest is Test {
    MultisigMarketHours mh;
    address owner = address(this);
    address stranger = makeAddr("stranger");

    function setUp() public {
        mh = new MultisigMarketHours(owner, true);
    }

    function test_constructor_initialState() public view {
        assertTrue(mh.open());
        assertTrue(mh.isMarketOpen());
        assertEq(mh.lastUpdate(), uint64(block.timestamp));
        assertEq(mh.owner(), owner);
        assertEq(mh.currentSessionStart(), block.timestamp);
    }

    function test_constructor_initiallyClosed() public {
        MultisigMarketHours mh2 = new MultisigMarketHours(owner, false);
        assertFalse(mh2.isMarketOpen());
    }

    function test_setOpen_updatesFlagAndTimestamp() public {
        skip(100);
        mh.setOpen(false);
        assertFalse(mh.isMarketOpen());
        assertEq(mh.lastUpdate(), uint64(block.timestamp));
        assertEq(mh.currentSessionStart(), 0);
    }

    function test_reopen_recordsCurrentSessionStart() public {
        mh.setOpen(false);
        skip(1 days);
        mh.setOpen(true);
        assertEq(mh.currentSessionStart(), block.timestamp);
        skip(1 hours);
        assertEq(mh.currentSessionStart(), block.timestamp - 1 hours);
    }

    function testRevert_setOpen_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mh.setOpen(false);
    }

    function test_setOpen_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(mh));
        emit MultisigMarketHours.MarketStatusUpdated(false, uint64(block.timestamp));
        mh.setOpen(false);
    }
}
