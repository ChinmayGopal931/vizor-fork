import { calculateBroadcasterFeeERC20Amount } from '@railgun-community/wallet';

/** What gas at `gasDetails` costs at `feeToken`'s rate, as a broadcaster's fee note pays it, never under `minFee`. */
export function gasFee(feeToken, gasDetails, minFee) {
  const { amount } = calculateBroadcasterFeeERC20Amount(feeToken, gasDetails);
  return amount > minFee ? amount : minFee;
}
