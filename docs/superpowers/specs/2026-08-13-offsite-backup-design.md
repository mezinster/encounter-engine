# Offsite backup — replacing Azure VM Backup

**Status:** approved design, ready for an implementation plan
**Date:** 2026-08-13
**Supersedes:** the `azcopy sync` sketch in §3/§8 of
`docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md` (phase 4)
**Related:** `docs/runbooks/restore.md` (database only), `config/deploy.yml`,
`.github/workflows/deploy.yml` (`setup` mode)

## Goal

Protect everything on the production VM that cannot be rebuilt, at a cost proportionate to
what it is worth, and retire the Azure Backup vault — whose price cannot be tuned down.

## What changed since phase 2 assumed this

Phase 2's design said losing the VM loses every author's uploads, and proposed `azcopy sync` to
close that. Two things measured on 2026-08-13 revise it.

**A backup already exists.** Recovery Services vault `vault712` protects the VM: weekly on
Sundays, 12 weeks retention, GeoRedundant, 12 recovery points present, no disk exclusion. So
uploads were never as exposed as phase 2 assumed — they sit on `sda1`, which is in every
recovery point.

**The machine has three disks, not one.** Phase 2 measured a single block device and killed the
kernel-partition layer (L5) on that basis. Today: `sda1` (30 G) at `/`, `sdb1` (4 G) at `/mnt`
(Azure temp), `sdc1` (30 G) at `/backup`. That does not revive L5 — `/var/lib/docker`, and
therefore both volumes, is still on `sda1` — but the earlier measurement is no longer current
and should not be quoted as if it were.

## Why the vault goes

Thirty days of billing, by resource, in USD:

| Resource | $/30d |
|---|---|
| `web` (compute) | 17.48 |
| **`vault712`** | **7.48** |
| `mezineudiag680` (diagnostics) | 5.85 → **deleted 2026-08-13** |
| `web-osdisk` | 2.77 |
| `webpublicip` | 2.60 |
| `web-datadisk` (`/backup`) | 1.57 |
| **`eewalxypkl1ft`** (wal-g) | **0.01** |
| Total | 39.60 |

The vault's meter is `Backup - Azure VM Protected Instance - EU West`, $4.83 of it. **That is a
fixed per-instance fee.** Retention, redundancy and disk exclusion do not move it — the only
lever is whether the VM is protected at all. This was established after excluding the data disk
on the assumption it would save money; it did not, and that exclusion stands on hygiene grounds
alone (the vault was snapshotting 11 GB of fsarchiver images weekly — backups of backups).

Meanwhile wal-g ships continuous WAL to blob for **one cent a month**. The two prices are the
argument: 748× the cost for a weekly snapshot.

## What actually needs protecting

Measured on the VM, 2026-08-13:

| Data | Size | Reproducible? | Covered today |
|---|---|---|---|
| Postgres (`encounter_engine_pg_data`) | 97 MB | no | **wal-g**, continuous WAL + daily base |
| Uploads (`encounter_engine_storage`) | 216 KB, will grow | no | vault only (weekly) |
| `/var/www/root` | 1.2 GB | **unknown — see Open questions** | vault only |
| `/opt` | 481 MB | unknown | vault only |
| `/home` | 394 MB | unknown | vault only |
| `/root` | 59 MB | unknown | vault only |
| `/etc`, systemd units, `/usr/local/bin/*` | 16 MB | partly (units are ours) | vault only |
| Let's Encrypt (`mezin.by`) | small | yes — reissuable | vault only |
| OS, Docker, packages | ~15 GB | **yes** — `kamal setup` from CI | vault |
| `/backup/*.fsa` | 11 GB | n/a — they *are* backups | excluded 2026-08-13 |

**Roughly 2.2 GB is genuinely irreplaceable**, excluding the database. Everything else the vault
stores is either rebuildable or is itself a backup.

Note the VM is not exclusively this application: `/var/www` holds `root`, `Keys`, `cache`,
`html`, `parked`, and there is a certificate for `mezin.by`. Kamal rebuilds the app; it rebuilds
none of that.

## Design

One systemd timer, modelled on `encounter-engine-backup.service` — which already proves the
pattern: managed identity, no access key, wal-g's Azure default credential chain fetching
short-lived tokens from IMDS.

**Daily.** `tar` the irreplaceable set — `/var/www`, `/etc`, the uploads volume, the systemd
units and wrapper scripts, `/opt`, `/home`, `/root` — compressed, streamed straight to blob in
`eewalxypkl1ft` under a dated key. No staging file: `/` has 13 GB free and the archive must not
compete with the application for it.

**Quarterly, and after any change to the machine that is not a deploy.** Push an fsarchiver
image offsite. These already exist — the habit is established, the images are simply stored on
`sdc1`, a disk that dies with the VM and is therefore worthless for the event it exists for.
At ~5 GB each that is about **$0.09/month** for bare-metal restore capability.

**Retention by Azure lifecycle policy, not by script.** 14 daily plus 8 weekly for the tar set;
2 images for the fsarchiver set. A deletion rule that lives in the storage account cannot be
skipped by a failing cron, and cannot delete the wrong thing because a variable was empty.

**wal-g:** unchanged.

### Cost

Under **$1/month** against the vault's $7.48, and the uploads RPO improves from 7 days to 1.

### Why not restic

Deduplication and encryption are real advantages, and at 2.2 GB neither pays for what they cost:
a repository password to store and rotate, a binary to keep current, and a second thing that can
be wrong at 03:00. `tar` + a lifecycle policy introduces no new secret, which is the property
`config/deploy.yml` already argues for at length about the storage account key.

## The RPO mismatch, and why it is survivable

Postgres restores to any instant; the uploads restore to the last backup. Restore both and the
database is *newer* than the volume: `game_files` rows exist whose blobs were written after the
last archive.

That is the state design §3 invariant **I3** was written for — "a missing blob is an expected
state, not an exception". The delivery route answers 404 for that one file, logs the blob key and
the ids, and leaves the rest of the level serving. It degrades correctly rather than 500ing
mid-race.

Moving uploads from weekly to daily narrows the window from seven days to one. It does not close
it, and closing it entirely would mean synchronous replication of a Docker volume, which is a
great deal of machinery for a quest platform. **One day is the accepted answer**, recorded here
so a future reader knows it was chosen rather than overlooked.

## What is lost, and what must be true first

Dropping the vault costs the one-click whole-VM restore. Rebuilding becomes: provision → Docker →
`kamal setup` from CI → wal-g restore per `docs/runbooks/restore.md` → untar the state → reissue
certificates. Call it 1–3 hours against roughly 30 minutes.

**Two preconditions, both blocking:**

1. **The rebuild path is written down and rehearsed once.** `docs/runbooks/restore.md` covers the
   database and nothing else. A recovery procedure that has never been executed is a hypothesis.
2. **`/var/www/root` (1.2 GB) and `/var/www/Keys` are inventoried.** Their contents were
   deliberately not read. "Keys" is a directory name that deserves understanding before anyone
   relies on a tarball of it — and if it holds credentials, a plaintext archive in blob storage is
   the wrong destination for it.

Until both hold, keep paying the $7.48. It buys a restore path that works without anyone having
practised it, which is precisely what the alternative does not yet have.

## Open questions

1. **What is `/var/www/root`?** 1.2 GB, more than half the irreplaceable set. If it is a site
   with its own source of truth, it may not need backing up at all.
2. **What is `/var/www/Keys`?** 28 KB. Governs whether the archive needs encryption.
3. **Is `/opt` (481 MB) reproducible?** Package-managed content does not need archiving.
4. **Do the wal-g container and the vault share a failure domain?** Both are in West Europe.
   `eewalxypkl1ft` is `Standard_LRS` — single region, three replicas. The vault is GeoRedundant.
   Moving to daily blob archives therefore *reduces* geographic redundancy unless the account is
   changed to GRS, which roughly doubles its storage cost — from approximately nothing to
   approximately nothing. **Recommend GRS**, and note this is the one place the vault is
   currently better.

## Rejected alternatives

**Tune the vault down.** Not possible: the cost is a fixed protected-instance fee. Measured,
not assumed.

**Keep the vault and add the daily job.** Correct on every axis except price, and price is the
reason this document exists. Worth reconsidering if the preconditions above prove expensive.

**Back up the whole filesystem to blob.** ~17 GB per copy for ~2.2 GB of information, most of it
reconstructible by CI in minutes. The fsarchiver images cover the bare-metal case at quarterly
cadence for a fraction of the storage.

**Azure Files or a second managed disk.** A disk attached to the VM shares the VM's fate — the
existing `/backup` disk demonstrates exactly this failure.
