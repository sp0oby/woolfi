"""Canonical Robinhood launch catalog shared by deployment tooling."""

CHAIN_ID = 4663
ZERO = "0x0000000000000000000000000000000000000000"
POOL_MANAGER = "0x8366a39cc670b4001a1121b8f6a443a643e40951"
STAKING_TOKEN = "0x9fbe210007ddd8389f98d0253018e65cc48b9d24"

ASSETS = {
    "MSTR": "0xec262a75e413fafd0df80480274532c79d42da09",
    "COIN": "0x6330d8c3178a418788df01a47479c0ce7ccf450b",
    "CRCL": "0xdf0992e440dd0be65bd8439b609d6d4366bf1cb5",
    "NVDA": "0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec",
    "SPY": "0x117cc2133c37b721f49de2a7a74833232b3b4c0c",
    "GLD": "0xc9a981fee1f9dec688bb123ccdecc63d0debfc4e",
    "WETH": "0x0bd7d308f8e1639fab988df18a8011f41eacad73",
    "USDG": "0x5fc5360d0400a0fd4f2af552add042d716f1d168",
    "QQQ": "0xd5f3879160bc7c32ebb4dc785f8a4f505888de68",
    "PLTR": "0x894e1ec2d74ffe5aef8dc8a9e84686accb964f2a",
    "AAPL": "0xaf3d76f1834a1d425780943c99ea8a608f8a93f9",
    "MSFT": "0xe93237c50d904957cf27e7b1133b510c669c2e74",
    "SMH": "0x072f979c2cac8e1391b0162a87fee094bf8744a0",
    "SOXX": "0x075742c18bc1f1c5c5f448f4c9d9c6f66dafaa38",
    "XLK": "0x15cd20759ce7f3285c29a319de2d1a2e098c6f43",
    "SLV": "0x411efb0e7f985935daec3d4c3ebaea0d0ad7d89f",
}

PAIRS = (
    ("MSTR", "USDG"), ("COIN", "USDG"), ("CRCL", "USDG"),
    ("NVDA", "USDG"), ("SPY", "USDG"), ("GLD", "USDG"),
    ("MSTR", "WETH"), ("COIN", "WETH"), ("QQQ", "WETH"),
    ("NVDA", "WETH"), ("PLTR", "WETH"), ("AAPL", "MSFT"),
    ("NVDA", "SMH"), ("SMH", "SOXX"), ("XLK", "QQQ"),
    ("SPY", "QQQ"), ("GLD", "SLV"), ("WETH", "USDG"),
)

SLUGS = tuple(f"{base.lower()}-{quote.lower()}" for base, quote in PAIRS)
SPREAD_SLUGS = frozenset(
    ("aapl-msft", "nvda-smh", "smh-soxx", "xlk-qqq", "spy-qqq", "gld-slv")
)
ALWAYS_OPEN_SLUGS = frozenset(("weth-usdg",))
GATE_FIELDS = (
    "auditComplete",
    "multisigApproved",
    "uruCapsApproved",
    "oraclesVerified",
    "initialLiquidityApproved",
    "keeperReady",
    "indexerReady",
    "frontendReviewed",
)
