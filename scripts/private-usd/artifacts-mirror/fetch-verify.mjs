// Copies the RAILGUN circuit artifacts the wallet SDK downloads (snarkjs: zkey, wasm, vkey) from an IPFS gateway
// into <out>/ipfs/<hash>/..., the same paths the SDK requests, and checks every zkey and wasm the way the SDK does:
// sha256 of the brotli-decompressed bytes against the SDK's artifact-v2-hashes.json. A file that fails is deleted,
// never kept.
//
// usage: node fetch-verify.mjs <artifact-v2-hashes.json> <out dir> [gateway] [--paths]
// (the hashes ship in the wallet SDK; README has the path)
//
// No gateway resolves the POI circuits' directory since wallet 11.2.0, only its files, so those come by their own
// CIDs and their vkeys from poi-v2/ (exported from the verified zkeys; see README). With --paths every file is asked
// for at the path the SDK requests instead: that is how to check the mirror itself.
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { brotliDecompressSync } from 'node:zlib';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const byPath = args.includes('--paths');
const [hashesPath, out, gateway = 'https://gateway.pinata.cloud'] = args.filter((arg) => arg !== '--paths');
const here = dirname(fileURLToPath(import.meta.url));
const MASTER = 'QmUsmnK4PFc7zDp2cmC4wBZxYLjNyRgWfs5GNcJJ2uLcpU';
// The POI circuits wallet 11.2.0 asks for ("V2"; proofs from the earlier ones no longer verify at the POI nodes).
const POI = 'QmZ2MyM6TKxffkv6stuo2hFwmUfs3q4xgMYN164Sje8new';
const POI_DIRS = { POI_3x3: '03x03', POI_13x13: '13x13' };
const POI_FILE_CIDS = {
  'circuits/03x03/zkey.br': 'QmYG6a72rcLiddX1DyHmDvRaDpkPAf3VdHNNPxVBqndhEy',
  'prover/snarkjs/03x03.wasm.br': 'QmaNNJxu5DqzmB3W6BSR49bsPM1MNhwWH9o4Dqd8cSpeyL',
  'circuits/13x13/zkey.br': 'QmTY2yzKjMhjdcgC52Q3aiHE5wNRUsWgdDtzFtqSFfuzXm',
  'prover/snarkjs/13x13.wasm.br': 'QmUtQFFYcmooihjn5wfYdVNPbtkEv4SKqegwcdcd1L3K5X',
};
// The POI circuits before 11.2.0 (poi-nov-2-23), kept for older builds, with their own hashes.
const POI_V1 = 'QmZrP9zaZw2LwErT2yA6VpMWm65UdToQiKj4DtStVsUJHr';
const hashes = JSON.parse(await readFile(hashesPath, 'utf8'));
const hashesV1 = JSON.parse(await readFile(join(here, 'poi-nov-2-23-hashes.json'), 'utf8'));

const jobs = [];
const add = (key, kind, expected, extra = {}) => jobs.push({ key, kind, expected, ...extra });
for (const variant of Object.keys(hashes).sort()) {
  const dir = POI_DIRS[variant];
  if (dir !== undefined) {
    for (const [file, kind] of [[`circuits/${dir}/zkey.br`, 'zkey'], [`prover/snarkjs/${dir}.wasm.br`, 'wasm']]) {
      add(`ipfs/${POI}/${file}`, kind, hashes[variant][kind], { cid: POI_FILE_CIDS[file] });
    }
    add(`ipfs/${POI}/circuits/${dir}/vkey.json`, null, null, { local: join(here, 'poi-v2', `${dir}-vkey.json`) });
    continue;
  }
  add(`ipfs/${MASTER}/circuits/${variant}/zkey.br`, 'zkey', hashes[variant].zkey);
  add(`ipfs/${MASTER}/prover/snarkjs/${variant}.wasm.br`, 'wasm', hashes[variant].wasm);
  add(`ipfs/${MASTER}/circuits/${variant}/vkey.json`, null, null);
}
for (const variant of Object.keys(hashesV1).sort()) {
  add(`ipfs/${POI_V1}/${variant}/zkey.br`, 'zkey', hashesV1[variant].zkey);
  add(`ipfs/${POI_V1}/${variant}/wasm.br`, 'wasm', hashesV1[variant].wasm);
  add(`ipfs/${POI_V1}/${variant}/vkey.json`, null, null);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let done = 0, skipped = 0, bytes = 0;
const failures = [];

async function verify(buf, job) {
  if (!job.kind) {
    const vkey = JSON.parse(buf.toString('utf8')); // a vkey must at least be JSON
    // One kept in poi-v2/ must be that one.
    if (job.local) return JSON.stringify(vkey) === JSON.stringify(JSON.parse(await readFile(job.local, 'utf8')));
    return true;
  }
  const digest = createHash('sha256').update(brotliDecompressSync(buf)).digest('hex');
  return digest === job.expected;
}

async function keep(path, buf) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, buf);
  done++; bytes += buf.length;
  if ((done + skipped) % 20 === 0) console.log(`progress ${done + skipped}/${jobs.length} (${(bytes / 1e6).toFixed(0)} MB new)`);
}

async function run(job) {
  const path = join(out, job.key);
  try {
    const existing = await readFile(path);
    if (await verify(existing, job)) { skipped++; return; }
    await rm(path);
  } catch {}
  if (job.local && !byPath) {
    await keep(path, await readFile(job.local));
    return;
  }
  const url = job.cid && !byPath ? `${gateway}/ipfs/${job.cid}` : `${gateway}/${job.key}`;
  for (let attempt = 1; attempt <= 8; attempt++) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(180_000) });
      if (res.status === 429 || res.status >= 500) {
        await sleep(Math.min(60_000, 2_000 * 2 ** attempt));
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const buf = Buffer.from(await res.arrayBuffer());
      if (!(await verify(buf, job))) throw new Error('hash mismatch');
      await keep(path, buf);
      return;
    } catch (e) {
      if (attempt === 8 || String(e.message).includes('hash mismatch')) {
        failures.push(`${job.key}: ${e.message}`);
        return;
      }
      await sleep(3_000 * attempt);
    }
  }
  failures.push(`${job.key}: gave up after retries`);
}

const queue = [...jobs];
await Promise.all(Array.from({ length: 3 }, async () => { while (queue.length) await run(queue.shift()); }));
console.log(`files ${jobs.length}: new ${done}, already verified ${skipped}, failed ${failures.length}, ${(bytes / 1e6).toFixed(0)} MB downloaded`);
for (const f of failures) console.log(`FAILED ${f}`);
process.exit(failures.length ? 1 : 0);
