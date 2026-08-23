// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DualOracleAdapter} from "../../src/oracle/DualOracleAdapter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";

contract DualOracleAdapterTest is Test {
    MockPriceOracle primary;
    MockPriceOracle backup;
    DualOracleAdapter adapter;

    uint16 constant MAX_DEV_BPS = 200; // 2%

    function setUp() public {
        primary = new MockPriceOracle(100e18);
        backup = new MockPriceOracle(100e18);
        adapter = new DualOracleAdapter(primary, backup, MAX_DEV_BPS);
    }

    // -----------------------------------------------------------------
    // happy paths
    // -----------------------------------------------------------------

    function test_getPrice_returnsPrimary_whenSourcesAgree() public view {
        assertEq(adapter.getPrice(), 100e18);
    }

    function test_getPriceData_returnsPrimaryMetadata() public {
        skip(10);
        primary.setPriceData(100e18, block.timestamp - 1);
        backup.setPriceData(100e18, block.timestamp - 2);
        (uint256 price, uint256 updatedAt) = adapter.getPriceData();
        assertEq(price, 100e18);
        assertEq(updatedAt, block.timestamp - 1);
    }

    function testRevert_getPriceData_doesNotSilentlyFailOverUnsafeError() public {
        primary.setStale(true);
        vm.expectRevert(MockPriceOracle.MockStale.selector);
        adapter.getPriceData();
    }

    function test_getPrice_acceptsExactlyAtDeviationBoundary() public {
        // |102-100|/100 = 2% exactly -> within threshold (strict `>` check)
        backup.setPrice(102e18);
        assertEq(adapter.getPrice(), 100e18);
    }

    function test_getPrice_failsOver_primaryStaleBackupFresh() public {
        primary.setStale(true);
        backup.setPrice(101e18);
        assertEq(adapter.getPrice(), 101e18); // silently returns backup
    }

    function test_getPrice_failsOver_backupStalePrimaryFresh() public {
        backup.setStale(true);
        primary.setPrice(101e18);
        // backup unhealthy -> use primary alone; deviation check is skipped (can't compute)
        assertEq(adapter.getPrice(), 101e18);
    }

    // -----------------------------------------------------------------
    // revert paths
    // -----------------------------------------------------------------

    function testRevert_getPrice_bothStale() public {
        primary.setStale(true);
        backup.setStale(true);
        vm.expectRevert(DualOracleAdapter.BothStale.selector);
        adapter.getPrice();
    }

    function testRevert_getPrice_deviationOverThreshold() public {
        backup.setPrice(103e18); // 3% deviation, above 2%
        vm.expectRevert(abi.encodeWithSelector(DualOracleAdapter.PriceDeviation.selector, 100e18, 103e18));
        adapter.getPrice();
    }

    function testRevert_getPrice_deviationSymmetric() public {
        // also reverts when primary is the higher side
        primary.setPrice(105e18);
        vm.expectRevert(abi.encodeWithSelector(DualOracleAdapter.PriceDeviation.selector, 105e18, 100e18));
        adapter.getPrice();
    }

    // -----------------------------------------------------------------
    // constructor guards
    // -----------------------------------------------------------------

    function testRevert_constructor_zeroPrimary() public {
        vm.expectRevert(DualOracleAdapter.InvalidConfig.selector);
        new DualOracleAdapter(IPriceOracle(address(0)), backup, MAX_DEV_BPS);
    }

    function testRevert_constructor_zeroBackup() public {
        vm.expectRevert(DualOracleAdapter.InvalidConfig.selector);
        new DualOracleAdapter(primary, IPriceOracle(address(0)), MAX_DEV_BPS);
    }

    function testRevert_constructor_zeroBps() public {
        vm.expectRevert(DualOracleAdapter.InvalidConfig.selector);
        new DualOracleAdapter(primary, backup, 0);
    }

    function testRevert_constructor_bpsOverBps() public {
        vm.expectRevert(DualOracleAdapter.InvalidConfig.selector);
        new DualOracleAdapter(primary, backup, 10_001);
    }
}
