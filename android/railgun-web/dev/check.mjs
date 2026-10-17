// Drives the built bundle in headless Chrome through the same MessagePort protocol as the app.
//   npm run check                 syncs a fresh wallet on Sepolia, reopens it from IndexedDB, then deletes it
//   npm run check -- --transact   sends privately to itself through the relayer, which pays the gas, with
//                                 the wallet RAILGUN_DEV_MNEMONIC in local.properties names, which must hold
//                                 the relayer's token; Chrome keeps dev/.profile between runs
// Mnemonics and keys are never printed. RAILGUN_CHECK_RPC must be a host the page's CSP allows.
import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { JsonRpcProvider, Mnemonic } from 'ethers';
import puppeteer from 'puppeteer-core';

const require = createRequire(import.meta.url);
const ASSETS = path.resolve('../app/src/main/assets/railgun');
const PROFILE = path.resolve('dev/.profile');
const LOCAL_PROPERTIES = path.resolve('../local.properties');
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const RPC_URL = process.env.RAILGUN_CHECK_RPC ?? 'https://ethereum-sepolia-rpc.publicnode.com';
const POI_NODE = 'https://ppoi.fdi.network/';
const RELAYER_URL = process.env.RAILGUN_CHECK_RELAYER ?? 'https://zecswap-testnet.pepeman931.workers.dev/relayer';
const SEND_AMOUNT = 10_000n;
const SPENDABLE_POLL_MS = 30_000;
const SPENDABLE_TIMEOUT_MS = 30 * 60_000;
const CONFIRM_TIMEOUT_MS = 120_000;
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm' };

/** The address Railgun's engine derives in Node, to compare with the browser's. */
async function expectedAddress(mnemonic) {
  const dist = path.dirname(require.resolve('@railgun-community/engine'));
  const load = (module) => require(path.join(dist, module));
  const { deriveNodes, WalletNode } = load('key-derivation/wallet-node');
  const { encodeAddress } = load('key-derivation/bech32');
  const { initPoseidonPromise } = load('utils/poseidon');
  const { initCurve25519Promise } = load('utils/scalar-multiply');
  await Promise.all([initPoseidonPromise, initCurve25519Promise]);
  const nodes = deriveNodes(mnemonic, 0);
  const viewing = await nodes.viewing.getViewingKeyPair();
  const nullifyingKey = await nodes.viewing.getNullifyingKey();
  const masterPublicKey = WalletNode.getMasterPublicKey(nodes.spending.getSpendingKeyPair().pubkey, nullifyingKey);
  return encodeAddress({ masterPublicKey, viewingPublicKey: viewing.pubkey });
}

async function localProperties() {
  const text = await readFile(LOCAL_PROPERTIES, 'utf8');
  return Object.fromEntries(
    text
      .split('\n')
      .map((line) => line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/))
      .filter(Boolean)
      .map(([, key, value]) => [key, value]),
  );
}

function serve() {
  const server = createServer(async (req, res) => {
    const file = path.join(ASSETS, path.normalize(new URL(req.url, 'http://x').pathname));
    try {
      const body = await readFile(file);
      res.writeHead(200, { 'content-type': TYPES[path.extname(file)] ?? 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

/** Loads the page, hands it a port, and returns `call(method, params)` over it. */
async function connect(page, url, onEvent) {
  await page.goto(url);
  await page.evaluate(() => {
    const { port1, port2 } = new MessageChannel();
    const pending = new Map();
    let next = 0;
    port1.onmessage = ({ data }) => {
      const message = JSON.parse(data);
      if (message.event !== undefined) return window.hostEvent(data);
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error === undefined) resolve(message.result);
      else reject(new Error(`${message.error.code}: ${message.error.message}`));
    };
    window.call = (method, params) =>
      new Promise((resolve, reject) => {
        const id = next++;
        pending.set(id, { resolve, reject });
        port1.postMessage(JSON.stringify({ id, method, params }));
      });
    // As the app's postWebMessage does, with no source window.
    window.dispatchEvent(new MessageEvent('message', { data: 'vizor-railgun-init', ports: [port2] }));
  });
  return async (method, params) => {
    const started = performance.now();
    const result = await page.evaluate((m, p) => window.call(m, p), method, params);
    onEvent('timing', `${method} took ${((performance.now() - started) / 1000).toFixed(1)} s`);
    return result;
  };
}

/** Prints events once each; `notesScans` counts the notes scans that started, which report 3% first. */
function eventPrinter() {
  let last = '';
  const print = (event, data) => {
    if (event === 'scan' && data.tree === 'utxo' && data.status === 'Updated' && data.progress <= 0.03) {
      print.notesScans += 1;
    }
    let line;
    if (event === 'scan') line = `scan ${data.tree} ${data.status} ${Math.floor(data.progress * 10) * 10}%`;
    else if (event === 'proof') line = `proof ${Math.floor(data.progress * 10) * 10}% ${data.status}`;
    else if (event === 'log') line = process.env.RAILGUN_CHECK_VERBOSE ? `log ${data}` : undefined;
    else line = `${event}${data === null ? '' : ` ${typeof data === 'string' ? data : JSON.stringify(data)}`}`;
    if (line !== undefined && line !== last) console.log(`  ${line}`);
    last = line ?? last;
  };
  print.notesScans = 0;
  return print;
}

/** The page reaches only its own hosts, and names what it refuses. */
async function boundaryCheck(page, call) {
  const outside = await page.evaluate(() => fetch('https://example.com/').then(() => 'reached', () => 'blocked'));
  if (outside !== 'blocked') throw new Error('the page reached a host outside its CSP');
  const unknown = await call('nonsense', {}).then(() => 'answered', (error) => error.message);
  if (!unknown.startsWith('BAD_REQUEST')) throw new Error(`an unknown method came back as ${unknown}`);
  console.log('  other hosts are blocked, and an unknown method is a BAD_REQUEST');
}

async function syncCheck(page, url, onEvent) {
  const mnemonic = process.env.RAILGUN_CHECK_MNEMONIC ?? Mnemonic.fromEntropy(randomBytes(32)).phrase;
  const fromBlock = process.env.RAILGUN_CHECK_FROM_BLOCK
    ? Number(process.env.RAILGUN_CHECK_FROM_BLOCK)
    : await new JsonRpcProvider(RPC_URL).getBlockNumber();
  const encryptionKey = randomBytes(32).toString('hex');
  const expected = await expectedAddress(mnemonic);
  for (const pass of ['first open', 'reopen from IndexedDB']) {
    console.log(`${pass}:`);
    const call = await connect(page, url, onEvent);
    if (pass === 'first open') await boundaryCheck(page, call);
    await call('start', { network: 'sepolia', rpcUrls: [RPC_URL], poiNodeUrls: [POI_NODE], debug: true });
    const { address } = await call('openNewWallet', { encryptionKey, mnemonic, creationBlock: fromBlock });
    if (address !== expected) throw new Error(`the browser opened ${address}, Node derives ${expected}`);
    console.log(`  address matches Node's derivation: ${address.slice(0, 16)}…`);
    const balances = await call('refresh', {});
    console.log(`  balances ${JSON.stringify(balances)}`);
    // The engine skips a scan while another runs; each sync must still get one of its own.
    const before = onEvent.notesScans;
    await Promise.all([call('refresh', {}), call('refresh', {})]);
    const scans = onEvent.notesScans - before;
    if (scans < 2) throw new Error(`two syncs at once started ${scans} notes scan(s)`);
    console.log('  two syncs at once each started a notes scan');
  }
  await deleteCheck(page, url, onEvent, mnemonic);
}

/**
 * How many keys the engine stores for `mnemonic`'s wallet: its record `<wallet>:<id>`, and the notes under it. level-js
 * keeps the keys as bytes, so the range is too.
 */
async function walletKeys(page, mnemonic) {
  const { Database, RailgunWallet } = require('@railgun-community/engine');
  const record = Database.pathToKey(RailgunWallet.dbPath(RailgunWallet.generateID(mnemonic, 0)));
  return page.evaluate(
    (location, from) =>
      new Promise((resolve, reject) => {
        const request = indexedDB.open(`level-js-${location}`);
        request.onerror = () => reject(request.error);
        request.onsuccess = () => {
          const db = request.result;
          const bytes = (text) => new TextEncoder().encode(text);
          const range = IDBKeyRange.bound(bytes(from), bytes(`${from}~`));
          const count = db.transaction(location, 'readonly').objectStore(location).count(range);
          count.onsuccess = () => {
            db.close();
            resolve(count.result);
          };
          count.onerror = () => reject(count.error);
        };
      }),
    'railgun-sepolia',
    record,
  );
}

/** A fresh page deletes the synced wallet with no network, and then refuses to start. */
async function deleteCheck(page, url, onEvent, mnemonic) {
  console.log('delete:');
  const stored = await walletKeys(page, mnemonic);
  if (stored === 0) throw new Error('the synced wallet left nothing in IndexedDB');
  const call = await connect(page, url, onEvent);
  await call('deleteWallet', { network: 'sepolia', mnemonic });
  const left = await walletKeys(page, mnemonic);
  if (left !== 0) throw new Error(`deleting the wallet left ${left} of its ${stored} keys`);
  await call('deleteWallet', { network: 'sepolia', mnemonic });
  const started = await call('start', { network: 'sepolia', rpcUrls: [RPC_URL], poiNodeUrls: [POI_NODE] }).then(
    () => 'started',
    (error) => error.message,
  );
  if (!started.startsWith('BAD_REQUEST')) throw new Error(`the page that deleted came back from start as ${started}`);
  console.log(`  deleteWallet removed all ${stored} of the wallet's keys, again harmlessly, and the page won't start`);
}

/** Posts what the page proved to the relayer, as the app does, and waits for its block from here. */
async function relay({ chainId, to, data, value }) {
  const response = await fetch(`${RELAYER_URL}/v1/railgun/transact`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ chainId, to, data, value }),
  });
  const answer = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`the relayer answered ${response.status}: ${answer.error ?? answer.code ?? ''}`);
  const [hash] = answer.transactions;
  const receipt = await new JsonRpcProvider(RPC_URL).waitForTransaction(hash, 2, CONFIRM_TIMEOUT_MS);
  if (receipt?.status !== 1) throw new Error(`${hash} is ${receipt === null ? 'pending' : 'reverted'}`);
  return hash;
}

const amountOf = (bucket, token) =>
  BigInt(bucket?.find((amount) => amount.token.toLowerCase() === token.toLowerCase())?.amount ?? 0);
const etherscan = (hash) => `https://sepolia.etherscan.io/tx/${hash}`;

async function waitForSpendable(call, token, amount) {
  const deadline = Date.now() + SPENDABLE_TIMEOUT_MS;
  for (;;) {
    const balances = await call('refresh', {});
    const held = Object.entries(balances)
      .filter(([bucket]) => bucket !== 'Spent')
      .reduce((sum, [, tokens]) => sum + amountOf(tokens, token), 0n);
    const spendable = amountOf(balances.Spendable, token);
    console.log(`  ${spendable} of ${held} spendable, ${amount} needed`);
    if (spendable >= amount) return;
    if (held < amount) throw new Error(`the dev wallet holds ${held} of ${token}, short of ${amount}`);
    if (Date.now() > deadline) throw new Error('nothing became spendable in time');
    await new Promise((resolve) => setTimeout(resolve, SPENDABLE_POLL_MS));
  }
}

/** Opens the dev wallet that local.properties names. */
async function openDevWallet(page, url, onEvent) {
  const { RAILGUN_DEV_MNEMONIC: mnemonic } = await localProperties();
  if (!mnemonic) throw new Error(`set RAILGUN_DEV_MNEMONIC in ${LOCAL_PROPERTIES}`);
  // Stable across runs, so the wallet stored in dev/.profile opens again.
  const encryptionKey = createHash('sha256').update(`railgun-check:${mnemonic}`).digest('hex');

  const call = await connect(page, url, onEvent);
  await call('start', { network: 'sepolia', rpcUrls: [RPC_URL], poiNodeUrls: [POI_NODE], debug: true });
  const { address } = await call('openWallet', { encryptionKey, mnemonic });
  console.log(`  wallet ${address.slice(0, 16)}…`);
  return { call, address };
}

async function transactCheck(page, url, onEvent) {
  const { call, address } = await openDevWallet(page, url, onEvent);
  const terms = await (await fetch(`${RELAYER_URL}/v1/terms`)).json();
  const sends = terms.railgunSends;
  if (!sends) throw new Error(`${RELAYER_URL} sends no Railgun transactions`);
  await waitForSpendable(call, sends.token, SEND_AMOUNT + BigInt(sends.fee));
  const broadcaster = {
    chainId: terms.chainId,
    railgunProxy: sends.railgunProxy,
    railgunAddress: sends.railgunAddress,
    token: sends.token,
    minFee: sends.fee,
    feePerUnitGas: sends.feePerUnitGas,
    maxGasPrice: sends.maxGasPriceWei,
  };
  const amount = SEND_AMOUNT.toString();
  const { fee } = await call('broadcasterFee', { to: address, token: sends.token, amount, broadcaster });
  console.log(`  the relayer asks a fee of ${fee}, at least ${sends.fee}`);
  const proved = await call('transfer', { to: address, token: sends.token, amount, fee, broadcaster });
  const notes = proved.spends.reduce((sum, { nullifiers }) => sum + nullifiers.length, 0);
  console.log(`  proved a private send to itself spending ${notes} note(s), proof ${proved.proofMs} ms`);
  console.log(`  the relayer sent it: ${etherscan(await relay(proved))}`);
}

async function main() {
  const transact = process.argv.includes('--transact');
  const server = await serve();
  const url = `http://127.0.0.1:${server.address().port}/index.html`;
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    protocolTimeout: 0,
    ...(transact ? { userDataDir: PROFILE } : {}),
  });
  try {
    const page = await browser.newPage();
    const onEvent = eventPrinter();
    page.on('pageerror', (error) => console.log(`  page error: ${error.message}`));
    page.on('console', (message) => message.type() === 'error' && console.log(`  console: ${message.text()}`));
    await page.exposeFunction('hostEvent', (json) => {
      const { event, data } = JSON.parse(json);
      onEvent(event, data);
    });
    await (transact ? transactCheck(page, url, onEvent) : syncCheck(page, url, onEvent));
  } finally {
    await browser.close();
    server.close();
  }
}

main().then(
  () => process.exit(0),
  (error) => {
    console.error(error);
    process.exit(1);
  },
);
