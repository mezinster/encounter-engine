// load_test/lib/auth.js
import http from 'k6/http';
import { check, fail } from 'k6';

// Rails masks the authenticity_token per render but accepts any valid
// unmasking for the SESSION. So this is scraped once per VU and cached:
// re-fetching before every POST would add a phantom GET to every write and
// distort the read/write ratio the whole test is trying to measure.
//
// Two sources, meta first. csrf_meta_tags is rendered by BOTH layouts
// (application.html.erb and in_game.html.erb), so every page carries a
// token. The hidden form field is not guaranteed: the dashboard a captain
// lands on after login renders a form only if some unrelated not-yet-started
// game happens to exist (an unscoped Game.notstarted query in
// _coming_games.html.erb), which is incidental global state, not a property
// of being logged in. Rails masks the token per render but accepts any valid
// unmasking for the session, so either source yields a token good for every
// later POST.
export function csrfFrom(res) {
  const meta = res.body.match(/name="csrf-token"\s+content="([^"]+)"/);
  if (meta) return meta[1];

  const field = res.body.match(/name="authenticity_token"\s+value="([^"]+)"/);
  if (field) return field[1];

  fail('no CSRF token in response body');
}

export function login(base, team) {
  const form = http.get(`${base}/login`);
  const token = csrfFrom(form);

  const res = http.post(`${base}/login`, {
    email: team.email,
    password: team.password,
    authenticity_token: token,
  });

  // Body content, NEVER status alone. k6 follows redirects, so a failed login
  // returns a cheerful 200 for the rest of the run and a status-only check
  // reports a flawless test against an app it never authenticated to.
  //
  // The check has to be a POSITIVE assertion, not merely "the login form
  // isn't showing again": a wrong password re-renders the form (which the
  // negative form of this check does catch), but a wrong/expired CSRF token
  // makes Rails' protect_from_forgery raise before any form ever renders --
  // in development that's the interactive debug page, in production it would
  // be whatever generic error body Rails falls back to (this app ships no
  // public/422.html). Neither contains `name="password"`, so a check that
  // only tests for that field's absence passes on the CSRF failure too --
  // verified against this app's real /login: a "logged in" check written as
  // `!r.body.includes('name="password"')` reported 100% success on a run
  // where every POST was rejected with 422. The one string that only ever
  // appears on an actual logged-in page is the left-menu's logout link.
  const ok = check(res, {
    'logged in': (r) => r.body.includes('href="/logout"'),
  });
  if (!ok) fail(`login failed for ${team.email}`);

  return csrfFrom(res);
}
