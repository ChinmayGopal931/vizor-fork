// Railgun's SDK downloads its circuit artifacts from the one IPFS gateway it hard-codes, ipfs-lb.com, with no fallback:
// while that gateway is down, no fresh install can make its first proof. The build (artifact-mirror-plugin.mjs) sends
// the SDK downloader's one request through `artifactGet`, which still asks the gateway first and turns to our mirror of
// its paths when the gateway fails. Only where a file comes from changes: the downloader still checks the hash of
// whatever arrives, as it always has.

export const IPFS_GATEWAY = 'https://ipfs-lb.com';
/** Serves the gateway's `/ipfs/<cid>/…` artifact paths, byte for byte (scripts/private-usd/artifacts-mirror/). */
export const ARTIFACT_MIRROR = 'https://railgun-artifacts.pepeman931.workers.dev';
/**
 * How long the gateway may send nothing, before its answer starts or during it, until the mirror is asked instead. The
 * SDK gives a circuit's three files 45 s in all, so the mirror needs most of that time.
 */
export const GATEWAY_STALL_MS = 10_000;

let progressListener;

/**
 * Hears every artifact download as it goes: `(url, loaded, total)` while bytes arrive (`total` undefined when the answer
 * gives no length), then `(url)` once it is done, whichever way. A mirror download reports under its gateway URL.
 */
export function setArtifactProgressListener(listener) {
  progressListener = listener;
}

/**
 * `axios.get(url, config)` for an artifact `url` on the gateway. When the gateway's request fails (an HTTP error, a
 * network error, or nothing from it for GATEWAY_STALL_MS), the mirror is asked for the same path, the same way.
 */
export async function artifactGet(axios, url, config) {
  if (typeof url !== 'string' || !url.startsWith(`${IPFS_GATEWAY}/ipfs/`)) {
    throw new Error(`not an artifact on the gateway: ${url}`);
  }
  const report = (event) => progressListener?.(url, event?.loaded ?? 0, event?.total || undefined);
  try {
    return await getUnlessStalled(axios, url, config, report);
  } catch {
    return await axios.get(`${ARTIFACT_MIRROR}${url.slice(IPFS_GATEWAY.length)}`, {
      ...config,
      onDownloadProgress: report,
    });
  } finally {
    progressListener?.(url);
  }
}

// A gateway that keeps sending, however slowly, is left to finish: only the SDK's own time limit applies to it.
async function getUnlessStalled(axios, url, config, report) {
  const abandon = new AbortController();
  let timer;
  const wait = () => {
    clearTimeout(timer);
    timer = setTimeout(() => abandon.abort(), GATEWAY_STALL_MS);
  };
  wait();
  try {
    return await axios.get(url, {
      ...config,
      signal: abandon.signal,
      onDownloadProgress: (event) => {
        wait();
        report(event);
      },
    });
  } finally {
    clearTimeout(timer);
  }
}
