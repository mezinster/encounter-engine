// load_test/main.js
import { manifest, teamFor } from './lib/manifest.js';
import { login } from './lib/auth.js';
import { playOnce } from './lib/play.js';

const PHASE = __ENV.PHASE || 'ramp';
const TEAMS = Number(__ENV.TEAMS || 60);

// ramping-vus, NOT ramping-arrival-rate. One VU is one team.
//
// Teams are a closed population: a fixed number exist (see the seeded manifest),
// and if the app slows down a team WAITS -- it does not spawn a second team to
// compensate. ramping-arrival-rate models the opposite: an OPEN population where
// `target` is iterations STARTED per second, a different quantity from "concurrent
// teams" by a factor of the iteration duration -- which play.js's own think times
// (20-90s + 5-20s) make ~67.5s on average. Read as an arrival rate, the "10 -> 120"
// plateaus below (which the design doc labels team counts) would ask for 675-8100
// concurrent VUs and generate up to 240 req/s against a one-vCPU host, instead of
// the ~3.6 req/s that 120 real teams, each idling most of the time, actually
// produce. With ramping-arrival-rate and this project's maxVUs, the pool would
// starve before the FIRST plateau (10/s needs 675 VUs; maxVUs was 400), so the
// run would report k6's own VU exhaustion as "the ceiling" -- the opposite of
// this project's purpose. See task-9-fix-report.md for the measured numbers.
//
// Each plateau pairs a short ramp so the target is actually reached, then holds
// it for the full 4m so the measurement is a steady-state read, not a transient.
const RAMP = {
  executor: 'ramping-vus',
  startVUs: 0,
  stages: [
    { target: 10,  duration: '30s' }, { target: 10,  duration: '4m' },
    { target: 20,  duration: '30s' }, { target: 20,  duration: '4m' },
    { target: 40,  duration: '30s' }, { target: 40,  duration: '4m' },
    { target: 80,  duration: '30s' }, { target: 80,  duration: '4m' },
    { target: 120, duration: '30s' }, { target: 120, duration: '4m' },
  ],
  exec: 'session',
};

const HOLD = {
  executor: 'constant-vus',
  vus: TEAMS,          // ~70% of the ramp's last clean plateau
  duration: '40m',
  exec: 'session',
};

export const options = {
  scenarios: PHASE === 'hold' ? { hold: HOLD } : { ramp: RAMP },
  // k6 resets each VU's cookie jar at the START of every iteration by default,
  // regardless of module-scope JS state -- confirmed directly: a debug script
  // that dumped http.cookieJar().cookiesForURL() showed an EMPTY jar at the
  // top of iteration 2, on the same VU that had just logged in successfully
  // in iteration 1. Without this flag, every VU authenticates once and then
  // silently loses its session on iteration 2 onward: show_current_level
  // redirects an unauthenticated GET to /login (302), and the cached CSRF
  // token from iteration 1 -- still the only one `session()` ever has, since
  // the login cache below is what's supposed to make re-login unnecessary --
  // no longer matches that reset session, so post_answer 422s with "Can't
  // verify CSRF token authenticity" on every subsequent iteration. That would
  // have made the per-VU login cache below a no-op in practice: correct in
  // theory, silently defeated by k6's own default. See task-9-report.md for
  // the reproduction.
  noCookiesReset: true,
  // abortOnFail only in the ramp. The hold deliberately runs to completion:
  // its whole purpose is to observe what happens after the CPU credit bank
  // empties, which is a threshold breach by design, not a reason to stop.
  thresholds: {
    'http_req_duration': [
      { threshold: 'p(95)<2000', abortOnFail: PHASE === 'ramp', delayAbortEval: '30s' },
    ],
    'http_req_failed': [
      { threshold: 'rate<0.02', abortOnFail: PHASE === 'ramp', delayAbortEval: '30s' },
    ],
    'checks': ['rate>0.99'],
  },
};

// Module scope in k6 is PER VU, so this caches one login per virtual user for
// the whole run. Logging in every iteration would put a bcrypt verify on every
// play cycle, which measures a login storm rather than steady play and would
// report a sustained ceiling far below the truth -- defeating the entire point
// of the hold phase. (Modelling the real start-of-game login stampede wants its
// own scenario and its own design pass; it is out of scope here.)
let token = null;

export function session() {
  const base = __ENV.BASE_URL || manifest().base_url;
  if (token === null) {
    token = login(base, teamFor(__VU));
  }
  playOnce(base, token);
}
