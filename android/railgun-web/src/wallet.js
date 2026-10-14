import { RailgunWallet } from '@railgun-community/engine';
import { MerkletreeScanStatus, NETWORK_CONFIG, NetworkName, TXIDVersion } from '@railgun-community/shared-models';
import {
  createRailgunWallet,
  generatePOIsForWallet,
  getProver,
  getSerializedERC20Balances,
  loadProvider,
  loadWalletByID,
  refreshBalances,
  refreshReceivePOIsForWallet,
  setLoggers,
  setOnTXIDMerkletreeScanCallback,
  setOnUTXOMerkletreeScanCallback,
  startRailgunEngine,
  walletForID,
} from '@railgun-community/wallet';
import LevelJS from 'level-js';
import { groth16 } from 'snarkjs';
import { artifactStore } from './artifacts.js';
import { badRequest } from './errors.js';

export const TXID_VERSION = TXIDVersion.V2_PoseidonMerkle;
const NETWORKS = { sepolia: NetworkName.EthereumSepolia, mainnet: NetworkName.Ethereum };
const WALLET_SOURCE = 'zapp';
// The engine's listener catches spends a scan misses, as it reads nullifiers from the latest commitment's block on.
const POLLING_INTERVAL_MS = 15_000;
const NOTES_SCAN_ATTEMPTS = 20;
const NOTES_SCAN_RETRY_MS = 3_000;
// A notes scan reports 3% as it starts, 1% on a full rescan; one the engine skips reports nothing.
const NOTES_SCAN_START = 0.03;

let starting;
let network;
let fees;
let wallet;
let debug = false;
let notesScan;
let notesScans = Promise.resolve();

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
  await startRailgunEngine(WALLET_SOURCE, new LevelJS(database), debug, artifactStore, false, false, poiNodeUrls);
  getProver().setSnarkJSGroth16(groth16);
  setOnUTXOMerkletreeScanCallback(({ scanStatus, progress }) => {
    if (notesScan !== undefined) {
      if (scanStatus === MerkletreeScanStatus.Updated && progress <= NOTES_SCAN_START) notesScan.started = true;
      if (scanStatus === MerkletreeScanStatus.Incomplete) notesScan.incomplete = true;
    }
    emit('scan', { tree: 'utxo', status: scanStatus, progress });
  });
  setOnTXIDMerkletreeScanCallback(({ scanStatus, progress }) => emit('scan', { tree: 'txid', status: scanStatus, progress }));
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

/** Scans to the chain's tip, then has the screening nodes check the notes, and returns balances. */
export async function refresh(_params, emit) {
  const { walletId } = session();
  await scanNotes(walletId);
  try {
    await refreshReceivePOIsForWallet(TXID_VERSION, network, walletId);
    await generatePOIsForWallet(network, walletId);
  } catch (error) {
    // The balances stand; their screening statuses catch up on a later sync.
    emit('log', `screening not refreshed: ${error?.message ?? error}`);
  }
  return balances();
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
