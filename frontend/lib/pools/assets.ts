import type {CuratedAsset} from "./types";

export const robinhoodAssets = {
  URU: asset("URU", "URU", "staking", "0x9fbe210007dDd8389f98d0253018e65CC48b9D24", 18),
  WETH: asset("WETH", "Wrapped Ether", "crypto", "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73", 18),
  USDG: asset("USDG", "Global Dollar", "stable", "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", 6),
  MSTR: asset("MSTR", "Strategy", "stock", "0xec262a75e413fAfD0dF80480274532C79D42da09"),
  COIN: asset("COIN", "Coinbase", "stock", "0x6330D8C3178a418788dF01a47479c0ce7CCF450b"),
  CRCL: asset("CRCL", "Circle", "stock", "0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5"),
  PLTR: asset("PLTR", "Palantir Technologies", "stock", "0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A"),
  NVDA: asset("NVDA", "NVIDIA", "stock", "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC"),
  AAPL: asset("AAPL", "Apple", "stock", "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9"),
  MSFT: asset("MSFT", "Microsoft", "stock", "0xe93237C50D904957Cf27E7B1133b510C669c2e74"),
  TSLA: asset("TSLA", "Tesla", "stock", "0x322F0929c4625eD5bAd873c95208D54E1c003b2d"),
  SPY: asset("SPY", "SPDR S&P 500 ETF", "etf", "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C"),
  QQQ: asset("QQQ", "Invesco QQQ", "etf", "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68"),
  GLD: asset("GLD", "SPDR Gold Shares", "etf", "0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e"),
  SLV: asset("SLV", "iShares Silver Trust", "etf", "0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f"),
} as const satisfies Record<string, CuratedAsset>;

export type RobinhoodSymbol = keyof typeof robinhoodAssets;

function asset(
  symbol: string,
  name: string,
  kind: CuratedAsset["kind"],
  address: CuratedAsset["address"],
  decimals = 18,
): CuratedAsset {
  return {symbol, name, kind, address, decimals};
}
