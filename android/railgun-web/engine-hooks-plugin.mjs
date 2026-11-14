// Points a few of the Railgun engine's internals at the page's own code, where the engine has no setting for what the
// page needs. The engine is pinned (package.json), and each rewrite names the exact source it replaces: a build
// against any other engine fails here rather than silently running without the page's code.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

export const ENGINE_VERSION = '9.8.0';

const ENGINE_PACKAGE = fileURLToPath(new URL('node_modules/@railgun-community/engine/package.json', import.meta.url));
const UTXO_MERKLETREE = /@railgun-community[\\/]engine[\\/]dist[\\/]merkletree[\\/]utxo-merkletree\.js$/;
const pageModule = (file) => JSON.stringify(fileURLToPath(new URL(`src/${file}`, import.meta.url)));

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

const replaceOnce = (source, original, replacement, what) => {
  if (source.split(original).length !== 2) {
    throw new Error(`the Railgun engine's ${what} changed: the page's rewrite of it no longer applies`);
  }
  return source.replace(original, () => replacement);
};

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
    build.onLoad({ filter: UTXO_MERKLETREE }, async (args) => {
      const contents = throughUnshieldWatermark(await readFile(args.path, 'utf8'));
      rewritten.add('utxo-merkletree');
      return { contents, loader: 'js' };
    });
    // A bundle with an engine module this didn't reach would run the engine's own code.
    build.onEnd(() =>
      rewritten.size === 1 ? undefined : { errors: [{ text: 'the engine modules were not all bundled through the page' }] },
    );
  },
};
