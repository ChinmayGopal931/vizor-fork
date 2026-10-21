import { TransactionHistoryItemCategory } from '@railgun-community/shared-models';

/**
 * The private sends a wallet received, from its history as the SDK lists it: `{txid, timestamp, token, amount,
 * bucket, sender}` for each token amount, `timestamp` null where the engine has no time for its block, and `sender`
 * only where the sender showed its 0zk address. Shields (a deposit, a bridge's payout) and change are not received
 * sends.
 */
export function receivedSends(history) {
  return history
    .filter(({ category }) => category === TransactionHistoryItemCategory.TransferReceiveERC20s)
    .flatMap(({ txid, timestamp, receiveERC20Amounts }) =>
      receiveERC20Amounts.map(({ tokenAddress, amount, balanceBucket, senderAddress }) => ({
        txid,
        timestamp: timestamp || null,
        token: tokenAddress,
        amount: amount.toString(),
        bucket: balanceBucket,
        sender: senderAddress ?? null,
      })),
    );
}
