// Bundles src/ into the assets the hidden anon-rpc page loads: `npm ci --ignore-scripts && npm run build`. Android's
// WebView reads them from the APK's assets under `anon/`. The iOS host does not load this page yet (plan D10).
import { build } from 'esbuild';
import { copyFile, mkdir, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
// From this file, not the working directory: the output is deleted before each build.
const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, '../app/src/main/assets/anon');
const harness = path.dirname(require.resolve('@anon-rpc/browser-harness/package.json'));

await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });

const result = await build({
  absWorkingDir: here,
  entryPoints: ['src/index.js'],
  outfile: path.join(out, 'anon.js'),
  bundle: true,
  format: 'esm',
  platform: 'browser',
  // Android's WebView (Chromium); WebKit for the day the iOS host loads it.
  target: ['chrome100', 'safari17'],
  minify: true,
  legalComments: 'external',
  metafile: true,
  logLevel: 'warning',
});

await copyFile(path.join(here, 'src/index.html'), path.join(out, 'index.html'));
// The §6 isolation boundary: a same-origin page the harness loads under `sandbox="allow-scripts"`, holding nothing but
// the harness's own bootstrap script (its `./iframe-boot.js` export), which spawns the worker and relays the port.
await copyFile(path.join(here, 'src/sandbox.html'), path.join(out, 'sandbox.html'));
await copyFile(path.join(harness, 'dist/iframe-boot.js'), path.join(out, 'iframe-boot.js'));
await copyFile(path.join(harness, 'LICENSE'), path.join(out, 'LICENSE-anon-rpc'));

const bytes = Object.values(result.metafile.outputs).reduce((sum, { bytes }) => sum + bytes, 0);
console.log(`anon.js and notices: ${(bytes / 1024).toFixed(0)} KiB in ${out}`);
