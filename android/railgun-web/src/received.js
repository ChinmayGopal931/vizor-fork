import { RailgunWalletBalanceBucket, TransactionHistoryItemCategory } from '@railgun-community/shared-models';

// Ethereum's slot time. A slot can pass without a block, so a block dated this way is off by the slots missed
// between it and the block it is dated from.
const SECONDS_PER_BLOCK = 12;

/**
 * The private sends a wallet received, from its history as the SDK lists it: `{txid, timestamp, token, amount,
 * bucket, sender}` for each token amount, and `sender` only where the sender showed its 0zk address. Shields (a
 * deposit, a bridge's payout) and change are not received sends.
 *
 * A send whose block the engine has no time for is dated from the nearest block it does have one for, in the history
 * or `head` (`{blockNumber, timestamp}`, the newest block), at 12 s a block; `timestamp` is null where neither dates it.
 */
export function receivedSends(history, head) {
  const dated = datedItems(history, head);
  return history
    .filter(isReceived)
    .flatMap((item) =>
      item.receiveERC20Amounts.map(({ tokenAddress, amount, balanceBucket, senderAddress }) => ({
        txid: item.txid,
        timestamp: timeOf(item, dated),
        token: tokenAddress,
        amount: amount.toString(),
        bucket: balanceBucket,
        sender: senderAddress ?? null,
      })),
    );
}

const isReceived = ({ category }) => category === TransactionHistoryItemCategory.TransferReceiveERC20s;

/** Whether a received send in `history` has no time of its own: then the newest block is worth reading to date it. */
export const hasUndatedReceipts = (history) => history.some((item) => isReceived(item) && !item.timestamp);

/**
 * The shields screening still holds (`ShieldPending`), from the wallet's history: `{timestamp, token}` for each token
 * amount, dated as `receivedSends` dates a send. A deposit, a bridge's payout and a shield from another wallet all
 * land as one.
 */
export function pendingShields(history, head) {
  const dated = datedItems(history, head);
  return history.flatMap((item) =>
    item.receiveERC20Amounts
      .filter(isPending)
      .map(({ tokenAddress }) => ({ timestamp: timeOf(item, dated), token: tokenAddress })),
  );
}

/** Whether a shield screening still holds has no time of its own: then the newest block is worth reading too. */
export const hasUndatedShields = (history) =>
  history.some((item) => !item.timestamp && item.receiveERC20Amounts.some(isPending));

const isPending = ({ balanceBucket }) => balanceBucket === RailgunWalletBalanceBucket.ShieldPending;

const datedItems = (history, head) => [...history, head].filter((item) => item?.timestamp && item.blockNumber != null);

function timeOf({ timestamp, blockNumber }, dated) {
  if (timestamp) return timestamp;
  if (blockNumber == null || dated.length === 0) return null;
  const distance = (item) => Math.abs(item.blockNumber - blockNumber);
  const nearest = dated.reduce((best, item) => (distance(item) < distance(best) ? item : best));
  return nearest.timestamp + (blockNumber - nearest.blockNumber) * SECONDS_PER_BLOCK;
}
