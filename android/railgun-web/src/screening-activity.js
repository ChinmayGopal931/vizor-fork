/** A progress change goes out at most this often; a step starting or ending goes out at once. */
export const PUBLISH_MS = 250;

/**
 * What the screening work is doing now, for the Processing row: catching up on txids, downloading the proving files,
 * proving POIs. Every change goes out through `publish` as the whole state, `{txids, download, proving}`, each null
 * while idle, so the host always knows what is still running and needs no timers of its own.
 */
export function screeningActivity(publish, now = Date.now) {
  const state = { txids: null, download: null, proving: null };
  const downloads = new Map();
  let published = -Infinity;

  const set = (key, value) => {
    const step = (state[key] === null) !== (value === null);
    state[key] = value;
    if (!step && now() - published < PUBLISH_MS) return;
    published = now();
    publish({ ...state });
  };

  return {
    /** The txid catch-up's share done, 0 to 1, or null once it ends. */
    txids(progress) {
      set('txids', progress === null ? null : { progress });
    },
    /** A download's bytes so far (`total` undefined while unknown), or its end with `loaded` undefined. */
    download(url, loaded, total) {
      if (loaded === undefined) downloads.delete(url);
      else downloads.set(url, { loaded, total });
      if (downloads.size === 0) {
        set('download', null);
        return;
      }
      let done = 0;
      let all = 0;
      let known = true;
      for (const file of downloads.values()) {
        done += file.loaded;
        if (file.total === undefined) known = false;
        else all += file.total;
      }
      set('download', { progress: known && all > 0 ? Math.min(1, done / all) : null });
    },
    /** Proof `index` (from 1) of `count`, `progress` 0 to 1, or null once proving ends. */
    proving(proof) {
      set('proving', proof);
    },
  };
}
