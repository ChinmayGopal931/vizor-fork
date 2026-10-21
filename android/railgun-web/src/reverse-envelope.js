import { getAddress } from 'ethers';
import { badRequest } from './errors.js';

/** Only the proof-bound fields cross into the relayer; its account supplies nonce, fees and signature. */
export function unsignedFunding(transaction, relayAdapt) {
  if (getAddress(transaction.to) !== getAddress(relayAdapt) || BigInt(transaction.value ?? 0n) !== 0n) {
    throw badRequest('unexpected sponsored funding destination or value');
  }
  if (typeof transaction.data !== 'string' || !/^0x(?:[0-9a-fA-F]{2}){4,65536}$/.test(transaction.data)) {
    throw badRequest('invalid sponsored funding calldata');
  }
  return { to: transaction.to, data: transaction.data, value: '0' };
}
