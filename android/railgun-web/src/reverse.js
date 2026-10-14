import { EVMGasType, NETWORK_CONFIG, getEVMGasTypeForTransaction } from '@railgun-community/shared-models';
import {
  generateCrossContractCallsProof,
  populateProvedCrossContractCalls,
} from '@railgun-community/wallet';
import { getAddress } from 'ethers';
import { badRequest } from './errors.js';
import { fundingAmounts } from './reverse-amounts.js';
import { unsignedFunding } from './reverse-envelope.js';
import { progress, spend } from './transact.js';
import { TXID_VERSION, session } from './wallet.js';

/** What unshielding enough to leave `amount` in escrow and pay the relayer `fee` costs, at the fee the engine loaded. */
export function reverseCost({ amount, fee, railgun }) {
  const { network, fees } = session();
  const proxy = NETWORK_CONFIG[network].proxyContract;
  if (getAddress(railgun) !== getAddress(proxy)) throw badRequest(`the engine's Railgun contract is ${proxy}`);
  if (BigInt(fee) < 0n) throw badRequest('invalid relayer fee');
  return fundingAmounts(BigInt(amount) + BigInt(fee), BigInt(fees.unshield));
}

export const prepareReverse = (params, emit) =>
  spend(async () => {
    const { network, walletId, encryptionKey, address } = session();
    const { token, calls } = params;
    const cost = reverseCost(params);
    const relayAdapt = NETWORK_CONFIG[network].relayAdaptContract;
    if (getAddress(params.relayAdapt) !== getAddress(relayAdapt)) throw badRequest('the funding adapter differs from the engine');
    const unshield = [{ tokenAddress: token, amount: BigInt(cost.debit) }];
    const shield = [{ tokenAddress: token, recipientAddress: address }];
    const transactions = calls.map(({ to, data }) => ({ to, data, value: 0n }));
    if (transactions.length !== 3 || transactions.some(({ to }, i) => i !== 1 && getAddress(to) !== getAddress(token))) {
      throw badRequest('expected approval, escrow open and relayer fee');
    }
    // Public-wallet mode binds requireSuccess=true. The relayer estimates real-proof gas and signs the envelope.
    await generateCrossContractCallsProof(
      TXID_VERSION, network, walletId, encryptionKey, unshield, [], shield, [], transactions,
      undefined, true, undefined, undefined, progress(emit),
    );
    const { transaction } = await populateProvedCrossContractCalls(
      TXID_VERSION, network, walletId, unshield, [], shield, [], transactions,
      undefined, true, undefined, {
        evmGasType: getEVMGasTypeForTransaction(network, true),
        gasEstimate: 0n,
        maxFeePerGas: 0n,
        maxPriorityFeePerGas: 0n,
      },
    );
    if (getEVMGasTypeForTransaction(network, true) !== EVMGasType.Type2) throw badRequest('unsupported funding gas type');
    return { ...unsignedFunding(transaction, relayAdapt), cost };
  });
