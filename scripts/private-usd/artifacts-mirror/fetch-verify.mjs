// Copies the RAILGUN circuit artifacts the wallet SDK downloads (snarkjs: zkey, wasm, vkey) from an IPFS gateway
// into <out>/ipfs/<hash>/..., the same paths the SDK requests, and checks every zkey and wasm the way the SDK does:
// sha256 of the brotli-decompressed bytes against artifact-v2-hashes.json. A file that fails is deleted, never kept.
//
// usage: node fetch-verify.mjs <artifact-v2-hashes.json> <out dir> [gateway]
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile, rm, stat } from 'node:fs/promises';
import { brotliDecompressSync } from 'node:zlib';
import { dirname, join } from 'node:path';

const [hashesPath, out, gateway = 'https://gateway.pinata.cloud'] = process.argv.slice(2);
const MASTER = 'QmUsmnK4PFc7zDp2cmC4wBZxYLjNyRgWfs5GNcJJ2uLcpU';
const POI = 'QmZrP9zaZw2LwErT2yA6VpMWm65UdToQiKj4DtStVsUJHr';
const hashes = JSON.parse(await readFile(hashesPath, 'utf8'));

const jobs = [];
for (const variant of Object.keys(hashes).sort()) {
  const poi = variant.startsWith('POI');
  const files = poi
    ? [
        [`ipfs/${POI}/${variant}/zkey.br`, 'zkey'],
        [`ipfs/${POI}/${variant}/wasm.br`, 'wasm'],
        [`ipfs/${POI}/${variant}/vkey.json`, null],
      ]
    : [
        [`ipfs/${MASTER}/circuits/${variant}/zkey.br`, 'zkey'],
        [`ipfs/${MASTER}/prover/snarkjs/${variant}.wasm.br`, 'wasm'],
        [`ipfs/${MASTER}/circuits/${variant}/vkey.json`, null],
      ];
  for (const [key, kind] of files) jobs.push({ key, kind, expected: kind ? hashes[variant][kind] : null });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let done = 0, skipped = 0, bytes = 0;
const failures = [];

async function verify(buf, job) {
  if (!job.kind) {
    JSON.parse(buf.toString('utf8')); // a vkey must at least be JSON
    return true;
  }
  const digest = createHash('sha256').update(brotliDecompressSync(buf)).digest('hex');
  return digest === job.expected;
}

async function run(job) {
  const path = join(out, job.key);
  try {
    const existing = await readFile(path);
    if (await verify(existing, job)) { skipped++; return; }
    await rm(path);
  } catch {}
  for (let attempt = 1; attempt <= 8; attempt++) {
    try {
      const res = await fetch(`${gateway}/${job.key}`, { signal: AbortSignal.timeout(180_000) });
      if (res.status === 429 || res.status >= 500) {
        await sleep(Math.min(60_000, 2_000 * 2 ** attempt));
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const buf = Buffer.from(await res.arrayBuffer());
      if (!(await verify(buf, job))) throw new Error('hash mismatch');
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, buf);
      done++; bytes += buf.length;
      if ((done + skipped) % 20 === 0) console.log(`progress ${done + skipped}/${jobs.length} (${(bytes / 1e6).toFixed(0)} MB new)`);
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
