// Sends the Railgun SDK's artifact downloads through src/artifact-mirror.js, so a file the SDK's gateway fails to send
// comes from our mirror. The SDK has no setting for its gateway, nor a fallback, so the build rewrites the one request
// its downloader makes: `axios_1.default.get(url, …)` becomes `artifactGet(axios_1.default, url, …)`, with the same
// arguments. Nothing else in the downloader changes, its hash check included.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const DOWNLOADER = /@railgun-community[\\/]wallet[\\/]dist[\\/]services[\\/]artifacts[\\/]artifact-downloader\.js$/;
const AXIOS = 'axios_1';
const REQUEST = `${AXIOS}.default.get(url,`;
const MIRROR = JSON.stringify(fileURLToPath(new URL('src/artifact-mirror.js', import.meta.url)));

/** The downloader's source with its request rerouted; it throws unless axios's one use there is that request. */
export function throughMirror(source) {
  // The import, and the request.
  if (source.split(AXIOS).length !== 3 || source.split(REQUEST).length !== 2) {
    throw new Error(`the SDK's artifact downloader changed: it should use axios once, as \`${REQUEST} …)\``);
  }
  return source.replace(REQUEST, `require(${MIRROR}).artifactGet(${AXIOS}.default, url,`);
}

export const artifactMirror = {
  name: 'artifact-mirror',
  setup(build) {
    let rerouted = false;
    build.onLoad({ filter: DOWNLOADER }, async (args) => {
      const contents = throughMirror(await readFile(args.path, 'utf8'));
      rerouted = true;
      return { contents, loader: 'js' };
    });
    // A bundle whose downloader this didn't reach would download from the gateway alone.
    build.onEnd(() =>
      rerouted ? undefined : { errors: [{ text: "the SDK's artifact downloader was not bundled through the mirror" }] },
    );
  },
};
