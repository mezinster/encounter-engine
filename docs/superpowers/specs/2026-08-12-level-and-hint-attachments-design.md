# Level and hint attachments — encounter-engine

**Status:** approved design, ready for an implementation plan
**Date:** 2026-08-12
**Related:** PR #90 scopes the acceptance-suite freeze by provenance. Under that clarification the
new `.feature` files this design adds are port-authored — ordinary review, not owner-authorised
amendments. Nothing here blocks on that PR merging; it only settles which review standard applies.

## Goal

Let game authors attach images and documents to levels and hints, manage them through a per-game
file Explorer, and pick them from a gallery while editing a level — with the file's visibility
following the visibility of whatever it is attached to, and without any path by which an upload can
fill the server's disk.

Formats in scope: **JPEG, PNG, GIF, HEIC, PDF**. HEIC is converted to JPEG on upload, because no
browser except Safari can display it.

## Decisions already taken

| Decision | Choice | Why |
|---|---|---|
| Placement on the play screen | Fixed strip below the task text | Renderer never parses author text, so the app's absolute HTML-escaping guarantee is untouched. No new injection surface at all |
| Ownership | Per **Game** | Levels and hints hang off `Game`; `GameRun` is "one event over that content". A run-scoped library would make photos the only per-run content in the system |
| Visibility | Same rule as the thing it is attached to | It is a competitive game. A level-5 photo reaching a team on level 2 is a cheat, not merely a leak |
| Denied response | **404**, never 403 | A 403 confirms the file exists, and "there is a photo on level 5" is itself worth knowing |
| Image processing | libvips, convert + resize at upload | Fixes HEIC, cuts 4 MB to ~240 KB for a player on mobile data, strips EXIF/GPS, and re-encoding is the strongest anti-polyglot defence available |
| Locale | Nullable `locale`, `NULL` = every language | One column now; avoids a migration through the play path, the picker, the Explorer and the export later |
| Storage | Active Storage, **Disk** service on a Kamal volume | Azure Blob is blocked on an adapter problem (below). The service abstraction keeps the decision reversible |
| Explorer layout | Detail table | "Where is this used" earns a real column — it is what makes deletion safe |
| JavaScript | **None required** | The picker is a checkbox table; rack-test drives it, so the acceptance suite covers it |

## Out of scope, deliberately

* **Inline placement of images within task text.** Considered and rejected — see *Rejected
  alternatives*.
* **Folders in the Explorer.** A quest has tens of files, not hundreds.
* **Upload progress bars, drag-and-drop.** These need JavaScript the acceptance suite cannot
  execute. They belong to the test-infrastructure work that follows this, not to this feature.
* **Per-game-run file overrides.**
* **Direct-to-storage uploads.** Active Storage's direct upload requires JS and bypasses the
  server-side validation in §2, which is the whole security model.

## Why not Azure Blob, given the VM already has a storage account

The deploy already writes to Azure Blob — wal-g ships Postgres WAL to storage account
`eewalxypkl1ft`. Reusing it looks obvious and is currently blocked, for a reason worth recording:

`ActiveStorage::Service::AzureStorageService` (activestorage 8.0.5.1) emits on construction:

> `ActiveStorage::Service::AzureStorageService` is deprecated and will be removed in **Rails 8.1**.
> Please try the `azure-blob` gem instead.

and its signature is `initialize(storage_account_name:, storage_access_key:, ...)` — it **requires a
shared access key**. `config/deploy.yml` states the opposite is deliberate:

> No `AZURE_STORAGE_ACCESS_KEY`. The VM holds a system-assigned managed identity with Storage Blob
> Data Contributor on this account only… A storage account name is not a secret; the key would be,
> and it does not exist here.

So the built-in adapter cannot use the identity-based auth this deployment deliberately chose, and
using it would mean creating the secret that decision avoided. Disk service now; the Active Storage
service abstraction makes the swap a config change plus a byte migration.

**A one-hour investigation worth doing during implementation:** whether the `azure-blob` gem Rails
points at supports IMDS/managed-identity credentials. If it does, this becomes real blob storage
with no access key and the §3 backup problem disappears. If it only takes an access key, it is the
same dead end and Disk stands.

## 1. Data model

```
game_files
  game_id            FK → games, indexed
  filename           author-visible; unique per game
  content_type       from magic bytes, NOT from the request header or the extension
  byte_size          size AFTER canonicalisation
  derived_byte_size  sum of generated variants
  checksum           dedup within a game
  uploaded_by_id     FK → users
  timestamps
  # has_one_attached :file   (Active Storage — canonical bytes)

file_attachments
  game_file_id       FK → game_files
  attachable_type    "Level" | "Hint"
  attachable_id
  locale             nullable; NULL = shown in every language
  position           acts_as_list, scoped to [attachable, locale]
  timestamps
```

`attachable` is polymorphic on purpose: it mirrors `ContentTranslation`'s
`belongs_to :translatable, polymorphic: true`, so levels and hints share one association and a third
owner later costs nothing. `acts_as_list` is already a dependency and is already scoped this way on
`Level`.

Deleting a game destroys its files and their blobs. Deleting a level or hint destroys its
`file_attachments` but **not** the `game_file` — the library outlives any one use.

### Active Storage's cost, accepted with eyes open

Adding `active_storage/engine` to `config/application.rb` — which requires railties one at a time
rather than `rails/all` — brings three tables and pulls in Active Job, which this app does not
otherwise have (no `app/jobs`, no queue adapter, no `active_job/railtie`). With no adapter
configured that is `:async`, an in-process thread pool that drops queued work on deploy.

This is tolerable **only because §2 generates variants eagerly and §3 forbids relying on background
work.** Nothing in this feature may depend on a job completing. If that stops being true, the queue
adapter becomes a prerequisite and must be designed properly rather than inherited by accident.

The engine also draws routes, and this cost was not accepted with eyes open the first time —
`bin/rails routes` after the initial require showed nine `/rails/active_storage/*` entries,
including `POST /rails/active_storage/direct_uploads` and
`PUT /rails/active_storage/disk/:encoded_token`. Both controllers descend from
`ActiveStorage::BaseController`, not `ApplicationController`, so this app's `Authentication` filter
never runs on them: the disk route accepts an anonymous, CSRF-protected write from anyone who can
read a token off a public page. That is not a hardening gap in an otherwise-used feature — direct
uploads are listed under *Out of scope, deliberately* above, precisely because they bypass the §2
validation pipeline, which is the entire security model this design builds. A route nobody is
supposed to call is not a smaller problem than one that is misconfigured; it is the same problem
with no legitimate traffic to excuse it.

The fix is `config.active_storage.draw_routes = false` in `config/application.rb`. This also
removes `blob.url` / `rails_blob_path`, which is desirable rather than incidental: this app already
serves every byte through one authorized route (`GET /games/:game_id/files/:id/:variant`, §4), and
with the built-in helpers gone there is no signed-URL shortcut left lying around for a later phase
to reach for instead of going through §4's authorization matrix. `spec/models/active_storage_wiring_spec.rb`
asserts the route table is empty of `/rails/active_storage` entries so this cannot regress silently
a second time.

## 2. Upload pipeline

Every uploaded byte passes all of this, in order. Nothing reaches storage until it all passes.

1. **Sniff magic bytes.** The client's `Content-Type` and the filename extension are ignored
   entirely — both are attacker-controlled. The first bytes are the file.
2. **Check the sniffed type** against the allowed list (§6), which is itself intersected with a
   hard-coded constant (§4).
3. **Canonicalise:**
   * **HEIC / JPEG / PNG** — decode with libvips, strip **all** metadata, re-encode. HEIC becomes
     JPEG. This is both the HEIC fix and the anti-polyglot defence: a file that is simultaneously
     valid JPEG and valid HTML does not survive being decoded to pixels and written back out.
     Stripping metadata is not cosmetic — a phone photo carries GPS coordinates, which on a
     find-this-building puzzle is literally the answer.
   * **GIF** — validated, **not** re-encoded. Re-encoding an animated GIF either loses the animation
     or needs frame-by-frame handling that is not worth its risk here. GIF is therefore the one
     raster format that keeps its original bytes; it is accepted as a known, bounded exception.
     Consequently a GIF gets a **`thumb` only** (first frame, still), and its `web` variant *is* the
     original — so the per-file limit is the only thing bounding what a player downloads for a GIF.
     That is deliberate: a resized GIF would lose the animation that was the reason to use one.
   * **PDF** — untouched. It cannot be re-encoded without ceasing to be a PDF. Its defences are in
     §4 instead.
4. **Generate variants eagerly** — `web` (max 1600 px) and `thumb` (max 320 px) — at upload time,
   not on first request. See the invariant in §3.
5. **Store.** The author-visible filename is a database string, never a path component; Active
   Storage names files on disk by opaque key. A filename such as `../../etc/passwd` is inert by
   construction, and is escaped like any other content when the Explorer renders it.

**A converted file's identity.** HEIC becomes JPEG, so `дом.heic` is stored as `дом.jpg` with
`content_type: image/jpeg`. The Explorer shows the stored name, not the uploaded one — otherwise an
author sees `.heic` in the list, downloads it, and gets a JPEG. If `дом.jpg` already exists in that
game, the new file is suffixed (`дом-2.jpg`) rather than overwriting: filenames are unique per game
and a silent overwrite could change a level in a running game.

## 3. Disk-space protection

### The problem is bigger than "the volume fills up"

One upload can transit the disk four times, and the app does not own that disk:

```
1. kamal-proxy    buffers the request body     ─┐   buffer-requests defaults to TRUE
2. Rack/Rails     multipart → Tempfile in /tmp  ├─  all one filesystem
3. libvips        scratch during re-encode      │
4. ActiveStorage  canonical blob + 2 variants  ─┘
                                                    …and so is Postgres,
                                                    …and so are the neighbours.
```

The host is **not dedicated**. `docs/superpowers/specs/2026-08-05-kamal-deployment-design.md`
records it as a working utility host with other tenants (danted, the APRS forwarders), 1 vCPU,
~1.1 GB spare RAM, and **30 GB disk with 17 GB free — measured 2026-08-05, before Docker was
installed.** Real free space today is lower and **must be re-measured before the numbers below are
committed to.**

The failure that actually hurts is not "uploads stop working". It is **Postgres, or a neighbouring
service, running out of room because an author uploaded holiday photos.**

### Seven layers, outermost first

| | Layer | Where | Protects |
|---|---|---|---|
| **L0** | `proxy.buffering.max_request_body` | kamal-proxy | `/tmp` and the proxy's own buffer — the only layer acting **before** Puma |
| **L1** | Per-file size limit | app, `Setting` | one absurd file |
| **L2** | Per-game quota | app, `Setting` | one game hogging the box |
| **L3** | Instance-wide cap | app, `Setting` | *N* games × quota exceeding the disk |
| **L4** | Free-space floor (`statvfs`) | app, immediately pre-write | everything, including disk eaten by Docker images, logs, Postgres growth, or a neighbour |
| **L5** | Postgres/neighbour reserve | volume layout | the database and the other tenants |
| **L6** | Reclaim: purge variants and orphaned blobs | rake task + admin button | recovery once it is already tight |
| **L7** | Usage on the admin dashboard | UI | noticing before L4 fires |

**L3 is the one that is easy to forget.** Per-game quotas bound nothing on their own — twenty games
at a 100 MB quota is 2 GB whether or not the disk has it.

**L4 is the only honest guard.** L1–L3 are arithmetic over our own records and are blind to
everything else on the box. A `statvfs` immediately before the write is what actually answers "is
there room right now".

**L5 is preferably enforced by the kernel, not by us.** If app storage is its own volume on a
separate partition, filling it *cannot* reach Postgres or the neighbours — the boundary is a
filesystem boundary. If it shares one filesystem, we are betting that L2 + L3 + L4 are always
correct. Prefer the separate volume; it converts a class of bug into an impossibility. Whether the
VM can present one is an open input (§9).

### Two invariants

**I1 — Reading must never require disk space.** Serving an existing file and its variants is a pure
read. This is why §2 builds variants eagerly: with lazy variants, a player's page load triggers a
libvips run needing scratch space, so a full disk breaks the **play screen for a team mid-race**.
With eager variants a full disk degrades to "authors cannot upload right now", and every running
game keeps working. Any future change that makes a read path allocate disk breaks this invariant.

**I2 — Nothing in this feature may depend on a background job.** See §1. There is no durable queue.

### Concurrency

The quota check is a time-of-check/time-of-use race: two uploads both read "38 MB used of 50", both
conclude they fit, both write, the game lands at 62 MB. Fixed with a row lock on the game held
across check-and-write. Overshoot would be survivable anyway — but only because L4 is a hard
backstop, which is why L4 must not later be dropped as redundant.

### Author-facing behaviour

* Refusals are **422 with a specific message carrying real numbers** — «Осталось 3,2 МБ из 50 МБ» —
  never a generic error and never a 500.
* Multi-file upload is processed **per file**: those that fit are saved, those that do not are
  listed by name. A batch failing atomically would make an author who picked one oversized photo
  re-select all nine.
* **A batch is at most 10 files** (`max_files_per_upload`). This is not comfort — it is what makes
  L0 computable: `max_request_body` has to be a fixed number, and without a batch limit there is no
  fixed number to set it to.

**What the quota counts:** `byte_size + derived_byte_size` summed over the game's files — the
canonical bytes *and* their variants, because that is what actually occupies the disk. A 5 MB
original that yields a 240 KB `web` and an 18 KB `thumb` consumes ~5.26 MB of quota, not 5 MB.

### Proposed defaults

| Setting | Default | Note |
|---|---|---|
| `file_max_megabytes` | 25 | |
| `game_quota_megabytes` | 100 | ~30 photos plus a PDF or two |
| `free_space_floor_megabytes` | 2048 | |
| `instance_cap_megabytes` | **derived from a fresh `df`** | not guessable from the 2026-08-05 figure |
| `proxy.buffering.max_request_body` | `file_max` × batch limit + slack | set in `config/deploy.yml` |

## 4. Serving and authorization

One route, one controller, every byte authorized:

```
GET /games/:game_id/files/:id/:variant      # variant ∈ {original, web, thumb}
```

`:variant` is matched against a hard-coded whitelist before anything touches storage; it never
becomes a path component.

| Requester | May fetch |
|---|---|
| Game author, superadmin | any file in the game |
| Playing team | files on the level they are currently on; on any level they have already passed; on hints that have fired for them |
| Everyone else | **404** |

Already-passed levels are allowed because the team has demonstrably seen them, and the log and
results screens show past levels. The `locale` column does not affect authorization — a Russian
player fetching the English map is harmless.

### Response headers

* `Content-Type` from our stored, sniffed value. Never from the request, never derived from the
  filename.
* `X-Content-Type-Options: nosniff` on every response.
* **PDF: `Content-Disposition: attachment`, always.** Never inline. An inline PDF runs in the
  browser's PDF viewer — a scripting environment we do not control — and §2 cannot neutralise PDF
  bytes. Forcing a download is a small UX cost for the one format that cannot be re-encoded.
  Non-ASCII filenames are RFC 5987-encoded.
* Images: `Content-Disposition: inline`.
* `Cache-Control: private, max-age=…` plus `ETag`. **Never `public`** — a shared proxy must not
  serve an authorized response to a different requester. The `ETag` is load-bearing for capacity,
  not just politeness: it turns repeat views into 304s, which is what stops every image byte
  re-crossing a Puma worker on a 1-vCPU host.

### SVG is permanently excluded, and the setting cannot override it

SVG is an image format that executes JavaScript; an `<svg onload=…>` served inline is stored XSS
against every playing team. Because §6 lets a superadmin edit the allowed-extension list, that list
is **intersected with a hard-coded `PERMITTED` constant in code**. A superadmin may narrow the
allowed set; they cannot widen it. Same treatment for `html`, `xml`, `svgz`.

The general principle, worth keeping: *"superadmin-manageable" is an operator convenience, not a
trust boundary.* A settings screen able to introduce a code-execution vector is a
privilege-escalation path wearing a config option's clothes, and superadmin accounts get phished
like any others.

## 5. Explorer and picker

One partial, `_file_table`, in two modes.

**Explorer** — `GET /games/:id/files`, for the game's author and for superadmins (who reach the same
page for any game). Quota bar, upload form, then the table: thumbnail, filename, size, type, **where
it is used**, delete.

**Picker** — rendered inline in the level and hint edit forms. Same table, checkbox column instead of
the actions column, `name="level[game_file_ids][]"`. Plain HTML: rack-test drives it with
`check`/`uncheck`, so the acceptance suite covers it with no browser driver and no JavaScript.

Rendering the picker inline rather than as a modal or a separate page also removes a problem those
would create: an author with unsaved level text who navigates away loses it. Checkboxes have no
state to lose.

**Deletion** is the one dangerous action, and the "where it is used" column is what makes it safe —
the consequence is on screen beside the button. Deleting a file attached to a level in a **running**
game requires the author to **type the filename** to confirm — the same shape as a destructive
confirmation elsewhere in the industry, and specifically not a checkbox, which is clicked reflexively.
An unused file deletes with an ordinary confirm.

## 6. Settings

`Setting` is integer-only today: `validates :value, numericality: { only_integer: true }`, with
`name` whitelisted against `Setting::DEFAULTS`. An extension list is strings.

**Minimal extension:** add a nullable `string_value` column; split the registry into
`INTEGER_DEFAULTS` (the four existing rate-limit keys, untouched) and `STRING_DEFAULTS`.
`Setting.integer(name)` keeps its exact current behaviour; `Setting.list(name)` is new and returns
an array. The numericality validation becomes conditional on the key being an integer key — the one
existing behaviour that changes, and it gets its own spec.

| Key | Type | Default |
|---|---|---|
| `file_max_megabytes` | int | 25 |
| `max_files_per_upload` | int | 10 |
| `game_quota_megabytes` | int | 100 |
| `instance_cap_megabytes` | int | from a fresh `df` |
| `free_space_floor_megabytes` | int | 2048 |
| `allowed_extensions` | list | `jpg jpeg png gif heic pdf` |

All of it renders on the existing `/admin/settings` page, which already applies a submission in one
transaction and records an audit row carrying the actual values through `AdminAudit`. New keys
inherit both for free.

**Per-game override:** a nullable `storage_quota_megabytes` on `games` (NULL = use the global
setting), editable by superadmins from the admin games page, so one large game can be raised without
raising every game. Same cheap pattern as the nullable `locale`.

## 7. Testing

**RSpec**

* Quota arithmetic, and the row lock under concurrent uploads.
* Magic-byte sniffing rejecting a `.jpg` whose bytes are HTML.
* Canonicalisation actually stripping EXIF/GPS — asserted on a fixture that has them.
* `PERMITTED` intersection refusing an `svg` a superadmin added to the setting.
* The free-space floor, with `statvfs` stubbed.
* **The §4 authorization matrix as request specs — one example per row.** That table is the security
  contract; it is not covered by prose.

**Cucumber** — new `.feature` files for the author flows: upload, attach to a level, attach to a
hint, quota refusal, delete-in-use. Written in **Russian**, matching the surrounding
`features/games` and `features/levels` corpus. These are port-authored files under PR #90's
clarification: ordinary review, no owner authorisation, not amendments.

**The frozen suite must stay green.** This feature adds a picker to the level and hint edit forms —
exactly where `features/levels/*.feature` and `features/hints/*.feature` drive. Adding form fields
should not disturb them, but that is a prediction, not a fact. Full suite before merge; the stable
figure to match is 232 scenarios / 2342 steps.

**CI — two changes, one of them repeating a lesson this repository already paid for**

* The RSpec job runs in `container: ruby:3.3.12`, a Debian image with no libvips. It needs an
  `apt-get install libvips42 libheif1` step. **If libvips is absent the specs must `raise`, not
  `skip`.** This is precisely the countdown/Node situation: guarded examples reported *pending* in
  every CI run for weeks, which reads exactly like passing unless you count them.
* The `app-image` job is the only thing that evaluates `config/environments/production.rb`. It must
  assert libvips is loadable **inside the built image**, or a missing runtime library ships green
  and breaks the first upload in production.

**i18n** — every new user-facing string in all seven locale files. Any new validator needs its
`activerecord.errors` message in all seven, or `raise_on_missing_translations` turns a correct
validation into a confusing raise. Turkish keys carrying a filename or game name must put the case
suffix on a common noun, per the rule in `CLAUDE.md`. Any new string that appears on the **play**
screen must also be added to `spec/i18n_play_screen_spec.rb`'s pinned list — a subset-of-`ru` locale
passes every other i18n check while silently rendering Russian mid-game.

## 7a. Suggested phasing

Large enough to warrant splitting; the plan should decide, but this ordering keeps every phase
independently shippable and green:

| Phase | Contents | Shippable alone? |
|---|---|---|
| **1** | Migrations, `GameFile`/`FileAttachment` models, Active Storage wiring, `Setting` string support, Dockerfile + CI libvips | Yes — nothing user-visible, all specs |
| **2** | Upload pipeline (§2) and disk protection (§3), Explorer page (§5) | Yes — authors can manage a library that nothing consumes yet |
| **3** | Picker in level/hint forms, play-screen rendering, serving controller + authorization matrix (§4) | Yes — the feature becomes real |
| **4** | Reclaim tooling (L6), admin dashboard usage (L7), `azcopy sync` backup | Yes — operational hardening |

Phase 3 is where the frozen acceptance suite is most at risk, since it touches the level and hint
edit forms and the play screen. Run the full suite at the end of every phase, not only at the end.

## 8. Deployment changes

* `Dockerfile` runtime stage: add `libvips42 libheif1` (~40 MB).
* `Gemfile`: `image_processing` (and its `ruby-vips` dependency).
* `config/application.rb`: require `active_storage/engine`.
* `config/deploy.yml`: a volume for `/rails/storage` on the app service — **preferably a separate
  partition** (§3, L5) — and `proxy.buffering.max_request_body`.
* Backup: the volume is **not** covered by wal-g, which backs up Postgres only. Losing the VM loses
  every author's uploads. A periodic `azcopy sync` of the volume to the existing storage account,
  using the same managed identity, closes this without introducing an access key.

## 9. Open inputs

1. **Fresh `df -h` on the VM.** Sets `instance_cap_megabytes` and confirms `free_space_floor`. The
   17 GB figure predates Docker.
2. **Can the VM present a separate partition/disk for `/rails/storage`?** Decides whether §3 L5 is
   kernel-enforced or arithmetic-enforced.
3. **Does the `azure-blob` gem support managed identity?** If yes, real blob storage with no access
   key, and the §8 backup gap closes. One hour to establish.

None of the three blocks starting implementation; each has a conservative default.

## 10. Rejected alternatives

| Rejected | Why |
|---|---|
| **Inline image tokens in task text** (`{{file:дом.jpg}}`) | Requires a renderer that parses author text. Today author content is 100% escaped and the app is structurally incapable of emitting author-supplied markup; a token parser is the first crack in that. The fixed strip gives most of the value at zero cost to the guarantee |
| **Markdown / rich text** | Same objection, much larger. It would also change how *every existing level's* text renders, and 2342 frozen steps assert on that text |
| **Per-game-run files** | Levels belong to the game. A run-scoped library means resolving attachments per-run at play time, and a run whose author forgot to upload shows missing photos with no way to notice beforehand |
| **Public unguessable blob URLs** | A URL is forever: it survives the game ending, gets pasted into chats, and cannot be revoked without re-uploading. For a quest that is re-run, last season's leaked link still works on this season's puzzle |
| **Active Storage's `AzureStorageService`** | Deprecated, removed in Rails 8.1, and requires a shared access key this deployment deliberately does not have |
| **Hand-rolled storage layer** | Defensible in a codebase this minimal, but it means re-solving checksums, variant caching, atomic replace and orphan cleanup — all solved problems — to avoid three tables |
| **Modal picker / drag-and-drop upload** | Needs JavaScript the acceptance suite cannot execute, and would lose an author's unsaved level text on navigation. Deferred to the test-infrastructure work that follows this |
| **Folders in the Explorer** | A whole subsystem — move, rename, orphan handling, and a new way to lose a file — for a library of tens of files |

## 11. What comes next

This feature is deliberately zero-JavaScript so the existing rack-test acceptance suite covers it.
The follow-on project — **upgrading the test infrastructure** so development is not constrained by
`Capybara.default_driver = :rack_test` — gets its own spec. Its requirements come partly from here
(upload progress, drag-and-drop) and partly from a debt already outstanding:
`public/javascripts/level_hint_updater.js` delivers hints to teams **in the live play path** and is
executed by no test in either suite.

Note also that `features/support/env.rb:16` asserts "there is no JavaScript anywhere in this
application", which is false — the app ships 17 JS files including jQuery 1.3.2 on the play screen.
That comment should be corrected whether or not the driver changes.
