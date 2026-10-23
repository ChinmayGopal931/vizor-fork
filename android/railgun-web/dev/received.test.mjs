import assert from 'node:assert/strict';
import { test } from 'node:test';
import { TransactionHistoryItemCategory } from '@railgun-community/shared-models';
import { hasUndatedReceipts, receivedSends } from '../src/received.js';

const USDC = '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238';

// A history item as `getWalletTransactionHistory` lists it, with only the fields read here.
function item(category, receiveERC20Amounts = [], extra = {}) {
  return { txid: `0x${'ab'.repeat(32)}`, timestamp: 1790000000, category, receiveERC20Amounts, ...extra };
}

function amount(value, extra = {}) {
  return { tokenAddress: USDC, amount: value, balanceBucket: 'Spendable', ...extra };
}

test('a received private send is listed, one entry per token amount', () => {
  const sends = receivedSends([
    item(TransactionHistoryItemCategory.TransferReceiveERC20s, [amount(5_000_000n), amount(1n)]),
  ]);
  assert.deepEqual(sends, [
    { txid: `0x${'ab'.repeat(32)}`, timestamp: 1790000000, token: USDC, amount: '5000000', bucket: 'Spendable', sender: null },
    { txid: `0x${'ab'.repeat(32)}`, timestamp: 1790000000, token: USDC, amount: '1', bucket: 'Spendable', sender: null },
  ]);
});

test('the sender shows only where it showed itself, and a missing time is null', () => {
  const [shown, hidden] = receivedSends([
    item(TransactionHistoryItemCategory.TransferReceiveERC20s, [
      amount(1n, { senderAddress: '0zk1sender', balanceBucket: 'MissingExternalPOI' }),
    ]),
    item(TransactionHistoryItemCategory.TransferReceiveERC20s, [amount(2n)], { timestamp: undefined }),
  ]);
  assert.equal(shown.sender, '0zk1sender');
  assert.equal(shown.bucket, 'MissingExternalPOI');
  assert.equal(hidden.sender, null);
  assert.equal(hidden.timestamp, null);
});

test('shields, sends, withdrawals and mixed items are not received sends', () => {
  const others = [
    TransactionHistoryItemCategory.ShieldERC20s,
    TransactionHistoryItemCategory.TransferSendERC20s,
    TransactionHistoryItemCategory.UnshieldERC20s,
    TransactionHistoryItemCategory.Unknown,
  ].map((category) => item(category, [amount(3n)]));
  assert.deepEqual(receivedSends(others), []);
});

test('a send the engine has no time for is dated from the nearest dated block, 12 s a block', () => {
  const { ShieldERC20s, TransferReceiveERC20s, UnshieldERC20s } = TransactionHistoryItemCategory;
  const sends = receivedSends([
    item(ShieldERC20s, [], { blockNumber: 100, timestamp: 1790000000 }),
    item(TransferReceiveERC20s, [amount(1n)], { blockNumber: 105, timestamp: undefined }),
    item(UnshieldERC20s, [], { blockNumber: 200, timestamp: 1790002000 }),
    item(TransferReceiveERC20s, [amount(2n)], { blockNumber: 190, timestamp: undefined }),
  ]);
  assert.deepEqual(
    sends.map(({ timestamp }) => timestamp),
    [1790000000 + 5 * 12, 1790002000 - 10 * 12],
  );
});

test('with no dated block in the history, the newest block dates it', () => {
  const history = [
    item(TransactionHistoryItemCategory.TransferReceiveERC20s, [amount(1n)], { blockNumber: 990, timestamp: undefined }),
  ];
  assert.equal(hasUndatedReceipts(history), true);
  const [send] = receivedSends(history, { blockNumber: 1000, timestamp: 1790000000 });
  assert.equal(send.timestamp, 1790000000 - 10 * 12);
  assert.equal(receivedSends(history)[0].timestamp, null);
});

test('only an undated received send asks for the newest block', () => {
  const { ShieldERC20s, TransferReceiveERC20s } = TransactionHistoryItemCategory;
  assert.equal(hasUndatedReceipts([item(TransferReceiveERC20s, [amount(1n)])]), false);
  assert.equal(hasUndatedReceipts([item(ShieldERC20s, [amount(1n)], { timestamp: undefined })]), false);
});
