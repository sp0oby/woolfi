// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Read-only Robinhood mainnet deployment sanity checks.
/// @dev Skips safely when ROBINHOOD_RPC_URL is absent; never assumes funded accounts or transfers tokens.
contract RobinhoodMainnetForkTest is Test {
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;

    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant URU = 0x9fbe210007dDd8389f98d0253018e65CC48b9D24;

    struct CandidatePair {
        address base;
        address quote;
    }

    function test_fork_canonicalContractsAndMetadata() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpc);
        assertEq(block.chainid, ROBINHOOD_CHAIN_ID);

        assertGt(POOL_MANAGER.code.length, 0, "PoolManager missing");
        assertGt(URU.code.length, 0, "URU missing");
        assertEq(IERC20Metadata(URU).symbol(), "URU");
        assertEq(IERC20Metadata(URU).decimals(), 18);

        (address[] memory assets, string[] memory symbols) = _canonicalAssets();
        for (uint256 i; i < assets.length; ++i) {
            assertGt(assets[i].code.length, 0, string.concat("canonical ", symbols[i], " missing"));
            assertEq(IERC20Metadata(assets[i]).symbol(), symbols[i], string.concat(symbols[i], " symbol mismatch"));
        }
    }

    function test_curatedCandidatesAreCanonicalAndUnique() public pure {
        (address[] memory assets,) = _canonicalAssets();
        CandidatePair[] memory pairs = _candidatePairs();

        for (uint256 i; i < assets.length; ++i) {
            for (uint256 j = i + 1; j < assets.length; ++j) {
                assertTrue(assets[i] != assets[j], "duplicate canonical asset");
            }
        }

        for (uint256 i; i < pairs.length; ++i) {
            assertTrue(pairs[i].base != pairs[i].quote, "self-pair candidate");
            assertTrue(_contains(assets, pairs[i].base), "noncanonical candidate base");
            assertTrue(_contains(assets, pairs[i].quote), "noncanonical candidate quote");
            for (uint256 j = i + 1; j < pairs.length; ++j) {
                bool duplicate = pairs[i].base == pairs[j].base && pairs[i].quote == pairs[j].quote;
                bool reversed = pairs[i].base == pairs[j].quote && pairs[i].quote == pairs[j].base;
                assertTrue(!duplicate && !reversed, "duplicate or reversed candidate");
            }
        }
    }

    function _canonicalAssets() private pure returns (address[] memory assets, string[] memory symbols) {
        assets = new address[](18);
        symbols = new string[](18);
        assets[0] = 0xec262a75e413fAfD0dF80480274532C79D42da09;
        symbols[0] = "MSTR";
        assets[1] = 0x6330D8C3178a418788dF01a47479c0ce7CCF450b;
        symbols[1] = "COIN";
        assets[2] = 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5;
        symbols[2] = "CRCL";
        assets[3] = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
        symbols[3] = "SPY";
        assets[4] = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
        symbols[4] = "QQQ";
        assets[5] = 0x15Cd20759CE7F3285c29A319dE2D1A2e098c6f43;
        symbols[5] = "XLK";
        assets[6] = 0x072f979c2CAc8e1391B0162a87Fee094bF8744a0;
        symbols[6] = "SMH";
        assets[7] = 0x75742c18BC1f1C5c5f448f4C9D9C6F66dafAAa38;
        symbols[7] = "SOXX";
        assets[8] = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
        symbols[8] = "NVDA";
        assets[9] = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
        symbols[9] = "AAPL";
        assets[10] = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
        symbols[10] = "MSFT";
        assets[11] = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
        symbols[11] = "TSLA";
        assets[12] = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
        symbols[12] = "META";
        assets[13] = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
        symbols[13] = "GLD";
        assets[14] = 0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f;
        symbols[14] = "SLV";
        assets[15] = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
        symbols[15] = "WETH";
        assets[16] = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
        symbols[16] = "USDG";
        assets[17] = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A;
        symbols[17] = "PLTR";
    }

    function _candidatePairs() private pure returns (CandidatePair[] memory pairs) {
        (address[] memory a,) = _canonicalAssets();
        pairs = new CandidatePair[](18);
        pairs[0] = CandidatePair(a[0], a[16]); // MSTR/USDG
        pairs[1] = CandidatePair(a[1], a[16]); // COIN/USDG
        pairs[2] = CandidatePair(a[2], a[16]); // CRCL/USDG
        pairs[3] = CandidatePair(a[8], a[16]); // NVDA/USDG
        pairs[4] = CandidatePair(a[3], a[16]); // SPY/USDG
        pairs[5] = CandidatePair(a[13], a[16]); // GLD/USDG
        pairs[6] = CandidatePair(a[0], a[15]); // MSTR/WETH
        pairs[7] = CandidatePair(a[1], a[15]); // COIN/WETH
        pairs[8] = CandidatePair(a[4], a[15]); // QQQ/WETH
        pairs[9] = CandidatePair(a[8], a[15]); // NVDA/WETH
        pairs[10] = CandidatePair(a[9], a[10]); // AAPL/MSFT
        pairs[11] = CandidatePair(a[8], a[6]); // NVDA/SMH
        pairs[12] = CandidatePair(a[6], a[7]); // SMH/SOXX
        pairs[13] = CandidatePair(a[5], a[4]); // XLK/QQQ
        pairs[14] = CandidatePair(a[3], a[4]); // SPY/QQQ
        pairs[15] = CandidatePair(a[13], a[14]); // GLD/SLV
        pairs[16] = CandidatePair(a[15], a[16]); // WETH/USDG
        pairs[17] = CandidatePair(a[17], a[15]); // PLTR/WETH
    }

    function _contains(address[] memory values, address candidate) private pure returns (bool) {
        for (uint256 i; i < values.length; ++i) {
            if (values[i] == candidate) return true;
        }
        return false;
    }
}
