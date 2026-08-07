# Security Remediation — Index

Source: the whole-application security review of 2026-08-07. Twelve findings survived adversarial
verification; the four HIGH ones were reproduced against a booted app rather than inferred from
reading. This index exists so the work can be handed out one plan at a time — **each plan below is
self-contained and can be implemented, reviewed and merged without any of the others.**

## The plans

| Plan | Findings covered | Severity | Size |
|---|---|---|---|
| [`2026-08-07-security-xss.md`](2026-08-07-security-xss.md) | Vulns 3, 4, 9 — two stored XSS, plus the user-directory email dump that lives on the same line as one of them | HIGH ×2, MEDIUM ×1 | 3 tasks, ~2 files of production code |
| [`2026-08-07-security-gameplay-access-control.md`](2026-08-07-security-gameplay-access-control.md) | Vulns 1, 5, 11 — unregistered teams can play; orphan `GamePassing` rows 500 a public page; option-text read oracle | HIGH ×1, MEDIUM ×1, LOW ×1 | 3 tasks, 1 controller + 1 fixture helper + 3 spec files |
| [`2026-08-07-security-csrf-verbs.md`](2026-08-07-security-csrf-verbs.md) | Vuln 2 — ~20 destructive actions routed over GET, outside CSRF protection | HIGH | 7 tasks, 20 routes / 19 view sites / 2 step defs / ~50 spec lines |
| [`2026-08-07-security-account-protection.md`](2026-08-07-security-account-protection.md) | Vulns 6, 7, 10 + the signup `reset_session` gap — no re-auth on password change, plaintext password in mail, SHA-1 hashing | MEDIUM ×3 | 5 tasks, includes a schema migration and a new mail/reset story |
| [`2026-08-07-security-data-exposure.md`](2026-08-07-security-data-exposure.md) | Vulns 8, 12 — cross-game answer-log disclosure; production DB password in `docker run` argv | MEDIUM ×1, LOW ×1 | 2 tasks, 1 view line + 1 ops script |

Vuln 9 (user-directory email dump) is implemented inside the XSS plan because it is the same ERB
line as Vuln 3 — splitting them would mean two implementers editing one line.

## Suggested order

1. **XSS** first. Smallest diff, closes remote script execution in other users' browsers, no schema
   or test-suite churn.
2. **Gameplay access control** next. One controller method; it is the finding that most directly
   breaks the product's fairness guarantee.
3. **CSRF verbs** third. Largest diff by file count but mechanically simple and fully inventoried.
4. **Data exposure** and **Account protection** last. The account plan is the only one that needs a
   product decision (a password-reset flow has to exist before the welcome-mail password can go).

## Rules that bind every plan

These are repeated in each plan's Global Constraints, but they are the ones most likely to be
violated by someone new to this repo:

- **Never edit a file under `features/**/*.feature`.** Step definitions (`features/*/steps/*.rb`,
  `features/steps/*.rb`, `features/support/*.rb`) are editable. This is a hard rule from
  `CLAUDE.md`; a scenario that appears wrong is a signal to look harder at the implementation.
- Ruby is not on `PATH` in non-login shells. Every command must be preceded by
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"`.
- Capture your own green baseline (`bundle exec rspec`, `bundle exec cucumber`) **before** touching
  anything, and compare against that number rather than against any count written in a document.
- `config/locales/{en,ru,uk,ka}.yml` move together. `spec/i18n_spec.rb` enforces exact `ru`↔`en`
  leaf-key parity and requires `uk`/`ka` to be a subset.
- Object factories are plain helpers in `spec/spec_helpers/fixtures_helper.rb`. Do not introduce
  FactoryBot.

## Findings deliberately NOT planned

Three candidates were refuted or downgraded during verification. They are recorded here so nobody
re-raises them as work:

- **Session fixation on the signup path.** The one-line `reset_session` fix is folded into the
  account-protection plan as hardening, but the CSRF-token-fixation attack does not survive
  scrutiny — `SameSite=Lax` and the Origin check are mutually covering.
- **`:answer` missing from `filter_parameters`.** The same request already persists the answer to
  the `logs` table by design, and the app shows those codes to the author as a product feature.
  Hygiene, not a vulnerability.
- **`create-heroku-instance` leaking `SECRET_KEY_BASE` via `set -x`.** Heroku is a dead deploy
  target; production is Kamal. The valuable fix is documentation — `CLAUDE.md`'s "Deployment:
  Heroku" section is stale and should be corrected to describe Kamal. That is a docs change, not a
  security fix, and is not planned here.
