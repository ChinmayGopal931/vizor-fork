import { RailgunWallet, setEngineTxidSyncBatchSize } from '@railgun-community/engine';
import {
  MerkletreeScanStatus,
  NETWORK_CONFIG,
  NetworkName,
  POIProofEventStatus,
  TXIDVersion,
} from '@railgun-community/shared-models';
import {
  createRailgunWallet,
  deleteWalletByID,
  generatePOIsForWallet,
  getEngine,
  getFallbackProviderForNetwork,
  getLatestRailgunTxidData,
  getProver,
  getSerializedERC20Balances,
  getWalletTransactionHistory,
  hasEngine,
  loadProvider,
  loadWalletByID,
  refreshBalances,
  refreshReceivePOIsForWallet,
  setLoggers,
  setOnTXIDMerkletreeScanCallback,
  setOnUTXOMerkletreeScanCallback,
  setOnWalletPOIProofProgressCallback,
  startRailgunEngine,
  syncRailgunTransactionsV2,
  walletForID,
} from '@railgun-community/wallet';
import LevelJS from 'level-js';
import { groth16 } from 'snarkjs';
import { setArtifactProgressListener } from './artifact-mirror.js';
import { artifactStore } from './artifacts.js';
import { badRequest } from './errors.js';
import { hasUndatedReceipts, receivedSends } from './received.js';
import { screeningActivity } from './screening-activity.js';
import { catchUpTxids, txidCompleteHold } from './txid-catch-up.js';
import { walletNamespaces } from './wallet-namespaces.js';

export const TXID_VERSION = TXIDVersion.V2_PoseidonMerkle;
const NETWORKS = { sepolia: NetworkName.EthereumSepolia, mainnet: NetworkName.Ethereum };
// Only in the encrypted annotations of the notes this wallet sends: neither the wallet's id nor where it is stored
// depends on it, so stored wallets open as before.
const WALLET_SOURCE = 'vizor';
// The engine's listener catches spends a scan misses, as it reads nullifiers from the latest commitment's block on.
const POLLING_INTERVAL_MS = 15_000;
const NOTES_SCAN_ATTEMPTS = 20;
const NOTES_SCAN_RETRY_MS = 3_000;
// A notes scan reports 3% as it starts, 1% on a full rescan; one the engine skips reports nothing.
const NOTES_SCAN_START = 0.03;
// The engine keeps the txids it syncs a batch at a time, and a page closed or paused before a batch ends keeps none of
// that batch. The engine's default batch is the 10,000 that Railgun's subgraph hands over at once, which takes a phone
// minutes; a wallet cut off that often never catches up, and can't prove its sends. Smaller batches keep their progress.
const TXID_SYNC_BATCH_SIZE = 1_000;
// The engine reads on only while the subgraph's answer is one batch long, so each of its txid syncs now reads one
// answer of 10,000; a refresh syncs again until one adds nothing. Ethereum's whole history is about 15 answers.
const TXID_SYNC_PASSES = 50;
const TXID_SYNC_WAIT_MS = 1_000;
// Only a long catch-up is reported, so a refresh that finds a few new txids doesn't flash the row; it is read this often.
const TXID_REPORT_GAP = 1_000;
const TXID_REPORT_MS = 2_000;

let starting;
// The engine a page opened to delete wallets: its database alone, with no provider. Such a page is never started.
let deleting;
let network;
let fees;
let wallet;
let debug = false;
let notesScan;
let notesScans = Promise.resolve();
// Whether the proofs the open wallet's sends need failed when the engine last sent them. The engine screens by itself
// after every scan, outside any call, and reports how that went only through its callback.
let proofsFailed = false;
const txidHold = txidCompleteHold();
let activity;

const chain = () => NETWORK_CONFIG[network].chain;

/** The open wallet, for the calls that spend from it. */
export function session() {
  if (wallet === undefined) throw badRequest('no wallet is open');
  return { network, fees, ...wallet };
}

/** Whether the engine was started for debugging, which answers the debug-only calls too. */
export const isDebug = () => debug;

/** Starts the engine once; a start that failed may run again. */
export function start({ network: name, rpcUrls, poiNodeUrls, debug: debugging = false }, emit) {
  const networkName = NETWORKS[name];
  if (networkName === undefined) throw badRequest(`unknown network ${name}`);
  if (!rpcUrls?.length) throw badRequest('no RPC URLs');
  if (deleting !== undefined) throw badRequest('this page deletes wallets');
  if (starting === undefined) {
    debug = debugging === true;
    const promise = startEngine(networkName, `railgun-${name}`, rpcUrls, poiNodeUrls, debug, emit);
    starting = { networkName, promise };
    promise.catch(() => {
      if (starting?.promise === promise) starting = undefined;
    });
  } else if (starting.networkName !== networkName) {
    throw badRequest(`the engine runs ${starting.networkName}`);
  }
  return starting.promise;
}

async function startEngine(networkName, database, rpcUrls, poiNodeUrls, debug, emit) {
  if (debug) setLoggers((message) => emit('log', String(message)), (error) => emit('log', String(error?.stack ?? error)));
  setEngineTxidSyncBatchSize(TXID_SYNC_BATCH_SIZE);
  await startRailgunEngine(WALLET_SOURCE, new LevelJS(database), debug, artifactStore, false, false, poiNodeUrls);
  getProver().setSnarkJSGroth16(groth16);
  setOnUTXOMerkletreeScanCallback(({ scanStatus, progress }) => {
    if (notesScan !== undefined) {
      if (scanStatus === MerkletreeScanStatus.Updated && progress <= NOTES_SCAN_START) notesScan.started = true;
      if (scanStatus === MerkletreeScanStatus.Incomplete) notesScan.incomplete = true;
    }
    emit('scan', { tree: 'utxo', status: scanStatus, progress });
  });
  setOnTXIDMerkletreeScanCallback(({ scanStatus, progress }) => {
    const event = { tree: 'txid', status: scanStatus, progress };
    if (txidHold.pass(event)) emit('scan', event);
  });
  activity = screeningActivity((state) => emit('screening', state));
  setArtifactProgressListener((url, loaded, total) => activity.download(url, loaded, total));
  setOnWalletPOIProofProgressCallback(({ status, railgunWalletID, progress, index, totalCount }) => {
    if (railgunWalletID !== wallet?.walletId) return;
    if (status === POIProofEventStatus.InProgress) {
      activity.proving({ index: index + 1, count: totalCount, progress: progress / 100 });
      return;
    }
    if (status === POIProofEventStatus.Error) proofsFailed = true;
    if (status === POIProofEventStatus.LoadingNextBatch || status === POIProofEventStatus.AllProofsCompleted) {
      proofsFailed = false;
    }
    activity.proving(null);
  });
  const providers = rpcUrls.map((url, index) => ({ provider: url, priority: index + 1, weight: 2 }));
  const config = { chainId: NETWORK_CONFIG[networkName].chain.id, providers };
  const { feesSerialized } = await loadProvider(config, networkName, POLLING_INTERVAL_MS);
  fees = { shield: Number(feesSerialized.shieldFeeV2), unshield: Number(feesSerialized.unshieldFeeV2) };
  network = networkName;
  return { fees };
}

/** Opens the wallet `mnemonic` derives at index 0, as Railway does; one stored under another key is made again. */
export const openWallet = ({ encryptionKey, mnemonic }) => open(encryptionKey, mnemonic, undefined);

/** Opens a wallet first used at `creationBlock`, which a sync then scans from: dev/check.mjs's fresh wallets. */
export const openNewWallet = ({ encryptionKey, mnemonic, creationBlock }) => open(encryptionKey, mnemonic, creationBlock);

async function open(encryptionKey, mnemonic, creationBlock) {
  if (network === undefined) throw badRequest('the engine is not running');
  const id = RailgunWallet.generateID(mnemonic, 0);
  if (wallet !== undefined) {
    if (wallet.walletId !== id) throw badRequest('another wallet is open');
    return { address: wallet.address };
  }
  let info;
  try {
    info = await loadWalletByID(encryptionKey, id, false);
  } catch {
    const creationBlocks = creationBlock === undefined ? undefined : { [network]: creationBlock };
    info = await createRailgunWallet(encryptionKey, mnemonic, creationBlocks, 0);
  }
  wallet = { walletId: info.id, encryptionKey, address: info.railgunAddress };
  return { address: info.railgunAddress };
}

/**
 * Deletes the wallet `mnemonic` derives at index 0, as `openWallet` would find it, from `network`'s database: its
 * encrypted keys, and the notes syncs decrypted for it, which the engine keeps unencrypted. Only the database opens,
 * with no provider and no screening nodes, so nothing leaves the page. The host loads a fresh page to delete and
 * closes it after; a page that deletes is never started, and one that started never deletes. Deleting a wallet that
 * isn't stored does nothing.
 */
export async function deleteWallet({ network: name, mnemonic }) {
  const networkName = NETWORKS[name];
  if (networkName === undefined) throw badRequest(`unknown network ${name}`);
  if (typeof mnemonic !== 'string' || mnemonic === '') throw badRequest('no mnemonic');
  // A start that failed may have left its engine, over its own network's database.
  if (starting !== undefined || (deleting === undefined && hasEngine())) {
    throw badRequest('wallets are deleted on a page of their own');
  }
  if (deleting === undefined) {
    const database = new LevelJS(`railgun-${name}`);
    deleting = { networkName, promise: startRailgunEngine(WALLET_SOURCE, database, false, artifactStore, false, false) };
  } else if (deleting.networkName !== networkName) {
    throw badRequest(`the engine runs ${deleting.networkName}`);
  }
  await deleting.promise;
  const id = RailgunWallet.generateID(mnemonic, 0);
  await deleteWalletByID(id);
  const { db } = getEngine();
  for (const namespace of walletNamespaces(id, NETWORK_CONFIG[networkName].chain)) {
    await db.clearNamespace(namespace);
  }
  return null;
}

/**
 * Scans to the chain's tip, catches up on txids, then has the screening nodes check the notes. Returns the balances,
 * the private sends received (`received`), and `screening`: `failed` when that check, or the proofs the engine last
 * sent for this wallet's sends, failed.
 */
export async function refresh(_params, emit) {
  const { walletId } = session();
  txidHold.begin();
  let reporting;
  try {
    reporting = await reportTxids();
    const before = await latestTxidIndex();
    await scanNotes(walletId);
    const tree = getEngine().getTXIDMerkletree(TXID_VERSION, chain());
    await catchUpTxids({
      before,
      latest: latestTxidIndex,
      sync: () => syncRailgunTransactionsV2(network),
      isScanning: () => tree.isScanning,
      wait: () => new Promise((resolve) => setTimeout(resolve, TXID_SYNC_WAIT_MS)),
      passes: TXID_SYNC_PASSES,
    });
  } finally {
    reporting?.stop();
    const complete = txidHold.end();
    if (complete !== undefined) emit('scan', complete);
  }
  let checkFailed = false;
  try {
    await refreshReceivePOIsForWallet(TXID_VERSION, network, walletId);
    // Only starts the engine's own screening: how its proofs went comes through the callback, by a later refresh.
    await generatePOIsForWallet(network, walletId);
  } catch (error) {
    checkFailed = true;
    // The balances stand; their screening statuses catch up on a later sync.
    emit('log', `screening not refreshed: ${error?.message ?? error}`);
  }
  return {
    balances: await balances(),
    received: await received(emit),
    screening: checkFailed || proofsFailed ? 'failed' : 'ok',
  };
}

const latestTxidIndex = async () => (await getLatestRailgunTxidData(TXID_VERSION, network)).txidIndex;

/**
 * Reports how far a long txid catch-up has come, from the txids the screening nodes have validated (which bound it)
 * and the ones stored, until `stop`. A short one, or one whose bound can't be read, isn't reported.
 */
async function reportTxids() {
  const start = await latestTxidIndex();
  let target;
  try {
    target = await getEngine().getLatestValidatedTxidIndex(TXID_VERSION, chain());
  } catch {
    // The catch-up runs as before; it just goes unreported.
  }
  if (target === undefined || target - start < TXID_REPORT_GAP) return { stop() {} };
  const report = async () => {
    try {
      activity?.txids(Math.min(1, Math.max(0, ((await latestTxidIndex()) - start) / (target - start))));
    } catch {
      // The next read reports it.
    }
  };
  await report();
  const timer = setInterval(report, TXID_REPORT_MS);
  return {
    stop() {
      clearInterval(timer);
      activity?.txids(null);
    },
  };
}

/** One notes scan at a time, so each can tell whether the engine ran it. */
function scanNotes(walletId) {
  const scan = notesScans.then(() => scanNotesNow(walletId));
  notesScans = scan.catch(() => {});
  return scan;
}

// The engine skips a notes scan while another runs or before the network loads, so try until one starts.
async function scanNotesNow(walletId) {
  for (let attempt = 0; attempt < NOTES_SCAN_ATTEMPTS; attempt += 1) {
    const scan = { started: false, incomplete: false };
    notesScan = scan;
    try {
      await refreshBalances(chain(), [walletId]);
    } finally {
      notesScan = undefined;
    }
    if (scan.incomplete) throw new Error('the notes scan broke off, so the balances may be stale');
    if (scan.started) return;
    await new Promise((resolve) => setTimeout(resolve, NOTES_SCAN_RETRY_MS));
  }
  throw new Error('no notes scan started for a minute: one may be stuck');
}

/**
 * The private sends this wallet received (`receivedSends`), from the notes its scans already decrypted. Only where
 * the engine has no time for one is the newest block read, to date it from. `null` when the history can't be read:
 * the balances stand without it.
 */
async function received(emit) {
  try {
    const history = await getWalletTransactionHistory(chain(), session().walletId, undefined);
    return receivedSends(history, hasUndatedReceipts(history) ? await newestBlock(emit) : undefined);
  } catch (error) {
    emit('log', `received sends not read: ${error?.message ?? error}`);
    return null;
  }
}

/** The newest block's number and time; undefined when it can't be read, and the sends it would date go undated. */
async function newestBlock(emit) {
  try {
    const block = await getFallbackProviderForNetwork(network).getBlock('latest');
    return block ? { blockNumber: block.number, timestamp: block.timestamp } : undefined;
  } catch (error) {
    emit('log', `newest block not read: ${error?.message ?? error}`);
    return undefined;
  }
}

/** Balances by screening status: `Spendable`, `ShieldPending`, `ShieldBlocked`, … */
async function balances() {
  const byBucket = await walletForID(session().walletId).getTokenBalancesByBucket(TXID_VERSION, chain());
  return Object.fromEntries(
    Object.entries(byBucket).map(([bucket, tokens]) => [
      bucket,
      getSerializedERC20Balances(tokens).map(({ tokenAddress, amount }) => ({ token: tokenAddress, amount: amount.toString() })),
    ]),
  );
}
