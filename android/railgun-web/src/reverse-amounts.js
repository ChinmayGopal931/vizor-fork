export function fundingAmounts(escrow, basisPoints) {
  if (escrow <= 0n || basisPoints < 0n || basisPoints >= 10000n) throw new Error('invalid funding amount or fee');
  const debit = (escrow - 1n) * 10000n / (10000n - basisPoints) + 1n;
  return { debit: debit.toString(), railgunFee: (debit - escrow).toString() };
}
