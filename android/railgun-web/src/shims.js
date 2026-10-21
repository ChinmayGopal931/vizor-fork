// Injected into every module by esbuild: the Node globals Railgun's engine and its deps expect.
import { Buffer } from 'buffer';
import process from 'process';

// The shim's nextTick waits on a clamped setTimeout, which slows the streams a sync runs through.
process.nextTick = (fn, ...args) => queueMicrotask(() => fn(...args));

globalThis.Buffer ??= Buffer;
globalThis.process ??= process;

// WebRTC's STUN and ICE traffic goes around both the CSP and the host's request filter, and nothing here uses it.
for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel']) {
  delete globalThis[name];
}

export { Buffer, process };
