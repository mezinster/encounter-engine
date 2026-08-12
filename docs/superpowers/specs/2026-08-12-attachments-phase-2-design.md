# Attachments phase 2 — upload, disk protection, Explorer

**Status:** approved design, ready for an implementation plan
**Date:** 2026-08-12
**Amends:** `docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md` (the programme design).
Where the two disagree, **this document wins for phase 2** — §3's L5 in particular is superseded.
**Builds on:** phase 1, merged as PR #91 (`398c897`).

## Goal

Make the phase 1 foundation usable: authors upload files through a per-game Explorer, every upload is
canonicalised and validated, and no upload path can exhaust the server's disk.

Out of scope, unchanged from the programme design: the picker in the level/hint forms and the
play-screen strip (phase 3), and offsite backup (phase 4).

## What changed since the programme design was written

The programme design was written before anyone measured the host. Measured on `mezin.eu`,
2026-08-12:

| | |
|---|---|
| Disk | 30 GB total, 17 GB used, **13 GB free** |
| **Postgres volume** | **96 MB** |
| App images | **561 MB each, 7 present** (3.16 GB after layer sharing) |
| `/snap` | 2.8 GB |
| `/var/log/apache2` | 442 MB — another tenant's, unwatched |
| Block devices | **one**: `sda1` at `/`. Everything else is a snap loopback |

Two consequences, and both change the design rather than merely informing it.

### The threat model was pointed at the wrong thing

The programme design says the failure that hurts is *"Postgres, or a neighbouring service, running
out of room."* Postgres is **96 MB** and effectively flat. Meanwhile every Kamal deploy adds another
**561 MB** image — and phase 1 made that image bigger by adding libvips and libheif.

So attachments do not compete with the database. **They compete with the ability to deploy.** A disk
filled by uploads does not corrupt anything; it makes the next `kamal deploy` fail to pull, on a
single-VM setup, which is precisely the state in which you need to ship a fix and cannot.

This is a better threat because it is *more likely* and *less obvious*. Nobody watches free disk
until a deploy fails.

### L5 does not exist and cannot be built cheaply

The programme design preferred a kernel-enforced boundary: app storage on its own partition, so
filling it could not reach anything else. There is one block device and no unallocated space. A
second Azure managed disk would provide it; the repository owner ruled on 2026-08-12 that we do
**not** buy one for phase 2, on the grounds that Postgres is 96 MB and 13 GB is free — the insured
risk is currently small.

**L5 is therefore replaced, not weakened.** Its job passes to L4, whose floor is sized specifically
to protect a deploy (below). The practical effect: **L4 is mandatory, not defence-in-depth.** It is
the only layer that sees the whole disk instead of our own records, and it is now the only thing
between an author's uploads and the next deployment.

## 1. Disk protection (supersedes programme §3)

### The transit table is five, not four

`blob.analyze` runs on attach and opens the blob into a `/tmp` tempfile. The programme design's
table missed it:

```
1. kamal-proxy    buffers the request body      ─┐
2. Rack/Rails     multipart → Tempfile in /tmp   │
3. libvips        scratch during re-encode       ├─  all one filesystem
4. ActiveStorage  analyze → another /tmp file    │
5. ActiveStorage  canonical blob + 2 variants   ─┘
```

### Layers and values

| | Layer | Value | Enforced by |
|---|---|---|---|
| L0 | `proxy.buffering.max_request_body` | **64 MB** | kamal-proxy, before Puma |
| L1 | `file_max_megabytes` | **25** | app |
| L1p | `GameFileUpload::MAX_PIXELS` | **50 Mpx** | app, libvips header parse |
| L2 | `game_quota_megabytes` | **100** | app, under a row lock |
| L3 | `instance_cap_megabytes` | **4096** | app |
| L4 | `free_space_floor_megabytes` | **3072** | app, `statvfs`, immediately pre-write |
| L5 | ~~kernel boundary~~ | **unavailable** | — |
| L6 | reclaim tooling | in this phase | rake + admin |
| L7 | usage on the admin dashboard | in this phase | admin |

**Only one of these values changes what phase 1 shipped.** `Setting::STORAGE_DEFAULTS` already
carries `file_max_megabytes: 25`, `max_files_per_upload: 10`, `game_quota_megabytes: 100` and
`instance_cap_megabytes: 4096` — the last was a placeholder in phase 1 and, measured, happens to be
right. **`free_space_floor_megabytes` changes from 2048 to 3072**, because the floor's job changed:
it now protects a deploy rather than merely leaving slack.

**Why 4096.** 13 GB free; 4 GB is roughly 40 games at the 100 MB quota, far beyond current use, and
leaves ~6 GB of genuine headroom after the floor.

**Why 3072, specifically.** Not a round comfort number. It is approximately two full image pulls
(561 MB each and growing), plus room for Kamal to retain a rollback target, plus slack for the
neighbours — `/var/log/apache2` is already 442 MB with nobody watching it. The floor exists to keep
a deploy possible.

**Why a layer that counts pixels, when every other layer counts bytes.** The five transit stages
above are all measured in bytes, and so were all the layers — which quietly assumes the two
quantities track each other. They do not: the compression ratio is the uploader's to choose. A
**654 KB PNG measured on this host decodes to 625 megapixels**, and costs 2.8 s for the canonical
re-encode plus 1.7 s for each variant. That file is 0.03% of `file_max_megabytes`, so L1 sees a
rounding error; at the full 25 MB the same trick is minutes of CPU. Because `:inline` is what makes
I2 safe, that CPU is spent *in the Puma worker holding the request*, not in a worker pool — and
signup is open, so "author" means any account that registered. The byte layers cannot see this
attack at all; it is not a smaller version of L1, it is a different axis.

Checking it is nearly free, which is why it can sit in front of the expensive step rather than
inside it: `Vips::Image.new_from_file` parses the header and decodes nothing, so `width * height` is
known before a single pixel is materialised. **PDF is exempt by construction** — answering the
question for a PDF would mean invoking vips' PDF loader on untrusted bytes, which contradicts §2's
"No PDF rasterisation" for no benefit, since PDFs get no variants. A header vips cannot read at all
is not this layer's business either: it declines to answer and lets the format's own path produce
the right refusal, so a corrupt GIF still fails where it fails today.

**Why 50 Mpx.** A 48 Mpx phone sensor is the top of the current mainstream and a full-frame camera
sits around 45, so the ceiling is above anything a real photograph arrives as. Bombs are hundreds of
megapixels — this is orders of magnitude clear of both, not a line drawn between two close numbers.

**Why 64 MB for L0.** Ten files at 25 MB would be 250 MB of request body buffered on a host with
~1.1 GB spare RAM. 64 MB bounds that. The cost is a genuine wart, stated plainly: a batch exceeding
it is rejected by kamal-proxy as a bare **413**, before Rails sees it, so the author gets a browser
error rather than a translated message. The Explorer form states the per-upload ceiling up front so
it is rarely reached. This is the price of having any defence that acts before `/tmp`.

### The volume persists; it does not isolate

`config/deploy.yml` gains a named volume for the app service:

```yaml
    volumes:
      - encounter_engine_storage:/rails/storage
```

matching the `db` accessory's existing pattern. Be exact about what this buys: named volumes live
under `/var/lib/docker/volumes` on the **same** filesystem. It fixes *"uploads vanish at the next
deploy"* — which is today's behaviour, since no volume exists — and provides no isolation whatsoever.

**Adding this volume is a prerequisite for the upload form, not a follow-up.** Shipping uploads
without it means the first author's work disappears at the next deploy, with no error anywhere.

### Two invariants, carried forward

**I1 — reading never allocates disk.** Serving a file and its variants is a pure read. This is why
variants are built eagerly at upload. With lazy variants a full disk breaks the *play screen*
mid-race; with eager ones it degrades to "authors cannot upload right now" and every running game
continues. Any future change that makes a read path allocate breaks this.

**I2 — nothing depends on a background job.** There is no durable queue; `:inline` is what makes
that safe.

### Concurrency

Quota is a check-then-write race: two uploads both see room for the last 5 MB. `game.with_lock`
held across check-and-write. Overshoot would be survivable only because L4 is a hard backstop —
another reason L4 cannot later be dropped as redundant.

### Author-facing behaviour

- Refusals are **422 with real numbers** — «Осталось 3,2 МБ из 100 МБ» — never a generic error,
  never a 500.
- Multi-file upload is processed **per file**: those that fit are saved, those that do not are named.
  A batch failing atomically would make an author who picked one oversized photo re-select all nine.

## 2. Upload pipeline (completes programme §2)

Order is unchanged. Four things the programme design left unspecified:

**Sniffing is name-blind.** `Marcel::MimeType.for` is already available — Active Storage depends on
marcel (1.2.1, in `Gemfile.lock`), so no new gem. It must be called with **bytes only**: Marcel
accepts `name:` and `declared_type:` hints and prefers them, and both are attacker-controlled. Passing
the filename would reintroduce exactly what this step exists to ignore.

**`PERMITTED` ceilings the setting.** A frozen constant on `GameFile`:

```ruby
PERMITTED = %w[jpg jpeg png gif heic pdf].freeze
```

read as `Setting.list("allowed_extensions") & GameFile::PERMITTED`. A superadmin may narrow the set
and cannot widen it — the programme design's §4 invariant. `svg`, `html`, `xml`, `svgz` are excluded
by construction, not by remembering to exclude them.

**Filename identity on conversion.** `дом.heic` is stored as `дом.jpg` with
`content_type: image/jpeg`, and the Explorer shows the stored name — otherwise an author downloads
something labelled `.heic` and gets a JPEG. A collision suffixes (`дом-2.jpg`) rather than
overwriting: a silent overwrite could change a level in a running game.

**Two concurrency guards.** The quota lock above, and a filename guard: the model's uniqueness
validation is TOCTOU-racy against its own unique index, so a concurrent duplicate raises
`ActiveRecord::RecordNotUnique`. Rescue it, re-suffix, retry **once**, then 422. Unrescued it is a
500 for a name collision.

**Per format**, unchanged: raster images decode → strip all metadata → re-encode, which fixes HEIC,
removes EXIF/GPS (on a find-this-building puzzle the GPS *is* the answer), and is the strongest
available anti-polyglot defence. **GIF** is validated but not re-encoded, so it gets a still
first-frame `thumb` and its `web` variant *is* the original — the per-file limit is the only bound on
what a player downloads for a GIF, deliberately, because a resized GIF loses the animation that was
the reason to use one. **PDF** is untouched: no variants, no thumbnail, a generic tile.

**No PDF rasterisation.** Rendering page 1 would need poppler in the image. Rejected: poppler parses
untrusted PDFs, and the programme design already treats PDF bytes as untrusted enough to force
`Content-Disposition: attachment`. Parsing them server-side to make a picture contradicts that for a
26px thumbnail.

**One field-setting rule.** `byte_size`, `derived_byte_size`, `content_type` and `checksum` duplicate
what the blob knows, deliberately, so quota arithmetic needs no join. Nothing keeps them in sync, so
**all four are set in exactly one place** and an invariant spec pins it. Divergence silently corrupts
quota accounting, which is a security control here.

## 3. Explorer, settings, reclaim (completes programme §5, §6)

**Routes** nested under the existing `resources :games`: `index`, `create`, `destroy`.
Authorization: the game's author, or a superadmin for any game.

**One partial, `_file_table`**, built now in two modes — an actions column here, a checkbox column
for phase 3's picker. Building both modes now means phase 3 inherits the component instead of
inventing a second one. Pure HTML: rack-test drives it, so the acceptance suite covers it and no
JavaScript is required.

**Deletion.** A file attached to a level in a **running** game requires typing the filename to
confirm; anything else is an ordinary confirm. The "where is this used" column is what makes that
judgement possible, which is why the table layout was chosen over a thumbnail grid.

**Settings.** Phase 1's pre-flight ruling is paid off here: `DEFAULTS` flips from
`RATE_LIMIT_DEFAULTS` to `INTEGER_DEFAULTS`, the five storage keys appear on `/admin/settings`, and
their five labels land in **all seven locales in the same change** that adds the enforcement making
them meaningful. `allowed_extensions` becomes a text field. Entries are validated
`/\A[a-z0-9]{1,10}\z/`, closing phase 1's finding that `Setting.put("allowed_extensions", 123)`
silently stored `"123"`.

**Reclaim (L6) and usage (L7)**, moved into this phase by owner ruling on 2026-08-12: two rake tasks
— purge unattached blobs, and drop-and-regenerate variants — plus disk and quota usage on the admin
dashboard. Honest assessment: with `:inline` purge, deleting through the Explorer already removes the
blob, so orphans arise from crashes mid-upload rather than normal use. **The dashboard number is
probably the more valuable half**, because it is what lets an operator see the wall before hitting
it.

## 4. Phase 1's ledger, resolved

**Closed in phase 1, no action:** the `images.yml` quoting fragility (fixed with `-i` plus an output
sentinel), the `CLAUDE.md` libvips prerequisite, and the `hint.game_files` assertion.

**Closed by disproof — do not act on it.** A note said a blob-purge spec would need
`:transaction => false` because `after_destroy_commit` does not fire in a rolled-back transaction.
The final reviewer tested it: RSpec's wrapper is `joinable: false`, so nested saves get real
savepoints and `after_commit` **does** fire. Phase 2 must not add a slow non-transactional spec on
the strength of that note.

**This phase's:**

| Finding | Where it lands |
|---|---|
| `Setting.put` format validation | §3 above |
| No test for `Setting.put("signup_max", nil)` | with the settings work |
| Filename uniqueness TOCTOU → `RecordNotUnique` rescue | §2 above |
| Settings migration rollback foot-gun | explicit `up`/`down` — this phase wires the admin form, which is what makes it live |
| `activerecord.errors.models.{game_file,file_attachment}.*` missing in all seven locales | with the Explorer; today's *"Game file не может быть пустым"* must become a real Russian sentence |
| `byte_size`/`checksum`/`content_type` sync | §2's one-place rule, with an invariant spec |
| `GameFile.storage_used_by` issues two `SUM` queries | optional; harmless under the row lock |

**One orphan, carried deliberately.** `.gitignore`'s `*.sqlite3` does not match the `-wal`/`-shm`
sidecars, so a `git add -A` after a test run stages a binary. Pre-existing and unrelated to
attachments; the final review suggested a standalone PR. It has not happened. Fold it into this phase
as **its own one-line commit** — visible and separable, not buried in a feature commit.

## 5. Testing

**The Cucumber baseline moves for the first time.** New Russian `.feature` files cover the author
flows — upload, quota refusal, delete-in-use — so the total stops being 232. The invariant becomes:
**the 232 inherited scenarios still pass**, and the new total is stated explicitly in the plan so
drift stays visible. These are port-authored files under PR #90's clarification: ordinary review, no
owner authorisation, not amendments to the frozen contract.

**Real fixtures, including a real HEIC.** Conversion cannot be tested with a fabricated file. Per
task 1's precedent the HEIC spec **raises** rather than skips on a host without HEIC support. That is
correct and nearly free: an ordinary `apt-get install libvips42 libheif1` does provide HEIC — CI
proved it, printing `libvips ok, HEIC ok` from inside the shipped image. The only machine lacking it
is the one whose libvips was hand-installed without root.

**`tmp/storage` needs a cleanup hook** in `spec/rails_helper.rb`; this phase's specs write real blobs
and they otherwise accumulate.

**Other coverage:** quota arithmetic under the row lock; `statvfs` stubbed at and below the floor;
magic-byte sniffing rejecting a `.jpg` whose bytes are HTML; `PERMITTED` refusing an `svg` a
superadmin added; EXIF/GPS actually stripped, asserted on a fixture that has them; the `RecordNotUnique`
retry; the four-field sync invariant.

**Neither suite evaluates `config/environments/production.rb`,** and this phase edits deployment
config — the `app-image` job and the production boot probe stay mandatory.

## 6. Suggested task split

Five units, each independently shippable and green:

| # | Unit | Why it is separable |
|---|---|---|
| 1 | Settings surface — `DEFAULTS` flip, seven-locale labels, format validation, migration `up`/`down` | touches only `Setting` and locales; no upload code |
| 2 | Upload pipeline — sniffing, `PERMITTED`, canonicalisation, variants, field-sync rule | model/service level, no UI, no routes |
| 3 | Disk protection — quota lock, `statvfs` floor, instance cap, `deploy.yml` volume and `max_request_body` | the guards, testable without a form |
| 4 | Explorer page — routes, controller, views, `_file_table` in both modes | the first user-visible surface |
| 5 | Reclaim and dashboard — rake tasks, usage display | operational, additive |

Unit 4 is where the frozen suite is most at risk, since it is the first to add routes and views. Run
both suites at the end of every unit, not only at the end.

## 7. Open items

1. **`azure-blob` managed-identity support** — still open, still one hour, still blocking nothing.
   Relevant to phase 4's backup, not to this phase.
2. **Backup remains absent until phase 4**, by owner ruling. If the VM is lost, uploads are gone
   while `wal-g` restores the rows that reference them. **Phase 3 must therefore treat a missing blob
   as an expected state**, not an exception: the play screen must not 500 when a `game_files` row
   points at a blob that no longer exists. Recorded here because this phase is what creates the rows.
