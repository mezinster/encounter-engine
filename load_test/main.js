// load_test/main.js
import { fail, sleep } from 'k6';
import exec from 'k6/execution';
import { manifest, teamFor } from './lib/manifest.js';
import { login } from './lib/auth.js';
import { playOnce } from './lib/play.js';

const PHASE = __ENV.PHASE || 'ramp';
const TEAMS = Number(__ENV.TEAMS || 60);

// Team count per plateau, not a rate -- see the README. Defaulted higher than
// the original 10/20/40/80/120: the 2026-08-21 production run sat under 10%
// CPU at 120 teams (load average 0.20), so that ladder never got near a
// ceiling. Override with --env LADDER for a different run.
const LADDER = (__ENV.LADDER || '120,250,500,1000').split(',').map(Number);

// Seconds over which the hold's own teams log in, and the tag boundary that
// keeps that minute out of the measurement.
//
// `constant-vus` starts every VU in the SAME INSTANT. That is a zero-second
// arrival window -- sharper than any stampede this project has run, against a
// host measured to cross its limit somewhere between 30 and 60 seconds. The
// first hold run, 2026-08-27, paid for it twice: 22 of 142 login attempts
// failed, taking the `checks` threshold down with them, and the burst was then
// averaged into a 40-minute summary meant to describe steady play. The tell was
// in the percentiles -- p95 371.5ms sitting above a p90 of 49ms, a clean body
// with a startup-shaped tail, when both healthy stampedes had a HIGHER p90 and
// a lower p95.
//
// 60s is not arbitrary: it is the arrival window the sweep of the same day
// measured as comfortable (p95 309ms, zero errors), and the one
// docs/manual/performance.en.md now tells operators to give their players. The
// test arrives through the door it advises them to use.
const WARMUP = Number(__ENV.WARMUP || 60);

// teamFor(vu) assigns teams by `vu % teams.length`. If the ramp's top
// plateau exceeds the seeded cohort, VUs wrap around and several concurrent
// sessions land on the same team -- many simultaneous writers against one
// GamePassing, which is not a model of anything and would silently produce a
// meaningless ceiling. Fail loudly at startup instead of discovering this
// from a garbled result. Only the ramp phase drives the ladder; `hold` uses
// `TEAMS` and is unaffected.
if (PHASE === 'ramp') {
  const topPlateau = LADDER[LADDER.length - 1];
  const seededTeams = manifest().teams.length;
  if (topPlateau > seededTeams) {
    fail(`LADDER's top plateau (${topPlateau}) exceeds the seeded cohort ` +
      `(${seededTeams} teams). Seed at least ${topPlateau} teams before ` +
      `running this ladder, or lower LADDER to match what's seeded.`);
  }
}

// The stampede oversubscribes exactly the same way -- teamFor(vu) assigns by
// modulo, so more VUs than teams means many sessions hammering one GamePassing.
if (PHASE === 'stampede') {
  const seededTeams = manifest().teams.length;
  if (TEAMS > seededTeams) {
    fail(`TEAMS (${TEAMS}) exceeds the seeded cohort (${seededTeams} teams). ` +
      `Seed at least ${TEAMS} teams, or lower TEAMS to match what's seeded.`);
  }
}

// ramping-vus, NOT ramping-arrival-rate. One VU is one team.
//
// Teams are a closed population: a fixed number exist (see the seeded manifest),
// and if the app slows down a team WAITS -- it does not spawn a second team to
// compensate. ramping-arrival-rate models the opposite: an OPEN population where
// `target` is iterations STARTED per second, a different quantity from "concurrent
// teams" by a factor of the iteration duration -- which play.js's own think times
// (20-90s + 5-20s) make ~67.5s on average. Read as an arrival rate, LADDER's
// plateaus (which the design doc labels team counts) would ask for orders of
// magnitude more concurrent VUs than the team count and generate a request rate
// no real cohort this size produces. With ramping-arrival-rate and this project's
// maxVUs, the pool would starve before the FIRST plateau, so the run would report
// k6's own VU exhaustion as "the ceiling" -- the opposite of this project's
// purpose. See task-9-fix-report.md for the measured numbers.
//
// Each plateau pairs a short ramp so the target is actually reached, then holds
// it for the full 4m so the measurement is a steady-state read, not a transient.
const RAMP = {
  executor: 'ramping-vus',
  startVUs: 0,
  stages: LADDER.flatMap((target) => [
    { target, duration: '30s' },
    { target, duration: '4m' },
  ]),
  exec: 'session',
};

// Forty minutes of steady play PLUS the warm-up, not forty including it. A VU
// that waits 59s to log in would otherwise get 39 minutes of the 40, and the
// question this scenario asks -- what an hour does to the credit bank -- is
// about elapsed play rather than elapsed wall clock.
const HOLD = {
  executor: 'constant-vus',
  vus: TEAMS,          // ~70% of the ramp's last clean plateau
  duration: `${40 * 60 + WARMUP}s`,
  exec: 'session',
};

// Every team arriving at once, which is what a real encounter game does at the
// whistle. Measured 2026-08-21 against production: 120 teams over 22 minutes
// gave p95 196ms; the same 120 arriving in 30 seconds gave p95 5860ms -- with
// zero errors in both. The difference is 91 bcrypt logins landing together on
// one vCPU, a cost no cache or index can reduce.
//
// The first measurement was produced by ACCIDENT, by passing a single-plateau
// ladder that happened to ramp 0->120 inside the executor's 30s stage. This
// scenario exists so the question can be asked deliberately.
const STAMPEDE_WINDOW = __ENV.STAMPEDE_WINDOW || '30s';

const STAMPEDE = {
  executor: 'ramping-vus',
  startVUs: 0,
  stages: [
    { target: TEAMS, duration: STAMPEDE_WINDOW },
    { target: TEAMS, duration: '4m' },
  ],
  exec: 'session',
};

// A lookup, not a ternary: `PHASE=stampede` mistyped as `stamped` used to fall
// through to the ramp and run a completely different test under the name you
// asked for. An unknown phase must refuse.
const SCENARIOS = { ramp: RAMP, hold: HOLD, stampede: STAMPEDE };

// Empty for every scenario but the hold -- see the thresholds block below.
const STEADY = PHASE === 'hold' ? '{phase:steady}' : '';

const THRESHOLDS = {
  [`http_req_duration${STEADY}`]: [
    { threshold: 'p(95)<2000', abortOnFail: PHASE !== 'hold', delayAbortEval: '30s' },
  ],
  [`http_req_failed${STEADY}`]: [
    { threshold: 'rate<0.02', abortOnFail: PHASE !== 'hold', delayAbortEval: '30s' },
  ],
  checks: ['rate>0.99'],
};
if (STEADY !== '') THRESHOLDS[`checks${STEADY}`] = ['rate>0.99'];
if (!SCENARIOS[PHASE]) {
  fail(`unknown PHASE ${JSON.stringify(PHASE)} -- expected one of ` +
    `${Object.keys(SCENARIOS).join(', ')}`);
}

export const options = {
  scenarios: { [PHASE]: SCENARIOS[PHASE] },
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
  // abortOnFail everywhere EXCEPT the hold. The ramp and the stampede are both
  // exploratory runs against production, on a host shared with danted, the
  // squid proxies on 3128-3130/8080-8081 and two APRS forwarders -- the brake
  // is what makes pointing them at it defensible. Only `hold` is meant to run
  // past a breach, because observing what happens after the CPU credit bank
  // empties is its entire purpose.
  //
  // `hold` alone measures a SUBMETRIC. k6 builds `metric{tag:value}` only where
  // a threshold names it, so declaring these here is what makes the steady
  // phase exist in the summary at all -- and that is a deliberate invariant, not
  // a side effect: a summary containing `http_req_duration{phase:steady}` is a
  // summary from a run that had a warm-up to exclude. ops/perf/build_record.rb
  // reads it that way and never asks which scenario ran, so this file stays the
  // one place the policy lives. The ramp and the stampede keep the plain
  // metrics, because for them the logins ARE the measurement -- excluding them
  // would delete the finding.
  //
  // `checks` is the exception, and stays declared on the WHOLE run for every
  // scenario including the hold. lib/auth.js runs its `logged in` check before
  // the tag is set -- deliberately, since a login is arriving rather than
  // playing -- so a hold that measured only the steady phase would be blind to
  // its own warm-up collapsing. That is not a theoretical gap: a failed login
  // here answers 200 with the login page, so it appears in neither
  // `http_req_failed` nor any duration percentile, and `checks` is the only
  // place it shows at all. Before the stagger, a whole-run `checks` threshold
  // was breached by the arrival burst and said little; with arrivals spread
  // over WARMUP, a breach means the app could not absorb even that, which is
  // worth failing on. The hold gets BOTH -- the whole-run threshold as the
  // alarm, the steady one as the measurement.
  thresholds: THRESHOLDS,
};

// Module scope in k6 is PER VU, so this caches one login per virtual user for
// the whole run. Logging in every iteration would put a bcrypt verify on every
// play cycle, which measures a login storm rather than steady play and would
// report a sustained ceiling far below the truth -- defeating the entire point
// of the hold phase. (Modelling the real start-of-game login stampede wants its
// own scenario and its own design pass; it is out of scope here.)
let token = null;
let team = null;

export function session() {
  const base = __ENV.BASE_URL || manifest().base_url;
  if (token === null) {
    // Spread the hold's arrivals over WARMUP seconds instead of firing all of
    // them at once. __VU is 1-based and runs to TEAMS, so this is an even
    // spacing: VU 1 goes immediately, the last waits just under the full
    // window. It costs one sleep per VU, once, in its first iteration.
    if (STEADY !== '') sleep((WARMUP * (__VU - 1)) / TEAMS);

    team = teamFor(__VU);
    token = login(base, team);

    // From here on this VU is playing, not arriving, and its requests carry the
    // tag the hold's thresholds are declared against. Set AFTER the login, so
    // the login itself -- the expensive part, and the part the stampede
    // scenario exists to measure -- stays outside the steady phase. On the
    // other scenarios STEADY is '' and this tags nothing anyone reads.
    if (STEADY !== '') exec.vu.tags.phase = 'steady';
  }
  playOnce(base, token, team);
}
