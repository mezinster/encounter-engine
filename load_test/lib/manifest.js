// load_test/lib/manifest.js
import { SharedArray } from 'k6/data';

// SharedArray, not a bare JSON.parse: without it every VU holds its own parsed
// copy of the manifest, which at 200 VUs is 200 copies of every credential.
const data = new SharedArray('manifest', () =>
  [JSON.parse(open(__ENV.MANIFEST || './manifest.json'))]
);

export function manifest() {
  return data[0];
}

export function teamFor(vu) {
  const teams = manifest().teams;
  return teams[(vu - 1) % teams.length];
}

export function allCodes() {
  return Object.values(manifest().codes).flat();
}
