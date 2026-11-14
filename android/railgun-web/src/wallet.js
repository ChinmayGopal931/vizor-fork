import { RailgunWallet, getEngineTxidSyncBatchSize, setEngineTxidSyncBatchSize } from '@railgun-community/engine';
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
  getEngine,
  getFallbackProviderForNetwork,
  getLatestRailgunTxidData,
  getProver,
  getSerializedERC20Balances,
  getWalletTransactionHistory,
  hasEngine,
  loadProvider,
  loadWalletByID,
  refreshReceivePOIsForWallet,
  refreshSpentPOIsForWallet,
  setBatchListCallback,
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
import { archive } from './archive.js';
import { ARCHIVES, installArchiveSync } from './archive-sync.js';
import { installArchiveTxids } from './archive-txids.js';
import { setArtifactProgressListener } from './artifact-mirror.js';
import { artifactStore } from './artifacts.js';
import { mainnetBlockTime } from './block-times.js';
import { badRequest } from './errors.js';
import { installQuickSync } from './quick-sync.js';
import { hasUndatedReceipts, hasUndatedShields, pendingShields, receivedSends } from './received.js';
import { refreshProgress } from './refresh-progress.js';
import { syncFailure } from './rpc-probe.js';
import { screeningActivity } from './screening-activity.js';
import { squidQueries } from './squid.js';
import { syncFinisher } from './sync-finish.js';
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
// A batch from Anon's archive is in within seconds, so a page cut off loses little of a larger one, and each batch
// costs a root check at the screening node.
const ARCHIVE_TXID_SYNC_BATCH_SIZE = 5_000;
// The engine reads on only while the subgraph's answer is one batch long, so each of its txid syncs now reads one
// answer of 10,000; a refresh syncs again until one adds nothing. Ethereum's whole history is about 15 answers.
const TXID_SYNC_PASSES = 50;
const TXID_SYNC_WAIT_MS = 1_000;
// A txid sync that adds nothing short of the screening nodes' validated index is tried again this many times, 5 s
// longer apart each time: a connection that drops for a moment makes the engine drop a batch.
const TXID_SYNC_RETRIES = 3;
const TXID_SYNC_RETRY_MS = 5_000;
// Only a long catch-up is reported, so a refresh that finds a few new txids doesn't flash the row; it is read this often.
const TXID_REPORT_GAP = 1_000;
const TXID_REPORT_MS = 2_000;
// How long the rest of a sync waits for a screening refresh the engine runs by itself, and how often it looks.
const POI_REFRESH_WAIT_MS = 10 * 60_000;
const POI_REFRESH_POLL_MS = 1_000;

let starting;
// The engine a page opened to delete wallets: its database alone, with no provider. Such a page is never started.
let deleting;
let network;
let fees;
let wallet;
// What the engine was started on, for telling an RPC failure from the connection's.
let providerUrls;
let screeningUrls;
let debug = false;
let notesScan;
let notesScans = Promise.resolve();
// The notes scan's progress as reported. The quick sync reports its own through the engine's scan updates, and the
// engine's milestones after it are lower, so within a scan it never goes back.
let notesProgress = 0;
// Whether the proofs the open wallet's sends need failed when the engine last sent them. The engine screens by itself
// after every scan, outside any call, and reports how that went only through its callback.
let proofsFailed = false;
const txidHold = txidCompleteHold();
let activity;
let syncProgress;

const chain = () => NETWORK_CONFIG[network].chain;

/** The open wallet, for the calls that spend from it. */
export function session() {
  if (wallet === undefined) throw badRequest('no wallet is open');
  return { network, fees, ...wallet };
}

/** Whether the engine was started for debugging, which answers the debug-only calls too. */
export const isDebug = () => debug;

/**
 * Starts the engine once; a start that failed may run again. With `archive`, a network with an archive (`ARCHIVES`)
 * reads Railgun's history from it before rail-squid. Only the Android host fetches the archive for the page, which
 * can't read it itself (it sends no CORS headers).
 */
export function start({ network: name, rpcUrls, poiNodeUrls, archive: useArchive = false, debug: debugging = false }, emit) {
  const networkName = NETWORKS[name];
  if (networkName === undefined) throw badRequest(`unknown network ${name}`);
  if (!rpcUrls?.length) throw badRequest('no RPC URLs');
  if (deleting !== undefined) throw badRequest('this page deletes wallets');
  if (starting === undefined) {
    debug = debugging === true;
    const onAndroid = globalThis.webkit?.messageHandlers?.railgunHost === undefined;
    const history = useArchive === true && onAndroid ? ARCHIVES[name] : undefined;
    const promise = startEngine(networkName, `railgun-${name}`, rpcUrls, poiNodeUrls, history, debug, emit);
    starting = { networkName, promise };
    promise.catch(() => {
      if (starting?.promise === promise) starting = undefined;
    });
  } else if (starting.networkName !== networkName) {
    throw badRequest(`the engine runs ${starting.networkName}`);
  }
  return starting.promise;
}

async function startEngine(networkName, database, rpcUrls, poiNodeUrls, history, debug, emit) {
  if (debug) setLoggers((message) => emit('log', String(message)), (error) => emit('log', String(error?.stack ?? error)));
  setEngineTxidSyncBatchSize(history === undefined ? TXID_SYNC_BATCH_SIZE : ARCHIVE_TXID_SYNC_BATCH_SIZE);
  await startRailgunEngine(WALLET_SOURCE, new LevelJS(database), debug, artifactStore, false, false, poiNodeUrls);
  getProver().setSnarkJSGroth16(groth16);
  const engine = getEngine();
  const queries = squidQueries(networkName);
  installQuickSync(engine, { queries, head: () => getFallbackProviderForNetwork(networkName).getBlockNumber() });
  if (history !== undefined) {
    const reader = archive(history.base, history.chainId);
    const head = async () => {
      const block = await getFallbackProviderForNetwork(networkName).getBlock('latest');
      return { blockNumber: block.number, timestamp: block.timestamp };
    };
    const log = (line) => emit('log', line);
    installArchiveSync(engine, { reader, queries, chainId: history.chainId, time: mainnetBlockTime, head, log });
    installArchiveTxids(engine, {
      reader,
      txidVersion: TXID_VERSION,
      chain: NETWORK_CONFIG[networkName].chain,
      batchSize: getEngineTxidSyncBatchSize,
      time: mainnetBlockTime,
      head,
      log,
    });
  }
  setOnUTXOMerkletreeScanCallback(({ scanStatus, progress: reported }) => {
    if (scanStatus === MerkletreeScanStatus.Updated) {
      notesProgress = reported <= NOTES_SCAN_START ? reported : Math.max(notesProgress, reported);
    }
    const progress = scanStatus === MerkletreeScanStatus.Updated ? notesProgress : reported;
    if (notesScan !== undefined) {
      if (scanStatus === MerkletreeScanStatus.Updated && progress <= NOTES_SCAN_START) notesScan.started = true;
      if (scanStatus === MerkletreeScanStatus.Incomplete) notesScan.incomplete = true;
    }
    // The notes scan goes on to its own txid sync, which the catch-up's share already counts.
    if (scanStatus === MerkletreeScanStatus.Complete) syncProgress?.done('notes');
    else syncProgress?.update('notes', progress);
    emit('scan', { tree: 'utxo', status: scanStatus, progress });
  });
  setOnTXIDMerkletreeScanCallback(({ scanStatus, progress }) => {
    const event = { tree: 'txid', status: scanStatus, progress };
    if (txidHold.pass(event)) emit('scan', event);
  });
  activity = screeningActivity((state) => emit('screening', state));
  syncProgress = refreshProgress((progress) => emit('refresh', { progress }));
  setArtifactProgressListener((url, loaded, total) => activity.download(url, loaded, total));
  // The screening nodes' check of the notes not yet cleared, a batch at a time, whoever started it.
  setBatchListCallback(({ current, total }) => {
    activity.checks(current, total);
    if (total > 0) syncProgress.update('checks', current / total);
  });
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
  providerUrls = rpcUrls;
  screeningUrls = poiNodeUrls;
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
 * Scans to the chain's tip and has the screening nodes check the notes. Returns the balances, the private sends
 * received (`received`), the shields screening still holds (`shielding`), `screening`: `failed` when that check, or the
 * proofs the engine last sent for this wallet's sends, failed, and `syncing`: whether the rest of the sync, which runs
 * on in the page, is long enough to tell the user about. How far the refresh has come goes out meanwhile as `refresh`
 * events (`refresh-progress.js`). A sync that fails while the RPC does not answer, or turns requests away, fails as
 * `RPC_FAILED` (`rpc-probe.js`), so the host can offer another RPC.
 *
 * The rest of the sync is Railgun's transaction list, then the proofs this wallet's sends need (`sync-finish.js`); a
 * send's change waits on them, and nothing else does. It ends with a `synced` event: the state the refresh returns,
 * read again.
 */
export async function refresh(_params, emit) {
  const { walletId } = session();
  syncProgress.begin();
  try {
    return await refreshWallet(walletId, emit);
  } finally {
    syncProgress.end();
  }
}

async function refreshWallet(walletId, emit) {
  try {
    syncProgress.step('notes');
    await scanNotes(walletId);
  } catch (error) {
    throw await syncFailure(error, { rpcUrls: providerUrls, poiNodeUrls: screeningUrls });
  }
  syncProgress.step('checks');
  let checkFailed = false;
  try {
    await refreshReceivePOIsForWallet(TXID_VERSION, network, walletId);
  } catch (error) {
    checkFailed = true;
    // The balances stand; their screening statuses catch up on a later sync.
    emit('log', `screening not refreshed: ${error?.message ?? error}`);
  }
  syncProgress.step('finishing');
  const state = await walletState(emit, checkFailed);
  const syncing = await finisher(walletId, emit).start(checkFailed);
  return { ...state, syncing };
}

/** The balances and history a refresh returns, `failed` when its screening did. */
async function walletState(emit, failed) {
  const amounts = await balances();
  const history = await walletHistory(emit);
  return {
    balances: amounts,
    received: history?.received ?? null,
    shielding: history?.shielding ?? null,
    screening: failed || proofsFailed ? 'failed' : 'ok',
  };
}

const latestTxidIndex = async () => (await getLatestRailgunTxidData(TXID_VERSION, network)).txidIndex;

// The open wallet's: one per page, as the wallet is.
let finishing;
function finisher(walletId, emit) {
  finishing ??= syncFinisher({
    behind: async () => (await txidsBehind()) >= TXID_REPORT_GAP,
    catchUp: () => catchUpTxidList(emit),
    prove: () => proveSends(walletId),
    state: (failed) => walletState(emit, failed),
    emit,
    log: (line) => emit('log', line),
  });
  return finishing;
}

/** How far the stored txid list is behind the one the screening nodes have validated; 0 when that can't be read. */
async function txidsBehind() {
  const target = await getEngine().getLatestValidatedTxidIndex(TXID_VERSION, chain());
  return target === undefined ? 0 : target - (await latestTxidIndex());
}

/** Syncs Railgun's transaction list until a sync adds nothing, the way a notes scan used to finish. */
async function catchUpTxidList(emit) {
  txidHold.begin();
  let reporting;
  try {
    reporting = await reportTxids();
    const before = await latestTxidIndex();
    await getEngine().scanTXIDHistoryV2(chain());
    const tree = getEngine().getTXIDMerkletree(TXID_VERSION, chain());
    await catchUpTxids({
      before,
      latest: latestTxidIndex,
      sync: () => syncRailgunTransactionsV2(network),
      isScanning: () => tree.isScanning,
      wait: () => delay(TXID_SYNC_WAIT_MS),
      passes: TXID_SYNC_PASSES,
      target: () => getEngine().getLatestValidatedTxidIndex(TXID_VERSION, chain()),
      retries: TXID_SYNC_RETRIES,
      retryWait: (attempt) => delay(TXID_SYNC_RETRY_MS * attempt),
    });
  } finally {
    reporting?.stop();
    const complete = txidHold.end();
    if (complete !== undefined) emit('scan', complete);
  }
}

/**
 * Reports how far the txid catch-up has come to the Processing row, from the txids the screening nodes have validated
 * (which bound it) and the ones stored, until `stop`: only a long one, so a few new txids don't flash the row. One
 * whose bound can't be read isn't reported.
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
      const done = ((await latestTxidIndex()) - start) / (target - start);
      activity?.txids(Math.min(1, Math.max(0, done)));
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

/**
 * Has the wallet prove its own sends and waits until it has. The engine refreshes a wallet's screening by itself after
 * every scan, outside any call, and a refresh asked for while one runs does nothing; so this waits for one running to
 * end, runs its own, then reads back what the screening nodes made of the proofs.
 */
async function proveSends(walletId) {
  const railgunWallet = walletForID(walletId);
  const busy = () => railgunWallet.isRefreshingPOIs.get(TXID_VERSION, chain()) === true;
  for (let waited = 0; busy() && waited < POI_REFRESH_WAIT_MS; waited += POI_REFRESH_POLL_MS) {
    await delay(POI_REFRESH_POLL_MS);
  }
  await railgunWallet.refreshPOIsForTXIDVersion(chain(), TXID_VERSION, busy());
  await refreshSpentPOIsForWallet(TXID_VERSION, network, walletId);
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** One notes scan at a time, so each can tell whether the engine ran it. */
function scanNotes(walletId) {
  const scan = notesScans.then(() => scanNotesNow(walletId));
  notesScans = scan.catch(() => {});
  return scan;
}

// The engine skips a notes scan while another runs or before the network loads, so try until one starts. Only the
// notes: the txid list is the rest of the sync's.
async function scanNotesNow(walletId) {
  for (let attempt = 0; attempt < NOTES_SCAN_ATTEMPTS; attempt += 1) {
    const scan = { started: false, incomplete: false };
    notesScan = scan;
    try {
      await getEngine().scanUTXOHistory(TXID_VERSION, chain(), [walletId]);
    } finally {
      notesScan = undefined;
    }
    if (scan.incomplete) throw new Error('the notes scan broke off, so the balances may be stale');
    if (scan.started) return;
    await delay(NOTES_SCAN_RETRY_MS);
  }
  throw new Error('no notes scan started for a minute: one may be stuck');
}

/**
 * The private sends this wallet received (`receivedSends`) and the shields screening still holds (`pendingShields`),
 * from the notes its scans already decrypted. Only where the engine has no time for one is the newest block read, to
 * date it from. `null` when the history can't be read: the balances stand without it.
 */
async function walletHistory(emit) {
  try {
    const history = await getWalletTransactionHistory(chain(), session().walletId, undefined);
    const undated = hasUndatedReceipts(history) || hasUndatedShields(history);
    const head = undated ? await newestBlock(emit) : undefined;
    return { received: receivedSends(history, head), shielding: pendingShields(history, head) };
  } catch (error) {
    emit('log', `wallet history not read: ${error?.message ?? error}`);
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
