// Railgun's SDK downloads its circuit artifacts from the one IPFS gateway it hard-codes, ipfs-lb.com, with no fallback:
// while that gateway is down, no fresh install can make its first proof. The build (artifact-mirror-plugin.mjs) sends
// the SDK downloader's one request through `artifactGet`, which still asks the gateway first and turns to our mirror of
// its paths when the gateway fails. Only where a file comes from changes: the downloader still checks the hash of
// whatever arrives, as it always has.

export const IPFS_GATEWAY = 'https://ipfs-lb.com';
/** Serves the gateway's `/ipfs/<cid>/…` artifact paths, byte for byte (scripts/private-usd/artifacts-mirror/). */
export const ARTIFACT_MIRROR = 'https://railgun-artifacts.pepeman931.workers.dev';
/** How long the gateway may send nothing, before its answer starts or during it, until the mirror is asked instead. */
export const GATEWAY_STALL_MS = 30_000;

/**
 * `axios.get(url, config)` for an artifact `url` on the gateway. When the gateway's request fails (an HTTP error, a
 * network error, or nothing from it for GATEWAY_STALL_MS), the mirror is asked for the same path, the same way.
 */
export async function artifactGet(axios, url, config) {
  if (typeof url !== 'string' || !url.startsWith(`${IPFS_GATEWAY}/ipfs/`)) {
    throw new Error(`not an artifact on the gateway: ${url}`);
  }
  try {
    return await getUnlessStalled(axios, url, config);
  } catch {
    return axios.get(`${ARTIFACT_MIRROR}${url.slice(IPFS_GATEWAY.length)}`, config);
  }
}

// A gateway that keeps sending, however slowly, is left to finish: only the SDK's own time limit applies to it.
async function getUnlessStalled(axios, url, config) {
  const abandon = new AbortController();
  let timer;
  const wait = () => {
    clearTimeout(timer);
    timer = setTimeout(() => abandon.abort(), GATEWAY_STALL_MS);
  };
  wait();
  try {
    return await axios.get(url, { ...config, signal: abandon.signal, onDownloadProgress: wait });
  } finally {
    clearTimeout(timer);
  }
}
