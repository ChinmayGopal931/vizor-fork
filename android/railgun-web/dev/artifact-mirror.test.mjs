import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { test } from 'node:test';
import vm from 'node:vm';
import { brotliCompressSync } from 'node:zlib';
import { ArtifactName } from '@railgun-community/shared-models';
import { throughMirror } from '../artifact-mirror-plugin.mjs';
import { ARTIFACT_MIRROR, GATEWAY_STALL_MS, IPFS_GATEWAY, artifactGet } from '../src/artifact-mirror.js';

const require = createRequire(import.meta.url);
// The SDK's artifact modules, which its package doesn't export.
const ARTIFACTS = path.join(path.dirname(require.resolve('@railgun-community/wallet')), 'services/artifacts');
const DOWNLOADER = path.join(ARTIFACTS, 'artifact-downloader.js');
const { getArtifactUrl } = require(path.join(ARTIFACTS, 'artifact-util.js'));

const VKEY = getArtifactUrl(ArtifactName.VKEY, '01x01');
const ZKEY = getArtifactUrl(ArtifactName.ZKEY, '01x01');
const TEXT = { method: 'GET', responseType: 'text' };
const fromMirror = (url) => url.startsWith(`${ARTIFACT_MIRROR}/`);
const mirrored = (url) => `${ARTIFACT_MIRROR}${url.slice(IPFS_GATEWAY.length)}`;
const httpError = (status) =>
  Object.assign(new Error(`Request failed with status code ${status}`), { response: { status } });

/** An axios whose `get` answers with `reply(url, config)` (an Error rejects), and records what it was asked. */
function axiosReplying(reply) {
  const asked = [];
  const configs = [];
  const get = async (url, config) => {
    asked.push(url);
    configs.push(config);
    const answer = await reply(url, config);
    if (answer instanceof Error) throw answer;
    return answer;
  };
  return { asked, configs, get };
}

/** The SDK's downloader as the build bundles it, with `axios` for the real one. */
function builtDownloader(axios) {
  const sdkRequire = createRequire(DOWNLOADER);
  const module = { exports: {} };
  const source = throughMirror(readFileSync(DOWNLOADER, 'utf8'));
  const load = vm.compileFunction(source, ['exports', 'require', 'module', '__filename', '__dirname'], {
    filename: DOWNLOADER,
  });
  load(module.exports, (id) => (id === 'axios' ? axios : sdkRequire(id)), module, DOWNLOADER, ARTIFACTS);
  return module.exports.ArtifactDownloader;
}

function memoryStore() {
  const files = new Map();
  return {
    files,
    get: async (file) => files.get(file),
    store: async (_dir, file, item) => void files.set(file, item),
    exists: async (file) => files.has(file),
  };
}

test('the SDK asks the gateway for the 279 files the mirror holds', () => {
  // The mirror copies these two of the gateway's directories (scripts/private-usd/artifacts-mirror/).
  const directories = [
    'QmUsmnK4PFc7zDp2cmC4wBZxYLjNyRgWfs5GNcJJ2uLcpU',
    'QmZrP9zaZw2LwErT2yA6VpMWm65UdToQiKj4DtStVsUJHr',
  ];
  const hashes = require(path.join(ARTIFACTS, 'json/artifact-v2-hashes.json'));
  const files = [ArtifactName.ZKEY, ArtifactName.WASM, ArtifactName.VKEY];
  const urls = new Set(Object.keys(hashes).flatMap((variant) => files.map((file) => getArtifactUrl(file, variant))));
  assert.equal(urls.size, 279);
  for (const url of urls) assert.ok(directories.some((cid) => url.startsWith(`${IPFS_GATEWAY}/ipfs/${cid}/`)), url);
});

test("the mirror isn't asked for a file the gateway sends", async () => {
  const axios = axiosReplying(() => ({ data: 'gateway' }));
  assert.equal((await artifactGet(axios, VKEY, TEXT)).data, 'gateway');
  assert.deepEqual(axios.asked, [VKEY]);
  assert.equal(axios.configs[0].responseType, 'text');
});

test('when the gateway fails, the mirror is asked for the same path, the same way', async () => {
  for (const failure of [httpError(502), new Error('Network Error')]) {
    const axios = axiosReplying((url) => (fromMirror(url) ? { data: 'mirror' } : failure));
    assert.equal((await artifactGet(axios, VKEY, TEXT)).data, 'mirror');
    assert.deepEqual(axios.asked, [VKEY, mirrored(VKEY)]);
    assert.equal(axios.configs[1], TEXT);
  }
});

test('the mirror is asked once nothing has come from the gateway for 30 s', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let progress;
  const axios = axiosReplying((url, config) => {
    if (fromMirror(url)) return { data: 'mirror' };
    progress = config.onDownloadProgress;
    return new Promise((resolve) => config.signal.addEventListener('abort', () => resolve(new Error('canceled'))));
  });
  const answer = artifactGet(axios, VKEY, TEXT);
  t.mock.timers.tick(GATEWAY_STALL_MS - 1);
  progress({ loaded: 1 }); // the gateway is sending: the wait starts again
  t.mock.timers.tick(GATEWAY_STALL_MS - 1);
  await new Promise(setImmediate); // anything the timers set off has run
  assert.deepEqual(axios.asked, [VKEY]);
  t.mock.timers.tick(1);
  assert.equal((await answer).data, 'mirror');
  assert.deepEqual(axios.asked, [VKEY, mirrored(VKEY)]);
});

test("when both fail, the mirror's failure is the one reported", async () => {
  const axios = axiosReplying((url) => httpError(fromMirror(url) ? 404 : 502));
  await assert.rejects(artifactGet(axios, VKEY, TEXT), /status code 404/);
});

test('a URL off the gateway is refused, and nothing is asked', async () => {
  const axios = axiosReplying(() => ({ data: '' }));
  for (const url of ['https://example.com/ipfs/x', `${IPFS_GATEWAY}.example/ipfs/x`, mirrored(VKEY)]) {
    await assert.rejects(artifactGet(axios, url, TEXT), /not an artifact on the gateway/);
  }
  assert.deepEqual(axios.asked, []);
});

test("built, the SDK's downloader keeps what the mirror sends once the gateway fails", async () => {
  const axios = axiosReplying((url) => (fromMirror(url) ? { data: '{"protocol": "groth16"}' } : httpError(502)));
  const store = memoryStore();
  await new (builtDownloader(axios))(store, false).downloadArtifact(ArtifactName.VKEY, '01x01');
  assert.deepEqual(axios.asked, [VKEY, mirrored(VKEY)]);
  assert.deepEqual([...store.files], [['artifacts-v2.1/01x01/vkey.json', '{"protocol":"groth16"}']]);
});

test("built, the SDK's downloader refuses a file with a wrong hash from either source, without a retry", async () => {
  const wrong = { data: brotliCompressSync(randomBytes(64)) };
  for (const [reply, asked] of [
    [() => wrong, [ZKEY]],
    [(url) => (fromMirror(url) ? wrong : httpError(502)), [ZKEY, mirrored(ZKEY)]],
  ]) {
    const axios = axiosReplying(reply);
    const store = memoryStore();
    const download = new (builtDownloader(axios))(store, false).downloadArtifact(ArtifactName.ZKEY, '01x01');
    await assert.rejects(download, /Invalid hash for artifact download/);
    assert.deepEqual(axios.asked, asked);
    assert.equal(store.files.size, 0);
  }
});

test('the build refuses a downloader that no longer uses axios once, for that request', () => {
  const source = readFileSync(DOWNLOADER, 'utf8');
  assert.throws(() => throughMirror(source.replace('axios_1.default.get(url,', 'axios_1.default.get(artifactUrl,')));
  assert.throws(() => throughMirror(`${source}\naxios_1.default.head(url, {});`));
});
