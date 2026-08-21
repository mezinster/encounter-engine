// load_test/lib/play.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { allCodes, manifest } from './manifest.js';

const WRONG_SHARE = Number(__ENV.WRONG_SHARE || 0.85);

function randomBetween(a, b) {
  return a + Math.random() * (b - a);
}

function pickCode() {
  if (Math.random() < WRONG_SHARE) return `wrong-${Math.floor(Math.random() * 1e9)}`;
  const codes = allCodes();
  return codes[Math.floor(Math.random() * codes.length)];
}

export function playOnce(base, token) {
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
    answer: pickCode(),
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
