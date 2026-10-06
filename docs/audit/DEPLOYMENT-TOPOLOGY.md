# Deployment Topology (post-deploy, Robinhood Chain 4663)

```mermaid
flowchart TB
  Safe["Safe multisig (2-of-3+)"]
  Gov["WoolFiGovernor (Ownable2Step)"]
  Hook["WoolFiHook (CREATE2-mined)"]
  PM["WoolFiPositionManager"]
  Router["WoolFiSwapRouter"]
  Zap["WoolFiLiquidityZapper"]
  Rebate["UrufuFeeRebateDistributor"]
  PMgr["Uniswap v4 PoolManager"]
  Vaults["18 x WoolFiUnderwritingVault (URU)"]
  Adapters["14 oracle adapters: 12 RobinhoodStockOracleAdapter + 2 ChainlinkOracleAdapter (WETH, USDG)"]
  CL["Chainlink feeds (14)"]
  Hours["NyseHoursOracle"]
  V3["Uniswap v3 router (allowlisted executor)"]
  Keeper["Keeper EOA / RebalanceKeeper"]

  Safe -- owner --> Gov
  Safe -- owner --> PM
  Safe -- owner --> Zap
  Safe -- owner --> Rebate
  Safe -- owner --> Hours
  Gov -- governor role --> Hook
  Hook -- callbacks for 18 pools --> PMgr
  Hook -- realizeFromHook --> PM
  Hook -- drawdown (onlyHook) --> Vaults
  Hook -- reads --> Adapters
  Hook -- reads --> Hours
  Adapters -- latestRoundData --> CL
  PM -- sole LP, modifyLiquidity --> PMgr
  PM -- depositRewards --> Vaults
  Router -- swap via unlock --> PMgr
  Router -- recordSwap (bound once) --> Rebate
  Rebate -- reads baseFee --> Hook
  Zap -- mint --> PM
  Zap -- exact approval --> V3
  Vaults -- seized URU --> Safe
  Keeper -- checkStructuralBreak --> Hook
```

## Authorization edges

- Safe owns: governor (must call `acceptOwnership`), PM (constructor owner), zapper, rebate
  distributor, market-hours oracle.
- Governor holds the hook `governor` role (accepted during deploy).
- Hook is the only caller of each vault's `drawdown`; vault `rebalancer` (seized URU recipient)
  is immutable and set to the Safe.
- PM is the only allowed LP on WoolFi pools once wired (`UnauthorizedLiquidityProvider`).
- Router is bound once as the rebate distributor's recorder.
- Keeper and `checkStructuralBreak` are permissionless; the keeper holds no protocol funds.
