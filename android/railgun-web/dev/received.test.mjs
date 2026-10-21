import assert from 'node:assert/strict';
import { test } from 'node:test';
import { TransactionHistoryItemCategory } from '@railgun-community/shared-models';
import { receivedSends } from '../src/received.js';

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
