// load_test/lib/play.js
import http from 'k6/http';
import { check, fail, sleep } from 'k6';
import { manifest } from './manifest.js';

const WRONG_SHARE = Number(__ENV.WRONG_SHARE || 0.85);

function randomBetween(a, b) {
  return a + Math.random() * (b - a);
}

// Correctness is PER-LEVEL (app/models/game_passing.rb's check_answer! matches
// through current_level.find_question_by_answer), so a "correct" draw has to
// come from the team's own current level's codes, not the whole game's --
// drawing from every level's codes made the true correct rate ~1/levels of
// the intended (1 - WRONG_SHARE), roughly 30x too low on a typical game. team
// carries the STARTING level id from the manifest (see lib/load_test/seeder.rb);
// this is exactly right at the start of a run and drifts as the team actually
// answers correctly and advances -- accepted rather than tracking live level
// state, which this harness doesn't otherwise need.
function pickCode(team) {
  if (Math.random() < WRONG_SHARE) return `wrong-${Math.floor(Math.random() * 1e9)}`;
  const codes = manifest().codes[team.level_id];
  if (!codes || codes.length === 0) {
    fail(`no codes for level ${team.level_id} — is this manifest older than the level_id field?`);
  }
  return codes[Math.floor(Math.random() * codes.length)];
}

export function playOnce(base, token, team) {
  const gameId = manifest().game_id;

  const page = http.get(`${base}/play/${gameId}`);
  check(page, {
    // A distinguishing marker from the real play screen, not a status code.
    'on the level screen': (r) => r.body.includes('playbar-form'),
  });

  // The model, not padding. This app never polls -- the only setInterval is the
  // client-side countdown, which never contacts the server -- so an idle team
  // costs zero requests. Without think time the script would generate roughly
  // two orders of magnitude more traffic than the team count implies.
  sleep(randomBetween(20, 90));

  const res = http.post(`${base}/play/${gameId}`, {
    answer: pickCode(team),
    authenticity_token: token,
  });
  check(res, {
    // Status alone isn't enough: a redirect (e.g. a session silently lost)
    // is neither 422 nor >=500, so a status-only check would report a
    // dropped POST as "accepted". Assert on body content too, the same
    // playbar-form marker the GET check uses above -- the response after
    // an answer is the play screen either way (next level, or the same one
    // again on a wrong guess). Known false negative: a correct answer that
    // finishes the WHOLE game renders the finish screen instead, which also
    // lacks this marker -- see README's note on this check for the other
    // known false negative (a paused game).
    'answer accepted by the app': (r) =>
      r.status !== 422 && r.status < 500 && r.body.includes('playbar-form'),
  });

  sleep(randomBetween(5, 20));
}
