/** One-line Urufu Gemu rebate eligibility for a wallet, from its NFT balance. */
export function gemuEligibilityText(args: {
  connected: boolean;
  balance?: bigint;
  isLoading?: boolean;
  isError?: boolean;
}): {text: string; eligible: boolean} {
  if (!args.connected) return {text: "Connect wallet to check", eligible: false};
  if (args.isError) return {text: "Could not check NFT balance", eligible: false};
  if (args.balance === undefined || args.isLoading) return {text: "Checking…", eligible: false};
  if (args.balance === 0n) return {text: "Not eligible · no Urufu Gemu NFT in this wallet", eligible: false};
  const n = args.balance.toString();
  return {text: `Eligible · holds ${n} Urufu Gemu NFT${args.balance === 1n ? "" : "s"}`, eligible: true};
}
