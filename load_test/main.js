// load_test/main.js
import { manifest, teamFor } from './lib/manifest.js';
import { login } from './lib/auth.js';

export default function () {
  const base = __ENV.BASE_URL || manifest().base_url;
  login(base, teamFor(__VU));
}
