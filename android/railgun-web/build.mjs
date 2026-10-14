// Bundles src/ into the assets the hidden WebView loads: `npm ci --ignore-scripts && npm run build`.
import { build } from 'esbuild';
import { copyFile, mkdir, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const out = path.resolve('../app/src/main/assets/railgun');

// wasm-bindgen's loaders fetch these next to the bundle (`new URL(file, import.meta.url)`).
const wasm = [
  '@railgun-community/poseidon-hash-wasm/pkg-esm/poseidon_hash_wasm_bg.wasm',
  '@railgun-community/curve25519-scalarmult-wasm/pkg-esm/curve25519_scalarmult_wasm_bg.wasm',
];

const browserBuilds = {
  name: 'browser-builds',
  setup(build) {
    // require() would get the Node builds, which read their wasm from disk; use wasm-bindgen's web builds.
    const web = {
      '@railgun-community/poseidon-hash-wasm': '@railgun-community/poseidon-hash-wasm/index.mjs',
      '@railgun-community/curve25519-scalarmult-wasm':
        '@railgun-community/curve25519-scalarmult-wasm/pkg-esm/curve25519_scalarmult_wasm.js',
    };
    build.onResolve({ filter: /^@railgun-community\/(poseidon-hash-wasm|curve25519-scalarmult-wasm)$/ }, (args) => ({
      path: require.resolve(web[args.path]),
    }));
    // micro-ftch (circomlibjs → web3-utils → @ethereumjs/util) requires these only in its Node path.
    build.onResolve({ filter: /^(http|https|url|zlib)$/ }, (args) => ({ path: args.path, namespace: 'node-stub' }));
    build.onLoad({ filter: /.*/, namespace: 'node-stub' }, () => ({ contents: 'module.exports = {};' }));
  },
};

await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });

const result = await build({
  entryPoints: ['src/index.js'],
  outfile: path.join(out, 'railgun.js'),
  bundle: true,
  format: 'esm',
  platform: 'browser',
  target: ['chrome100'],
  minify: true,
  legalComments: 'external',
  metafile: true,
  inject: ['src/shims.js'],
  define: {
    global: 'globalThis',
    'process.env.NODE_ENV': '"production"',
  },
  alias: {
    crypto: 'crypto-browserify',
    stream: 'stream-browserify',
  },
  plugins: [browserBuilds],
  logLevel: 'warning',
});

await copyFile('src/index.html', path.join(out, 'index.html'));
// The bundle includes GPL-3.0 code (snarkjs, ffjavascript, circomlibjs); its license text ships beside it.
await copyFile('COPYING', path.join(out, 'COPYING'));
for (const file of wasm) {
  await copyFile(require.resolve(file), path.join(out, path.basename(file)));
}

const bytes = Object.values(result.metafile.outputs).reduce((sum, { bytes }) => sum + bytes, 0);
console.log(`railgun.js and legal notices: ${(bytes / 1024 / 1024).toFixed(2)} MiB in ${out}`);
