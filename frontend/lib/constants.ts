/** v4 LPFeeLibrary.DYNAMIC_FEE_FLAG = 0x800000 - the fee value a dynamic-fee pool is initialized with. */
export const LPFeeLibraryDynamicFee = 0x800000;

/** Power of 10. */
export const WAD = 10n ** 18n;
export const BPS = 10_000n;

/** Official Uniswap v3 NonfungiblePositionManager on Robinhood Chain (4663), from Uniswap's
 *  sdk-core address book; factory 0x1f7d...2efa, WETH9 0x0Bd7...AD73 verified on-chain. */
export const UNISWAP_V3_NPM = "0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3" as const;
