// A Web Worker that multiplies points by a viewing scalar with the engine's own WebAssembly, for the note keys
// note-keys.js works out ahead. It keeps nothing between batches: each brings the scalar it needs.
import {
  initSync,
  scalarMultiply,
} from '../node_modules/@railgun-community/curve25519-scalarmult-wasm/pkg-esm/curve25519_scalarmult_wasm.js';

/**
 * `multiply(point, scalar)` for each 32-byte point packed in `points`: the 32-byte products, packed the same way, and
 * which points failed, a byte each (1 for one `multiply` refused).
 */
export function multiplyAll(multiply, scalar, points) {
  const count = points.length / 32;
  const products = new Uint8Array(points.length);
  const failed = new Uint8Array(count);
  for (let i = 0; i < count; i += 1) {
    try {
      const product = multiply(points.subarray(i * 32, i * 32 + 32), scalar);
      if (product.length !== 32) throw new Error('not a point');
      products.set(product, i * 32);
    } catch {
      failed[i] = 1;
    }
  }
  return { products, failed };
}

// Only as a worker: a test imports the module for `multiplyAll` alone.
if (typeof WorkerGlobalScope !== 'undefined' && globalThis instanceof WorkerGlobalScope) {
  globalThis.onmessage = ({ data }) => {
    if (data.module !== undefined) {
      initSync(data.module);
      return;
    }
    const { id, scalar, points } = data;
    try {
      const { products, failed } = multiplyAll(scalarMultiply, scalar, points);
      globalThis.postMessage({ id, products, failed }, [products.buffer, failed.buffer]);
    } catch (error) {
      globalThis.postMessage({ id, error: String(error?.message ?? error) });
    }
  };
}
