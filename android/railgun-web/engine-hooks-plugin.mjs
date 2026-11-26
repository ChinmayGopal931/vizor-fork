// Points a few of the Railgun engine's internals at the page's own code, where the engine has no setting for what the
// page needs. The engine is pinned (package.json), and each rewrite names the exact source it replaces: a build
// against any other engine fails here rather than silently running without the page's code.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

export const ENGINE_VERSION = '9.8.0';

const ENGINE_PACKAGE = fileURLToPath(new URL('node_modules/@railgun-community/engine/package.json', import.meta.url));
const UTXO_MERKLETREE = /@railgun-community[\\/]engine[\\/]dist[\\/]merkletree[\\/]utxo-merkletree\.js$/;
const MERKLETREE = /@railgun-community[\\/]engine[\\/]dist[\\/]merkletree[\\/]merkletree\.js$/;
const TXID_MERKLETREE = /@railgun-community[\\/]engine[\\/]dist[\\/]merkletree[\\/]txid-merkletree\.js$/;
const RAILGUN_ENGINE = /@railgun-community[\\/]engine[\\/]dist[\\/]railgun-engine\.js$/;
const ABSTRACT_WALLET = /@railgun-community[\\/]engine[\\/]dist[\\/]wallet[\\/]abstract-wallet\.js$/;
const KEYS_UTILS = /@railgun-community[\\/]engine[\\/]dist[\\/]utils[\\/]keys-utils\.js$/;
const KEYS_UTILS_LEGACY = /@railgun-community[\\/]engine[\\/]dist[\\/]utils[\\/]keys-utils-legacy\.js$/;
const pageModule = (file) => JSON.stringify(fileURLToPath(new URL(`src/${file}`, import.meta.url)));

// Each original must occur once; the replacement is taken as it is, `$` and all.
const replaceOnce = (source, original, replacement, what) => {
  if (source.split(original).length !== 2) {
    throw new Error(`the Railgun engine's ${what} changed: the page's rewrite of it no longer applies`);
  }
  return source.replace(original, () => replacement);
};

// utxo-merkletree.js: every new unshield event is looked up before it is stored (src/unshield-events.js).
const ADD_UNSHIELD_EVENTS = `    async addUnshieldEvents(unshields, replaceExisting = false) {
        let newUnshields = unshields;
        if (!replaceExisting) {
            newUnshields = (0, is_defined_1.removeUndefineds)(await Promise.all(unshields.map(async (unshield) => {
                const hasExisting = await this.hasExistingUnshieldEvent(unshield);
                if (!hasExisting) {
                    return unshield;
                }
                return undefined;
            })));
        }
        // Build write batch for nullifiers
        const writeBatch = newUnshields.map((unshield) => ({
            type: 'put',
            key: this.getUnshieldEventsDBPath(unshield.txid, unshield.eventLogIndex, unshield.railgunTxid).join(':'),
            value: unshield,
        }));
        // Write to DB
        return this.db.batch(writeBatch, 'json');
    }
`;

/** utxo-merkletree.js with `addUnshieldEvents` handing over to src/unshield-events.js. */
export function throughUnshieldWatermark(source) {
  return replaceOnce(
    source,
    ADD_UNSHIELD_EVENTS,
    `    addUnshieldEvents(unshields, replaceExisting = false) {
        return require(${pageModule('unshield-events.js')}).addUnshieldEvents(this, unshields, replaceExisting);
    }
`,
    'UTXOMerkletree.addUnshieldEvents',
  );
}

// merkletree.js: insertLeaves writes the leaves whose root it has checked (src/txid-updates.js).
const WRITE_LEAVES = `        // If new root is valid, write to DB.
        await this.writeTreeToDB(tree, hashWriteGroup, dataWriteGroup);
`;

/** merkletree.js with insertLeaves handing the leaves it is about to write to src/txid-updates.js first. */
export function throughAcceptedLeaves(source) {
  return replaceOnce(
    source,
    WRITE_LEAVES,
    `        // If new root is valid, write to DB.
        await require(${pageModule('txid-updates.js')}).leavesAccepted(this, dataWriteGroup);
        await this.writeTreeToDB(tree, hashWriteGroup, dataWriteGroup);
`,
    'Merkletree.insertLeaves',
  );
}

// txid-merkletree.js: the screening node refusing a root the txid list would take says so (src/txid-repair.js). A
// root check that fails with the connection throws before it, and isn't a refusal.
const TXID_ROOT_REFUSED = `    // eslint-disable-next-line class-methods-use-this
    invalidRootCallback() {
        // Unused for Txid merkletree
        return Promise.resolve();
    }
`;

/** txid-merkletree.js with the screening node's refusals reported to src/txid-repair.js. */
export function throughTxidRootRefusals(source) {
  return replaceOnce(
    source,
    TXID_ROOT_REFUSED,
    `    invalidRootCallback() {
        require(${pageModule('txid-repair.js')}).listStopped('root', undefined);
        return Promise.resolve();
    }
`,
    'TXIDMerkletree.invalidRootCallback',
  );
}

// railgun-engine.js: the V2 txid sync works out each transaction's railgunTxid (src/archive-txids.js).
const TXID_HASH = `            const railgunTransactionWithTxid = (0, railgun_txid_1.createRailgunTransactionWithHash)(railgunTransaction);
            if (railgunTransactionWithTxid.version !== formatted_types_1.RailgunTransactionVersion.V2) {
`;

/** railgun-engine.js with the V2 txid sync hashing archive transactions through src/archive-txids.js. */
export function throughArchiveTxids(source) {
  return replaceOnce(
    source,
    TXID_HASH,
    `            const railgunTransactionWithTxid = require(${pageModule('archive-txids.js')}).withHash(railgunTransaction, railgun_txid_1.createRailgunTransactionWithHash);
            if (railgunTransactionWithTxid.version !== formatted_types_1.RailgunTransactionVersion.V2) {
`,
    'RailgunEngine.handleNewRailgunTransactionsV2',
  );
}

// railgun-engine.js: the V2 txid sync writes each record on its own, before the root check (src/txid-updates.js).
const TXID_QUEUE = `        let toQueue = [];
`;
const TXID_FLUSH = `        const flushQueue = async () => {
            if (toQueue.length === 0)
                return;
            await txidMerkletree.queueRailgunTransactions(toQueue, latestValidatedTxidIndex);
            toQueue = [];
            await txidMerkletree.updateTreesFromWriteQueue();
        };
`;
const TXID_PRE_V2_UNSHIELD = `                    // eslint-disable-next-line no-await-in-loop
                    await utxoMerkletree.addUnshieldEvents([unshieldEvent]);
                    this.invalidateTXOsCacheAllWallets(chain);
`;
const TXID_UNSHIELD_UPDATE = `                            matchingUnshieldEvent.railgunTxid = railgunTxid;
                            // eslint-disable-next-line no-await-in-loop
                            await utxoMerkletree.updateUnshieldEvent(matchingUnshieldEvent);
                            this.invalidateTXOsCacheAllWallets(chain);
`;
const TXID_COMMITMENT_UPDATE = `                        commitment.railgunTxid = railgunTxid;
                        // eslint-disable-next-line no-await-in-loop
                        await utxoMerkletree.updateData(tree, position, commitment);
`;

/**
 * railgun-engine.js with the V2 txid sync holding its commitment and unshield updates in src/txid-updates.js, which
 * the txid tree writes with the transactions they belong to, once their root is accepted.
 */
export function throughBatchedTxidUpdates(source) {
  const what = 'RailgunEngine.handleNewRailgunTransactionsV2';
  const rewrites = [
    [
      TXID_QUEUE,
      `${TXID_QUEUE}        const txidUpdates = require(${pageModule('txid-updates.js')}).txidUpdates(utxoMerkletree, txidMerkletree, () => this.invalidateTXOsCacheAllWallets(chain));
`,
    ],
    [
      TXID_FLUSH,
      `        const flushQueue = async () => {
            if (toQueue.length === 0)
                return;
            await txidMerkletree.queueRailgunTransactions(toQueue, latestValidatedTxidIndex);
            toQueue = [];
            await txidMerkletree.updateTreesFromWriteQueue();
            txidUpdates.settle();
        };
`,
    ],
    [
      TXID_PRE_V2_UNSHIELD,
      `                    txidUpdates.added(unshieldEvent);
`,
    ],
    [
      TXID_UNSHIELD_UPDATE,
      `                            matchingUnshieldEvent.railgunTxid = railgunTxid;
                            txidUpdates.unshield(matchingUnshieldEvent);
`,
    ],
    [
      TXID_COMMITMENT_UPDATE,
      `                        commitment.railgunTxid = railgunTxid;
                        txidUpdates.commitment(tree, position, commitment);
`,
    ],
  ];
  return rewrites.reduce(
    (rewritten, [original, replacement]) => replaceOnce(rewritten, original, replacement, what),
    source,
  );
}

// railgun-engine.js: the V2 txid sync reads commitments and unshield events in batches (src/txid-reads.js).
const TXID_READS = `        const v2BlockNumber = railgun_smart_wallet_1.RailgunSmartWalletContract.getEngineV2StartBlockNumber(chain);
`;
const TXID_UNSHIELD_READ = `                    const unshieldEventsForTxid = await utxoMerkletree.getAllUnshieldEventsForTxid(txid);
`;
const TXID_COMMITMENT_READ = `                const commitment = await utxoMerkletree.getCommitmentSafe(tree, position);
`;

/** railgun-engine.js with the V2 txid sync reading its commitments and unshield events through src/txid-reads.js. */
export function throughBatchedTxidReads(source) {
  const rewrites = [
    [
      TXID_READS,
      `${TXID_READS}        const txidReads = require(${pageModule('txid-reads.js')}).txidReads(utxoMerkletree, railgunTransactions);
`,
    ],
    [
      TXID_UNSHIELD_READ,
      `                    const unshieldEventsForTxid = await txidReads.unshieldEvents(txid);
`,
    ],
    [
      TXID_COMMITMENT_READ,
      `                const commitment = await txidReads.commitment(tree, position);
`,
    ],
  ];
  return rewrites.reduce(
    (rewritten, [original, replacement]) =>
      replaceOnce(rewritten, original, replacement, 'RailgunEngine.handleNewRailgunTransactionsV2'),
    source,
  );
}

// railgun-engine.js: the V2 txid sync stopping at a transaction says why (src/txid-repair.js).
const TXID_MISSING_UNSHIELD = `                        missingAnyCommitments = true;
                    }
                }
            }
`;
const TXID_MISSING_COMMITMENT = `                else {
                    missingAnyCommitments = true;
`;
const TXID_BROKEN_CHAIN = `            if (expectedVerificationHash !== verificationHash) {
                debugger_1.default.error(`;

/**
 * railgun-engine.js with the V2 txid sync reporting each stop to src/txid-repair.js: an unshield or a commitment the
 * notes trees lack, or a transaction that breaks the verification hashes, and the transaction's block.
 */
export function throughTxidStops(source) {
  const stopped = (reason) => `require(${pageModule('txid-repair.js')}).listStopped('${reason}', blockNumber);`;
  const rewrites = [
    [
      TXID_MISSING_UNSHIELD,
      `                        missingAnyCommitments = true;
                        ${stopped('unshield')}
                    }
                }
            }
`,
    ],
    [
      TXID_MISSING_COMMITMENT,
      `                else {
                    missingAnyCommitments = true;
                    ${stopped('commitment')}
`,
    ],
    [
      TXID_BROKEN_CHAIN,
      `            if (expectedVerificationHash !== verificationHash) {
                ${stopped('verification')}
                debugger_1.default.error(`,
    ],
  ];
  return rewrites.reduce(
    (rewritten, [original, replacement]) =>
      replaceOnce(rewritten, original, replacement, 'RailgunEngine.handleNewRailgunTransactionsV2'),
    source,
  );
}

// railgun-engine.js: the root check at the end of a notes scan says which root it refused (src/tree-recovery.js).
const END_OF_SCAN_ROOT_CHECK = `                if (!isValid) {
                    throw new Error(\`Invalid merkleroot: \${root}. Tree: \${treeIndex}. Index: \${index}.\`);
                }
`;

/** railgun-engine.js with the end-of-scan root check reporting the root it refuses to src/tree-recovery.js. */
export function throughRootRefusals(source) {
  return replaceOnce(
    source,
    END_OF_SCAN_ROOT_CHECK,
    `                if (!isValid) {
                    throw require(${pageModule('tree-recovery.js')}).rootRefused(treeIndex, root, new Error(\`Invalid merkleroot: \${root}. Tree: \${treeIndex}. Index: \${index}.\`), index);
                }
`,
    'RailgunEngine.scanUTXOHistory',
  );
}

// railgun-engine.js: a notes scan ends complete only with its wallets' notes decrypted through every leaf
// (src/notes-decrypted.js).
const SCAN_DECRYPTED = `            }, true);
            this.emitUTXOMerkletreeScanUpdateEvent(txidVersion, chain, 0.97); // 97%
`;

/**
 * railgun-engine.js with a notes scan checking, once its balance decryption returns, that the decryption got through
 * every leaf (src/notes-decrypted.js). The engine's decryption logs whatever stops it and returns as if it had
 * finished; the check throws instead, into the scan's own handling of a scan that broke off.
 */
export function throughDecryptedNotes(source) {
  return replaceOnce(
    source,
    SCAN_DECRYPTED,
    `            }, true);
            await require(${pageModule('notes-decrypted.js')}).notesDecrypted(this, txidVersion, chain, walletIdFilter);
            this.emitUTXOMerkletreeScanUpdateEvent(txidVersion, chain, 0.97); // 97%
`,
    'RailgunEngine.scanUTXOHistory',
  );
}

// railgun-engine.js: a full rescan ends by resetting the V2 txid list, which src/tree-recovery.js does instead.
const RESCAN_TXID_RESET = `            if (txidVersion === poi_types_1.TXIDVersion.V2_PoseidonMerkle) {
                // Must reset txid merkletree which is mapped to UTXO commitments in V2.
                // eslint-disable-next-line no-await-in-loop
                await this.fullResetTXIDMerkletreesV2(chain);
            }
`;

/**
 * railgun-engine.js with a full rescan leaving the V2 txid list alone. The engine's reset refuses to run before the
 * page has synced the list, and otherwise syncs all of it there and then. The page's own rebuild runs the rescan's
 * steps itself, clearing the list first (src/tree-recovery.js); the SDK's rescan still calls this one.
 */
export function withoutRescanTxidReset(source) {
  return replaceOnce(source, RESCAN_TXID_RESET, '', 'RailgunEngine.fullRescanUTXOMerkletreesAndWallets');
}

// abstract-wallet.js: a notes scan has each batch's keys worked out ahead (src/note-keys.js).
const SCAN_LEAVES_KEY = `        const vpk = this.getViewingKeyPair().privateKey;
        const leafSyncPromises = [];
`;
const SCAN_LEAVES_WRITE = `        const writeBatch = (await Promise.all(leafSyncPromises)).flat();
`;

/** abstract-wallet.js with `scanLeaves` preparing each batch's keys in src/note-keys.js, and releasing them after. */
export function throughNoteKeyBatches(source) {
  const what = 'AbstractWallet.scanLeaves';
  const prepared = replaceOnce(
    source,
    SCAN_LEAVES_KEY,
    `        const vpk = this.getViewingKeyPair().privateKey;
        const preparedKeys = await require(${pageModule('note-keys.js')}).prepareKeys(vpk, leaves, AbstractWallet.getCommitmentType);
        const leafSyncPromises = [];
`,
    what,
  );
  return replaceOnce(
    prepared,
    SCAN_LEAVES_WRITE,
    `        let writeBatch;
        try {
            writeBatch = (await Promise.all(leafSyncPromises)).flat();
        }
        finally {
            preparedKeys.release();
        }
`,
    what,
  );
}

// abstract-wallet.js: a shield's note is kept only if it hashes to its leaf. A quick sync's source gives a shield's
// note (its key, token and amount) beside the leaf's hash, and the trees' root check vouches for the hash alone, so
// the engine kept whatever amount the source gave, on any leaf whose ciphertext the wallet could open. Engine 9.9.1
// checks it, as 9.8.0 already checks a transfer's note; these are its lines, and a build against it fails here, where
// this rewrite is to be dropped.
const noteKept = (addressedTo) => `                    noteReceive = await transact_note_1.TransactNote.deserialize(txidVersion, chain, serialized, viewingPrivateKey, this.tokenDataGetter);
                    serializedNoteReceive = serialized;
                }
                catch (err) {
                    // Expect error if leaf not addressed to ${addressedTo}.
                }
`;
const noteKeptIfItHashes = (addressedTo, what) => `                    noteReceive = await transact_note_1.TransactNote.deserialize(txidVersion, chain, serialized, viewingPrivateKey, this.tokenDataGetter);
                    // SECURITY: the preImage is served by the sync source, not proven by the hash.
                    if (!decryptedNoteMatchesCommitment(noteReceive)) {
                        debugger_1.default.log('Discarding ${what} note: preImage hash does not match commitment.');
                        noteReceive = undefined;
                    }
                    else {
                        serializedNoteReceive = serialized;
                    }
                }
                catch (err) {
                    // Expect error if leaf not addressed to ${addressedTo}.
                }
`;

/**
 * abstract-wallet.js with a shield's note, and a legacy shield's, kept only when it hashes to its leaf: engine 9.9.1's
 * check, in its own words.
 */
export function throughShieldHashChecks(source) {
  const what = 'AbstractWallet.createScannedDBCommitments';
  const shields = replaceOnce(source, noteKept('this wallet'), noteKeptIfItHashes('this wallet', 'shield'), what);
  return replaceOnce(shields, noteKept('us'), noteKeptIfItHashes('us', 'legacy shield'), what);
}

// abstract-wallet.js: a wallet that loads holds the shield notes it kept before that check to their leaves, once
// (src/kept-notes.js).
const WALLET_TREES_LOADED = `        this.utxoMerkletrees.set(txidVersion, utxoMerkletree.chain, utxoMerkletree);
    }
`;

/**
 * abstract-wallet.js with `loadUTXOMerkletree` handing the wallet to src/kept-notes.js before it takes its trees: where
 * the engine migrates a wallet's notes itself, with nothing of the engine's reading or writing them yet.
 */
export function throughKeptNotes(source) {
  return replaceOnce(
    source,
    WALLET_TREES_LOADED,
    `        await require(${pageModule('kept-notes.js')}).holdShieldNotesToLeaves(this, utxoMerkletree, txidVersion);
        this.utxoMerkletrees.set(txidVersion, utxoMerkletree.chain, utxoMerkletree);
    }
`,
    'AbstractWallet.loadUTXOMerkletree',
  );
}

// abstract-wallet.js: what stops a wallet's balance decryption is reported (src/notes-decrypted.js).
const DECRYPTION_STOPPED = `            // Reset decryptBalancesKeyForChain
            this.decryptBalancesKeyForChain.del(null, chain);
            if (err instanceof Error) {
`;

/**
 * abstract-wallet.js with `decryptBalances` handing whatever stopped it to src/notes-decrypted.js, beside logging it
 * and returning as if it had finished: the scan's check of how far the decryption came then says why it fell short.
 */
export function throughDecryptionStops(source) {
  return replaceOnce(
    source,
    DECRYPTION_STOPPED,
    `            // Reset decryptBalancesKeyForChain
            this.decryptBalancesKeyForChain.del(null, chain);
            require(${pageModule('notes-decrypted.js')}).decryptionStopped(this.id, err);
            if (err instanceof Error) {
`,
    'AbstractWallet.decryptBalances',
  );
}

/** abstract-wallet.js as the build has it. */
export const throughAbstractWalletHooks = (source) =>
  throughDecryptionStops(throughKeptNotes(throughShieldHashChecks(throughNoteKeyBatches(source))));

// keys-utils.js and keys-utils-legacy.js: a key a scan prepared is taken as it is (src/note-keys.js).
const SHARED_KEY = `async function getSharedSymmetricKey(privateKeyPairA, blindedPublicKeyPairB) {
    try {
`;
const LEGACY_SHARED_KEY = `async function getSharedSymmetricKeyLegacy(privateKeyPairA, blindedPublicKeyPairB) {
    try {
`;
const takePrepared = (name, lookup) => `async function ${name}(privateKeyPairA, blindedPublicKeyPairB) {
    const prepared = require(${pageModule('note-keys.js')}).${lookup}(privateKeyPairA, blindedPublicKeyPairB);
    if (prepared !== undefined) {
        return prepared;
    }
    try {
`;

/** keys-utils.js with `getSharedSymmetricKey` answering a key src/note-keys.js prepared, if it did. */
export const throughPreparedKeys = (source) =>
  replaceOnce(source, SHARED_KEY, takePrepared('getSharedSymmetricKey', 'preparedKey'), 'getSharedSymmetricKey');

/** keys-utils-legacy.js with `getSharedSymmetricKeyLegacy` answering a key src/note-keys.js prepared, if it did. */
export const throughPreparedLegacyKeys = (source) =>
  replaceOnce(
    source,
    LEGACY_SHARED_KEY,
    takePrepared('getSharedSymmetricKeyLegacy', 'preparedLegacyKey'),
    'getSharedSymmetricKeyLegacy',
  );

/** railgun-engine.js as the build has it. */
export const throughRailgunEngineHooks = (source) =>
  withoutRescanTxidReset(
    throughDecryptedNotes(
      throughRootRefusals(
        throughTxidStops(throughBatchedTxidReads(throughBatchedTxidUpdates(throughArchiveTxids(source)))),
      ),
    ),
  );

/** Throws unless the installed engine is the one the rewrites were written against. */
export function checkEngineVersion(version) {
  if (version !== ENGINE_VERSION) {
    throw new Error(`the page's engine rewrites are for @railgun-community/engine ${ENGINE_VERSION}, not ${version}`);
  }
}

export const engineHooks = {
  name: 'engine-hooks',
  setup(build) {
    const rewritten = new Set();
    build.onStart(async () => {
      checkEngineVersion(JSON.parse(await readFile(ENGINE_PACKAGE, 'utf8')).version);
    });
    const rewrite = (filter, name, through) =>
      build.onLoad({ filter }, async (args) => {
        const contents = through(await readFile(args.path, 'utf8'));
        rewritten.add(name);
        return { contents, loader: 'js' };
      });
    rewrite(UTXO_MERKLETREE, 'utxo-merkletree', throughUnshieldWatermark);
    rewrite(MERKLETREE, 'merkletree', throughAcceptedLeaves);
    rewrite(TXID_MERKLETREE, 'txid-merkletree', throughTxidRootRefusals);
    rewrite(RAILGUN_ENGINE, 'railgun-engine', throughRailgunEngineHooks);
    rewrite(ABSTRACT_WALLET, 'abstract-wallet', throughAbstractWalletHooks);
    rewrite(KEYS_UTILS, 'keys-utils', throughPreparedKeys);
    rewrite(KEYS_UTILS_LEGACY, 'keys-utils-legacy', throughPreparedLegacyKeys);
    // A bundle with an engine module this didn't reach would run the engine's own code.
    build.onEnd(() =>
      rewritten.size === 7
        ? undefined
        : { errors: [{ text: 'the engine modules were not all bundled through the page' }] },
    );
  },
};
