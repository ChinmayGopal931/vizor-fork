// Bodies cross the host channel as base64 inside JSON.

const CHUNK = 0x8000;

/** `bytes` as base64. */
export function toBase64(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

/** The bytes `base64` encodes. */
export function fromBase64(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/**
 * `text` with every URL replaced: the worker's lines and a fetch error can quote the RPC URL, which may hold a key,
 * or a KPS address.
 */
export function redact(text) {
  return String(text).replace(/\b[a-z][a-z0-9+.-]*:\/\/\S+/gi, '<url>');
}
