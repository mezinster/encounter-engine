# Access codes — design

**Date:** 2026-08-18. **Decided by:** repository owner (`mezinster`), in session.
**Sub-project C of** `docs/superpowers/specs/2026-08-18-commercial-games-programme-design.md`.
**Depends on** sub-project B (`2026-08-18-access-gated-games-design.md`), which shipped the
entitlement — `AccessPass` — and the play path that resolves an attempt from it. C adds the
secret a customer buys and exchanges for one.

## 0. The gap

A team plays a gated game only if an operator has issued it a pass by name
(`AccessPassesController#create`). That is the whole point of B being proven with invitations
only: it kept the play-path surgery free of code generation, digest storage and an export UI.

It is not, however, a product. A commercial customer buys a card, a voucher or an e-mailed
string, and redeems it themselves. C adds that: a **code** is a secret which, exchanged once,
creates exactly one pass.

**The code is not the entitlement.** B settled this and it is what keeps `access_passes.team_id`
NOT NULL forever: an unredeemed code belongs to nobody. Redemption is what mints a pass.

## 1. Decisions

| # | Decision | Answer |
|---|---|---|
| C1 | What does a code look like? | **Ten characters of Crockford base32**, shown grouped as `XXXXX-XXXXX`, accepted case-insensitively. |
| C2 | How much entropy? | **2^50.** With 10,000 codes outstanding, a blind guess succeeds about once in 10^11 attempts. |
| C3 | How is it stored? | **`Digest::SHA256` of the normalised code**, unique-indexed. The raw code is shown once, at generation, and never again. |
| C4 | Is there a batch model? | A **`batch_key` column**, not a table. Every bulk operation is `where(:batch_key => ...)`. |
| C5 | Who may redeem? | The **team captain**, and only them. |
| C6 | Where is the redemption form? | **One global form.** The code carries its own game. |
| C7 | How is the claim made safe? | A **conditional UPDATE** on `redeemed_at IS NULL`, checking the affected-row count, inside the transaction that creates the pass. |
| C8 | What do failures report? | **Specifically** — unknown, redeemed, revoked, expired, game unavailable. C2 is what makes that safe. |
| C9 | How do codes stop working? | Two nullable columns: **`revoked_at`** (an operator act) and **`expires_at`** (a clock). Either may be applied to one code or a whole batch, and either may be lifted. |
| C10 | Does any of that reach a redeemed code? | **No.** They govern whether a code can still be exchanged, and nothing else. |
| C11 | May a team redeem when it already holds a live pass? | **Yes.** B6 lets a team hold several, consumed oldest-first. |
| C12 | How does an operator inspect a code? | By **typing it into a lookup box**. Digest-only storage leaves no other way, and this is the whole support workflow. |

### C9/C10 — why two columns, and where their authority stops

Revocation and expiry are different questions. Revocation is deliberate and immediate — a print
run leaked, a client relationship ended. Expiry is a clock set in advance. Both are useful, both
are cheap, and with `batch_key` they cover all four combinations an operator asked for:

| | one code | whole batch |
|---|---|---|
| revoke now | set `revoked_at` on the row | set it across the `batch_key` |
| expire on a date | set `expires_at` on the row | set it across the `batch_key` |

Both are liftable: a code that has not been redeemed has done nothing irreversible.

**Neither reaches a code that has already been redeemed**, and the spec says so in those words
because "expired" reads like it ought to mean "no longer works". A redeemed code has produced an
`AccessPass`, and that pass has its own lifecycle — spent when the team completes or quits,
released when an operator ends the game (programme P3, P4). Expiring the code afterwards must not
reach through and end a run the customer paid for and may be halfway through.

Killing a live run stays a separate, deliberate act: revoke the **pass**, which B already refuses
once the attempt has begun, precisely so that decision goes through `InterventionsController`
instead.

This mirrors B's `spent?` split: one concept derived from the attempt, another stored on the
thing it describes. Keeping them apart is what stops an operator tidying old codes from
disturbing live games.

### C7 — why the claim is a conditional UPDATE

The unique index on `code_digest` stops two codes sharing a digest. It does **not** stop one code
being redeemed twice: two requests can both read `redeemed_at IS NULL` and both create a pass.

That failure is silent and costs money — a free run, and two passes pointing at one purchase with
nothing in the data to say which was the mistake. So the claim is:

```sql
UPDATE access_codes SET redeemed_at = :now, access_pass_id = :pass WHERE id = :id AND redeemed_at IS NULL
```

and the redemption proceeds only if it affected exactly one row, inside the transaction that
creates the pass. A Ruby-side `if code.redeemed_at.nil?` looks correct and is not.

Note the asymmetry with B, which is deliberate: `AccessPass#spent?` is **derived** because the
attempt already holds the answer, while `redeemed_at` is **stored** because the claim must be one
atomic write.

## 2. Data model

```ruby
create_table :access_codes do |t|
  t.integer  :game_id,        :null => false
  t.string   :code_digest,    :null => false
  t.string   :batch_key,      :null => false
  t.integer  :issued_by_id
  t.datetime :revoked_at
  t.datetime :expires_at
  t.datetime :redeemed_at
  t.integer  :access_pass_id
  t.timestamps
end

add_index :access_codes, :code_digest, :unique => true
add_index :access_codes, [ :game_id, :batch_key ]
```

`access_pass_id` records what a redemption produced. It is the audit trail for a disputed
purchase: this code became that team's pass.

`AccessCode#redeemable?` is `revoked_at.nil? && redeemed_at.nil? && (expires_at.nil? || expires_at > Time.now)`.

**`batch_key` is a handle, not a secret.** It is `SecureRandom.hex(6)`, generated once per
generation request, shown to operators in the console and safe in an `AdminAction`'s `details`.
It identifies a print run; it grants nothing. Only `code_digest` derives from the secret.

## 3. Format and normalisation

The alphabet is Crockford base32 — the digits and the uppercase letters excluding `I`, `L`, `O`
and `U`, giving 32 symbols. A code is ten of them, each drawn as
`ALPHABET[SecureRandom.random_number(32)]`, rendered `XXXXX-XXXXX`.

`random_number(32)` rather than sampling a longer random string, because 32 divides the generator's
range exactly and the draw is therefore uniform — taking characters modulo an alphabet that does
not divide evenly is the standard way to quietly lose entropy.

**Normalisation is one method, used by generation, redemption and the operator's lookup.** It
upcases, strips whitespace and dashes, and maps the confusables the alphabet deliberately
excludes: `I` and `L` to `1`, `O` to `0`. Crockford excludes those from output *so that* they can
be accepted as input; the design only pays off if the input side does the mapping.

If the lookup and the redemption path ever disagreed about normalisation, an operator would
confirm a code is fine while the customer keeps failing to redeem it. One method, and a spec that
asserts a code typed with `O` and `I` resolves to the same digest as the one printed with `0`
and `1`.

`SecureRandom.urlsafe_base64` — B's precedent for tokens — is deliberately **not** used: it is
case-sensitive and contains `-` and `_`, which is right for a URL and wrong for something typed
off a card.

## 4. Generation and the one-time export

A POST on the codes console: how many, and an optional expiry for the batch. It mints N codes
sharing a freshly generated `batch_key`, stores only digests, and renders the raw codes **once** —
monospace, one per line, with a plain statement that this is the only time they will be shown.

No file download and no e-mail: the operator copies them into whatever they already use for
printing or delivery. Both would add a second place a secret can leak, for no capability the
clipboard does not already give.

Generation writes an `AdminAction`.

## 5. Redemption

One global form, reachable from a gated game's catalogue line — B2 renders an "access required"
line there, which becomes the link — and directly, for a customer who arrives holding only a card.

Guards in order: signed in → `SecurityFilters#ensure_team_captain` → `throttle!(:access_code_redemption)`.

The throttle follows `RequestThrottling` exactly, reading `Setting.integer("access_code_redemption_max")`,
so it is operator-tunable and `0` disables it, like every other limit in this app.

A captainless or teamless user is sent to create or join a team, with the code preserved so they
need not retype it.

On success: an `AccessPass` with `source: "access_code"`, the conditional claim of C7, and a
redirect to that game's play screen. **No `AdminAction`** — redemption is a customer act, and
`AdminAction` records administrative acts on other people's things. The operator console shows
redemptions through `access_pass_id` instead.

Refusals are specific (C8) and each has its own message: unknown code, already redeemed, revoked,
expired, and the game no longer being available (withdrawn, draft, or no longer gated).

## 6. The operator console

A second screen beside the existing pass console — `game_access_codes_path(game)` — under the same
guards (`may_operate_commercial?` and `pass_required?`). Passes and codes answer different
questions and both lists grow.

**The list shows batches, not codes.** One row per `batch_key`: when, by whom, size, and counts —
outstanding, redeemed, revoked, expired. Those counts come from **one grouped query**
(`group(:batch_key)`), never a lookup per row: sub-project B broke two query-count specs by adding
a per-row read behind a listing, and the same specs guard this one.

Per-batch actions: revoke all, lift the revocation, set or clear the batch's expiry.

**The lookup box (C12).** An operator cannot read codes off the screen, so when a customer says
their code does not work, the only way to find the row is to type the code in — normalised and
digested exactly as redemption does — and see what it is: which batch, redeemed or not, revoked,
expired, and if redeemed, which team and which pass. From there, per-code revoke, un-revoke and
expiry.

This is a security decision creating a product requirement. Digest-only storage is right, and it
silently removes the operator's ability to inspect a code; the design hands it back through the
one channel that still works — the customer supplying the secret.

Revocation, un-revocation and expiry changes each write an `AdminAction`, with the code or batch
in `details`.

## 7. Security posture

* **Entropy over obscurity.** C2 is what earns C8's specific error messages: distinguishing
  "unknown" from "already redeemed" leaks whether a string is a real code, which matters at 2^30
  and is worthless at 2^50, where an attacker cannot produce a candidate to test.
* **The raw code is never logged.** Not in `Rails.logger`, not in an `AdminAction`'s `details`,
  not in an exception message. The lookup box takes one as a parameter, so `config/application.rb`'s
  `filter_parameters` gains the field name.
* **The throttle is a nuisance filter, not the security control.** At 2^50 it exists to stop noise
  and accidental scripting, which is why `0` disabling it is acceptable here where it would not be
  at lower entropy.
* **Digest lookup** uses `ActiveSupport::SecurityUtils.secure_compare` with an explicit guard so a
  NULL digest can never match — the three-part shape `User.find_by_reset_token` already uses, and
  whose comment explains why that guard exists.

## 8. i18n

New keys in **all seven** locales (`ru`, `en`, `uk`, `ka`, `tr`, `be`, `pl`): the redemption form
and its five refusals, the generation form and its one-time-export warning, the batch list's
column headers and state words, the lookup box and its results, and the audit-action labels.

`spec/i18n_spec.rb` proves only `ru`↔`en` parity plus a subset check for the other five, so
completeness elsewhere is the implementer's job — except the audit labels, which
`spec/i18n_audit_actions_spec.rb` hard-covers in every locale.

Any key interpolating a team or game name must, in Turkish, put the case suffix on a common noun
rather than the placeholder.

## 9. Testing

* **Model** — normalisation (including a code typed with `O`/`I` digesting identically to one
  printed with `0`/`1`); `redeemable?` across all four blocking states; generated codes drawn only
  from the alphabet and of the right length.
* **Concurrency** — the conditional claim. Two redemptions of one code must produce exactly one
  pass. Exercise the claim itself rather than simulating threads: assert that a second claim
  against an already-claimed row affects zero rows and creates nothing.
* **Request** — redemption by a captain; refusal for a non-captain, for each of the five failure
  states, and when over the throttle; generation, revocation, un-revocation and expiry by an
  operator and their refusal for everyone else; the lookup box resolving a code the operator
  cannot see.
* **Regression** — the inherited Cucumber contract (228 scenarios / 2325 steps) unchanged, and the
  existing query-count specs still flat after the batch list lands.

## 10. Sequencing

Three groups, in this order, and the plan should not interleave them because they fail
differently:

1. **The code itself** — table, model, normalisation, generation and the one-time export. A defect
   here is silent and permanent: a weak alphabet or a mis-normalised digest cannot be corrected
   for codes already printed.
2. **Redemption** — the form, the guards, the conditional claim. A defect here gives away runs.
3. **The console** — batch list, bulk actions, the lookup box. A defect here inconveniences an
   operator, who can fall back on the pass console B already ships.

## 11. Out of scope

Payment of any kind (programme §4). Delivery — printing, e-mail, SMS — the operator copies codes
out and uses their own channel. Codes that grant more than one pass, or that name a team in
advance. Self-service refunds. Points, ledgers and the global chart, which are sub-project D.
