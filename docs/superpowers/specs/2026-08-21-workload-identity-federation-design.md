# Workload Identity Federation for `ANTHROPIC_API_KEY` — encounter-engine

**Status:** designed and deliberately **dormant**. Do not implement until a trigger in §6 fires.
**Date:** 2026-08-21
**Related:** extends the *"Why not Azure Key Vault"* section of
`2026-08-16-ai-translation-design.md`, which decided how the Claude credential is delivered today.
This document revisits that decision against a mechanism that did not exist when it was taken, and
reaches the same answer — for now — with the conditions for changing it written down.

## Goal

Record whether Anthropic's Workload Identity Federation (WIF) can replace the static
`ANTHROPIC_API_KEY` this application uses for AI translation, and — since the answer is "yes,
technically" — record why we are **not** doing it yet, what it would cost, and the specific
Entra ID details that would otherwise have to be rediscovered.

The point of writing this while it is fresh is that the expensive part of the work is not the code.
It is the Entra/Anthropic configuration and the two or three non-obvious ways it fails. Those are
below.

## The recommendation, up front

**Leave `ANTHROPIC_API_KEY` in place.** The trade on offer is:

* **Give up:** a static secret with one consumer, on one VM, already absent from git, already
  absent from disk in plaintext, sourced from a GitHub Actions secret through `.kamal/secrets`
  into container env. Its blast radius today is *this feature's spend* and nothing else — the key
  is workspace-scoped and buys an attacker Claude API calls, not access to the game database.
* **Take on:** an Entra app registration, an Anthropic federation issuer, a federation rule, a
  service account, and a new **liveness** dependency — IMDS reachable, VM clock within 30 seconds
  of true, Anthropic's JWKS cache warm, token exchange succeeding — inside
  `Translation::Runner`'s bare background `Thread`, which is already the least observable path in
  the application (it is why `TranslationRun.sweep_stale!` exists at all).

Today an unset key means the feature *politely does not exist* — `Translation::Client.configured?`
is false, the controller guard refuses, the views hide every entry point. Under federation, a
**broken exchange** is a different animal: configuration looks present, the guard passes, and the
failure surfaces mid-run in a thread whose death locks a game out of translation until swept.

On a one-VM deployment with one key and one consumer, that is not a good exchange rate. §6 lists
what would change it.

## Decisions taken

| Decision | Choice | Why |
|---|---|---|
| Adopt WIF now? | **No** | See above. The static-secret risk is already contained; the new failure mode is not |
| Is it feasible here? | **Yes**, and unusually cleanly | The VM already holds a managed identity and already proves IMDS works from inside a Kamal container — see §2 |
| Identity source, if adopted | Azure **system-assigned managed identity** via IMDS | Already present, already trusted for wal-g. No second identity to manage |
| Token delivery to the SDK | A **callable provider**, not a token file | `anthropic 1.62.0` accepts `identity_token_provider:`; no sidecar writing files to disk, no projected-volume machinery that doesn't exist outside Kubernetes |
| Rule scope, if adopted | `workspace:inference` | Strictly narrower than an API key. This is the one genuine security *gain* on the table — see §3.5 |
| Cutover style | Precedence-driven, reversible, zero-downtime | The API key outranks federation in the SDK's resolution order, so both can be configured at once — see §5 |

## §1 What federation actually is

Not "tokenless" — **credential substitution**. Instead of holding a long-lived `sk-ant-...`, the
workload presents a JWT that its own platform already issues to it, and Anthropic exchanges that
JWT for a short-lived access token (`POST /v1/oauth/token`, the RFC 7523 `jwt-bearer` grant,
returning an `sk-ant-oat01-...` bearer token with an `expires_in`).

Four environment variables activate the direct env-var path; all four must be set or the SDK
reports "no credentials" rather than falling through:

```
ANTHROPIC_FEDERATION_RULE_ID   fdrl_...
ANTHROPIC_ORGANIZATION_ID      <uuid>              # Console → Settings → Organization
ANTHROPIC_SERVICE_ACCOUNT_ID   svac_...
ANTHROPIC_IDENTITY_TOKEN_FILE  /path/to/jwt        # or ANTHROPIC_IDENTITY_TOKEN (literal JWT)
```

`ANTHROPIC_WORKSPACE_ID` is read alongside but does **not** gate activation. It is required only
when the rule is enabled for more than one workspace; with a single-workspace rule the server picks
it. The minted token is workspace-scoped *at exchange time*, so the per-request
`anthropic-workspace-id` header does not work with federation tokens.

**Credential precedence, first match wins** — this matters twice, in §5 and in the trap below:

| Order | Source |
|---|---|
| 1 | Constructor argument (`api_key:`, `auth_token:`, `credentials:`) |
| 2 | `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` |
| 3 | `ANTHROPIC_PROFILE` (a missing named profile is an **error**, not a fall-through) |
| 4 | Federation environment variables |
| 5 | Active profile on disk |

> **The empty-string trap.** A variable set to `""` still occupies its precedence slot. Exporting
> `ANTHROPIC_API_KEY=""` selects the API-key path *with an empty key* rather than falling through
> to federation. Unset it; never blank it. This is worth knowing independent of federation,
> because `.kamal/secrets` composes variables from the environment and an unset upstream secret can
> produce exactly this shape.

## §2 Why this VM is unusually well suited

Checked rather than assumed. From `config/deploy.yml:97`, written for the wal-g backup accessory:

> No `AZURE_STORAGE_ACCESS_KEY`. The VM holds a system-assigned managed identity with Storage Blob
> Data Contributor on this account only, and wal-g's Azure default credential chain fetches
> short-lived tokens from IMDS. […] If Task 4 Step 6 found IMDS unreachable from a container, add
> `AZURE_STORAGE_ACCESS_KEY` to the secret list below.

That comment establishes two things this design would otherwise have to prove from scratch:

1. **The VM has a managed identity.** No new identity to create or assign.
2. **IMDS is reachable from inside a Kamal container.** The comment explicitly anticipated that it
   might not be and prescribed a fallback; the fallback was never taken, so the container path
   works on this host. `169.254.169.254` being unreachable from a bridge-networked container is the
   single most likely thing to sink an IMDS-based scheme, and it is already disproven here.

The `2026-08-13-offsite-backup-design.md` spec makes the same point from the other side
(§"managed identity, no access key, short-lived tokens from IMDS") — the pattern is established in
this deployment, not novel to this document.

**SDK support is present and does not need upgrading.** `anthropic 1.62.0` (pinned in
`Gemfile.lock:80`) ships `Anthropic::Credentials::WorkloadIdentity`, which takes an
`identity_token_provider:` — any callable returning the JWT string. Relevant behaviours read from
the gem source:

* The provider is **re-invoked on every exchange**, so a rotating token is always current.
* Passing the object as `credentials:` to `Anthropic::Client` wraps it in a `TokenCache`
  automatically, so the exchange does not happen per request.
* The assertion is capped at 16 KiB (`MAX_ASSERTION_BYTES`); real IdP JWTs are under 4 KiB.
* Exchange failures raise a typed `Anthropic::Credentials::WorkloadIdentityError` carrying
  `status_code`, a redacted `body`, and `request_id`.

A lambda that curls IMDS is therefore a first-class provider. No token-file sidecar, no projected
volume, no file-watching.

## §3 The Entra ID specifics

This section is the reason the document exists. **Marked throughout: what was read from Anthropic's
WIF reference (verified) versus what is reasoning about Entra's behaviour (must be confirmed by
decoding a real token before anyone builds on it).**

### §3.1 Ask IMDS for *your own* resource, not a Microsoft one

*(Reasoning — confirm by decoding.)* Azure managed identity issues an **access token for a named
resource**, not a generic ID token. Tokens minted for Microsoft-owned resources (Graph and friends)
are not reliably verifiable against the public JWKS — they may be encrypted or signed with keys
outside the published set. The workable shape is to register **your own Entra application** and ask
IMDS for a token whose audience is that app:

```
GET http://169.254.169.254/metadata/identity/oauth2/token
      ?api-version=2018-02-01
      &resource=api://<your-app-id-uri>
Metadata: true
```

The resulting JWT should carry `aud` = your app URI, `sub` = the managed identity's principal, and
an `iss` naming your tenant.

### §3.2 `iss` will not match the discovery URL — use `jwks.discovery_base`

*(Anthropic side verified; Entra values are reasoning.)* Entra v1 tokens are issued with
`iss = https://sts.windows.net/<tenant-id>/`, while the OIDC discovery document lives under
`https://login.microsoftonline.com/<tenant-id>/`. Anthropic compares the JWT's `iss` claim against
the registered `issuer_url` **byte for byte** — scheme, trailing slash and all — and separately
needs somewhere to fetch keys from.

The issuer's `jwks` field is a discriminated union that handles exactly this:

| `jwks.type` | Behaviour | Fit here |
|---|---|---|
| `discovery` (default) | Fetches `<discovery_base or issuer_url>/.well-known/openid-configuration`, reads `jwks_uri`, fetches keys | **Use this**, with `discovery_base` set to the `login.microsoftonline.com` tenant URL so `issuer_url` can stay equal to the `iss` claim |
| `explicit_url` | Fetches a JWKS URL directly; `issuer_url` never dialled | Workable fallback |
| `inline` | Keys pasted in; no outbound fetch, **and no automatic rotation** | Wrong for Entra — a key rotation would break every exchange |

`issuer_url`, `discovery_base` and `jwks.url` are all validated: HTTPS only, port 443 only, public
DNS hostname only, no IP literals.

### §3.3 The token-lifetime ceiling is the most likely first failure

*(Anthropic side verified; the collision is the reasoning.)* Anthropic rejects an assertion whose
lifetime — `exp` minus `iat` — exceeds the **issuer's configured maximum, which defaults to
1 hour**. Azure managed-identity access tokens routinely carry lifetimes well beyond that, and for
some resources up to 24 hours.

If that holds, a correctly configured federation will fail on its very first exchange, with the
opaque `401` described in §3.6, for a reason that has nothing to do with any of the claim matching
anyone will be staring at. The fix is to raise the issuer's maximum lifetime in the Console when
registering it — but only after decoding a real token and reading its actual `exp - iat`, and only
as far as that value requires. **Check this first, before debugging anything else.**

Other verified JWT constraints, all of which Entra satisfies normally:

* Asymmetric signing only (RS*/PS*/ES*); `HS256` and `none` rejected.
* A `kid` header matching a key in the JWKS is **required**.
* `sub`, `iat`, `exp` must all be present; `iat` not in the future, `exp` in the future.
* 30-second clock-skew leeway on `exp`, `nbf`, `iat`. Azure VMs sync time from the host, so this
  should be free — but it is a dependency the API key does not have.

### §3.4 Writing the rule's `match` block

*(Verified.)* All populated matchers are ANDed. **At least one of `subject_prefix`, `claims`, or
`condition` must be set** — a block containing only `audience` is rejected outright, precisely to
prevent a rule that accepts every token from an issuer.

| Matcher | Semantics |
|---|---|
| `subject_prefix` | Exact match on `sub`, case-sensitive; a trailing `*` makes it a prefix match |
| `audience` | `aud` must contain this string exactly (any element, if `aud` is an array) |
| `claims` | Map of top-level claim name → required exact string value |
| `condition` | A CEL expression over a `claims` map, for nested/non-string claims |

*(Reasoning.)* For a managed identity the natural matcher is `subject_prefix` set to the identity's
object/principal ID, plus `audience` set to the app URI. **Do not assume `sub` equals the object
ID** — decode a real token and look. Entra also emits `xms_mirid`, carrying the managed identity's
full ARM resource ID, which would make a far more legible matcher via `claims` or a CEL
`condition` if it is present. Decide from the decoded token, not from this paragraph.

> CEL conditions are a security boundary. An expression that is true for more inputs than intended
> grants more access than intended. Prefer the static matchers wherever they express the constraint.

### §3.5 Scope: the one place federation is genuinely *better*

*(Verified.)* A federation rule's `oauth_scope` is a ceiling the minted token can never exceed.
This application needs exactly one thing from the Claude API — Messages, including streaming and
token counting — which is the `workspace:inference` scope:

| Scope | Grants |
|---|---|
| `workspace:inference` | Messages (incl. streaming and `count_tokens`) and Models. **This is our whole surface.** |
| `workspace:developer` | The above plus Files, Skills, Managed Agents — "what an API key for the same workspace has" |
| `org:admin` | The Admin API. Never relevant here |

`Translation::Client` calls `messages.create` and `count_input_tokens` and nothing else, so a
`workspace:inference` rule is a strictly tighter credential than the API key it would replace. That
is a real improvement and the strongest argument in favour whenever the triggers in §6 do fire.
Effective permission is the intersection of the rule's scope and the target service account's
`organization_role`, so the service account should be `developer`, not `admin`.

### §3.6 Every denial looks identical

*(Verified.)* Every assertion denial returns the same `401 authentication_error` with the fixed
message `Authentication failed`, regardless of which check failed — deliberately, so a caller
cannot probe rule configuration. The actual reason (`match_subject_prefix`, `workspace_id_required`,
and so on) is recorded **only** on the attempt's row in the Console's authentication-history tab
(Settings → Workload Identity Federation → History).

Budget for this. The debugging loop is "read the history page", not "read the error". Note also
that a `401` with *no* matching history entry usually means the `federation_rule_id` itself was not
recognised, and that malformed-request `400`s leave no history entry at all but do name their
problem directly.

## §4 The code change is small, and mostly deletion

Four seams touch the credential. All of them get simpler, because the SDK's precedence chain is
doing work the application currently does by hand.

| Location | Today | Under federation |
|---|---|---|
| `app/services/translation/client.rb:137` | `::Anthropic::Client.new(:api_key => @api_key)` | `::Anthropic::Client.new` — or `credentials:` with the IMDS provider. Let precedence resolve |
| `app/services/translation/runner.rb:114` | `Client.new(:api_key => ENV["ANTHROPIC_API_KEY"], ...)` | Stop threading a key through |
| `app/services/translation/runner.rb:335` | same | same |
| `app/services/translation/client.rb:59` | `configured?` → `ENV["ANTHROPIC_API_KEY"].present?` | Becomes "is *a* credential configured" |

`config/deploy.yml:85` drops `ANTHROPIC_API_KEY` from the `secret:` list and gains four
non-secret `clear:` entries — federation rule ID, organization ID, service account ID are
identifiers, not credentials, and belong in the clear block. `.kamal/secrets` loses a line.

**`configured?` is the only one needing thought.** `TranslationRunsController#require_api_key!`
(line 165) leans on it to make the whole feature *absent* rather than *broken* when unconfigured,
and the views hide every entry point on the same signal. That absent-by-default property is
load-bearing and must survive: with nothing set, development and CI keep working and the feature
keeps disappearing cleanly. What it cannot detect any more is a credential that is present but
*will not exchange* — see the risk in "The recommendation, up front".

**The spec suite is unaffected by design.** `client.rb`'s own header comment states it is the only
place in the application that touches the Anthropic SDK and that every spec stubs this seam, so no
spec needs a network or a credential. That stays true. `configured?` is the one behaviour whose
specs would need revisiting.

## §5 The cutover is reversible and has no downtime

This follows directly from precedence (§1): `ANTHROPIC_API_KEY` **outranks** the federation
variables. So the two can coexist, and the sequence is:

1. Ship the §4 code change with the key still set. The key wins; nothing changes in production.
2. Configure the Entra app, issuer, rule and service account. Set the four federation variables
   alongside the still-present key. The key still wins; still nothing changes.
3. Verify the exchange independently — a one-off `bin/rails runner` that builds the provider and
   calls it, or the raw `POST /v1/oauth/token` with a token fetched by hand from IMDS.
4. **Unset** (never blank — §1) `ANTHROPIC_API_KEY`. Federation is now the winning credential.
5. To roll back, set the key again. One variable, one deploy.

Steps 1–3 are risk-free rehearsal; only step 4 is a change in behaviour, and it is a single
reversible variable. This property is why the design is worth having on file: whenever it is
picked up, it does not need a maintenance window or a leap of faith.

## §6 Triggers — when to wake this up

Any one of these makes the trade in "The recommendation, up front" come out the other way:

* **More keys, or more consumers.** A second service, a scheduled job, or anything else calling
  the Claude API. The argument against is "one key, one consumer"; that premise is what is being
  tested.
* **CI needs to call the Claude API.** This is the strongest trigger and the one to watch. GitHub
  Actions OIDC is the best-supported federation path there is, and the deploy workflow
  (`.github/workflows/deploy.yml:117`) already authenticates to Azure by exactly this mechanism, so
  the concept is not new to this repository. If CI ever needs Claude access, federate it from day
  one rather than minting a second static key.
* **A compliance or policy requirement for no long-lived credentials.**
* **Moving off the single VM** — anything with real workload-identity plumbing (Kubernetes
  projected tokens, Container Apps) makes the token-delivery half nearly free, which is most of
  what makes it unattractive today.
* **Wanting the tighter scope for its own sake.** §3.5 is a real reduction in what a leaked
  credential buys. Not sufficient on its own at current scale, but it is a thumb on the scale.

Absent all of these, revisiting this is churn. Leave it.

## §7 Rejected and out of scope

* **Azure Key Vault.** Still rejected, still for the reasons in `2026-08-16-ai-translation-design.md`
  §"Why not Azure Key Vault" — Kamal 2.12 ships no Azure adapter, and wiring one in adds a
  boot-time failure mode for the whole application in exchange for one key. Nothing here changes
  that. Note that federation and Key Vault are *alternatives*, not complements: federation removes
  the secret rather than storing it better, which is why it is the more interesting of the two if
  either is ever adopted.
* **An `ANTHROPIC_PROFILE` / on-disk profile.** Profiles (`<config_dir>/configs/<name>.json`) are
  the ergonomic path for baking federation parameters into an image, and the config half is
  non-secret and commit-safe. Rejected for now because it adds a file to manage inside the
  container for four environment variables Kamal already delivers, and because a *missing* named
  profile is a hard error rather than a fall-through — a new way to break boot.
* **`inline` JWKS mode.** No automatic key refresh; an Entra signing-key rotation would break every
  exchange until someone noticed. Use `discovery`.
* **Rotating the API key more aggressively as a middle path.** Considered and not pursued: rotation
  is a deploy here, and the thing it would mitigate (a leaked key) is already bounded by workspace
  scope and by the fact that the key never lands in git or on disk.

## §8 Open questions, for whoever picks this up

Each of these is a decode-and-look, not a design decision. None can be answered from documentation
alone, which is why they are questions rather than decisions:

1. What are the actual `iss`, `aud`, `sub`, `exp - iat` and `xms_mirid` values in a real IMDS token
   for a custom `resource=api://...` audience on **this** VM? Everything in §3 hangs off this.
2. Does `exp - iat` exceed one hour (§3.3)? If so, what maximum lifetime does the issuer need?
3. Is `sub` the managed identity's object ID, or something else? Which claim makes the best
   matcher (§3.4)?
4. Does the Anthropic token exchange itself succeed from inside the container — i.e. is outbound
   HTTPS to `api.anthropic.com` plus the IMDS hop both fine under the current NSG rules? Outbound
   to Anthropic is already proven by the feature working; the IMDS hop is proven by wal-g; the
   combination in one process is not.
5. How should a `WorkloadIdentityError` surface inside `Translation::Runner`'s thread? It arrives
   at a different layer than `Translation::Client::Error` and would otherwise kill the thread and
   leave the run for `sweep_stale!`. This is the one piece of *new* design the adoption would need.
