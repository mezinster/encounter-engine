# Offsite backup — replacing Azure VM Backup

**Status:** approved design, ready for an implementation plan
**Date:** 2026-08-13, **substantially revised 2026-08-14** after measuring the VM (see
*What the measurements changed*)
**Supersedes:** the `azcopy sync` sketch in §3/§8 of
`docs/superpowers/specs/2026-08-12-level-and-hint-attachments-design.md` (phase 4)
**Related:** `docs/runbooks/restore.md` (database only), `config/deploy.yml`,
`.github/workflows/deploy.yml` (`setup` mode)

## Goal

Protect everything on the production VM that cannot be rebuilt, at a cost proportionate to
what it is worth, and retire the Azure Backup vault — whose price cannot be tuned down.

## What the measurements changed

The 2026-08-13 draft was written from a partial inventory and left four open questions. All
four were measured on the VM on 2026-08-14. Three of the answers change the design, and one
of them is a gap rather than a refinement.

**There is a second database, and the draft did not mention it.** `/var/lib/mysql` is 357 MB,
database `wordpress` on `127.0.0.1:3306`, referenced by `/var/www/root/wp-config.php`. A
WordPress site's content — posts, pages, users, settings — lives there and not on disk, so the
draft's plan (archive `/var/www/root`, say nothing about MySQL) would have restored an **empty**
WordPress site while reporting success. This is the single reason the draft could not have been
implemented as written.

**The WordPress estate is switched off, deliberately.** No `mysql`/`mariadb` unit, nothing
listening on 3306, and the newest file under `/var/lib/mysql` is dated **2026-08-04 21:36**.
Host `apache2` and `nginx` are both inactive; the only nginx container (`parked`, `nginx:alpine`)
mounts exactly one thing — `/var/www/parked` → `/usr/share/nginx/html`, read-only, 5.5 KB, one
file — and has no port bindings. MySQL and WordPress were stopped to free CPU and memory for
this application. Open question 1 asked what `/var/www/root` is; the answer is *a site that is
no longer running*, which is a stronger answer than the draft anticipated.

**`/opt` and `/home` are largely reproducible.** `/opt` is 473 MB of which 435 MB is
`/opt/microsoft` (the Azure monitoring agent) and 39 MB is `/opt/eff.org` (certbot) — both
reinstallable, answering open question 3. `/home/mezinster` is 348 MB dominated by a 154 MB
omsagent installer, 99 MB of Let's Encrypt material (reissuable), a 39 MB scratch directory and
a 33 MB PDF.

**`/var/www/Keys` is three private keys** — `id_ecdsa` (OpenSSH), `id_rsa2_512` (OpenSSH RSA)
and `wp_rsa` (PEM RSA), each with its public half; 6 files, 12 KB, `wp-user:www-data`, mode
`0640`, untouched since November 2022. Only names, sizes and `file(1)` types were read;
contents deliberately were not. This settles open question 2 in the direction that requires
encryption (see *Encryption* below).

It is **not** web-exposed: `Keys` is a sibling of the DocumentRoots (`/var/www/root`,
`/var/www/Cloudlog`, `/var/www/html`), not inside any of them, and both host web servers are
inactive in any case.

**The wal-g backup is genuinely healthy**, which the draft assumed rather than checked.
`encounter-engine-backup.timer` is enabled and active, the last run finished `Result=success` at
`2026-08-14 03:12:50 UTC`, daily base backups are present through `2026-08-14`, and the next run
is scheduled. Nothing in this design touches it.

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

Measured on the VM, 2026-08-14. Disks: `sda1` 30 G at `/` (17 G used), `sdb1` 3.9 G at `/mnt`
(Azure temp, excluded), `sdc1` 30 G at `/backup` (11 G used).

| Data | Size | Reproducible? | Tier |
|---|---|---|---|
| Postgres (`encounter_engine_pg_data`) | 100 MB | no | **wal-g**, continuous WAL + daily base — unchanged |
| Uploads (`encounter_engine_storage`) | 851 KB, will grow | no | **daily** |
| `/var/www/Keys` | 12 KB | no — three private keys | **daily** |
| Our systemd units + the wal-g wrapper | small | no | **daily** |
| `/etc/ddclient.conf`, ssh host keys, letsencrypt, cron, fstab | ~2 MB | no | **daily** (enumerated below) |
| `/var/lib/mysql` (dormant `wordpress` DB) | 357 MB | no | **archive, once** |
| `/var/www/root` (WordPress + Cloudlog) | 1.2 GB | partly — core is | **archive, once** |
| `/home/mezinster` | 348 MB | mostly | **archive, once** |
| `system-2026-08-04.fsa` | 5.1 GB | n/a | **archive, once** |
| `/opt` | 473 MB | **yes** — omsagent, certbot | not backed up |
| Other home directories | 30 MB | mostly | not backed up |
| WordPress core (`wp-includes`, `wp-admin`) | 70 MB | **yes** — reinstallable | archived only as part of the tree |
| OS, Docker images, other volumes | ~15 GB | **yes** — `kamal setup` from CI | not backed up |
| `/backup/*.fsa` beyond the one image | 5 GB | n/a — they *are* backups | not backed up |

The live, changing set is **single-digit megabytes**. Everything large is either frozen, itself
a backup, or rebuilt by CI.

## Design

Two mechanisms, not the draft's daily-tar-plus-quarterly-image. Both modelled on
`encounter-engine-backup.service`, which already proves the pattern: managed identity, no access
key, short-lived tokens from IMDS.

### Tier 1 — the archive, written once and never updated

`/var/www/root`, `/var/lib/mysql`, `/home/mezinster`, and `/backup/system-2026-08-04.fsa`
pushed to blob under a dated prefix. About 7 GB, **Cool** tier, encrypted, and with **no
lifecycle expiry rule** — this copy must not age out.

Three reasons it is one-off rather than recurring:

**The estate is frozen.** MySQL and WordPress are stopped by choice. A daily copy of data that
cannot change is 1.5 GB of transfer a day to reproduce a byte-identical blob.

**A cold MySQL copy is trustworthy, and only while it stays cold.** With the server stopped,
copying `/var/lib/mysql` at file level yields a consistent database. The moment it is started
again that stops being true — a live InnoDB directory copies torn — and any recurring job would
need `mysqldump` instead. Taking the copy in the current state avoids needing that machinery at
all. **If MySQL is ever restarted, this decision expires**; add a dump step before archiving it
again.

**The fsarchiver image already on the box is not a substitute for that.**
`system-2026-08-04.fsa` was written at 06:11 on 4 August; MySQL's last write was 21:36 the same
evening. The image predates the shutdown by fifteen hours, so the database inside it was
captured live — the torn copy this design is avoiding. It is sound as a bare-metal image of the
OS and is archived on that basis; it is not a source for the WordPress database.

It also replaces the draft's *quarterly* fsarchiver job. A machine whose extra services are
switched off, and whose application is rebuilt from CI, does not drift enough between quarters
to justify a recurring image. One push of the image that exists covers the bare-metal case, and
that image is currently stored on `sdc1` — a disk that dies with the VM, and therefore worthless
for the only event it exists for.

### Tier 2 — daily

Compressed, encrypted, uploaded under a dated key. The set, enumerated rather than described,
because "host config" is not something an implementation can act on:

| Path | Size | Why |
|---|---|---|
| `encounter_engine_storage` volume | 851 KB, grows | author uploads; the whole point |
| `/var/www/Keys` | 12 KB | three private keys |
| `/etc/systemd/system/encounter-engine-backup.{service,timer}` | small | ours; the wal-g job |
| `/etc/systemd/system/ddclient.service` | small | ours |
| `/usr/local/bin/encounter-engine-backup` | 2 KB | the wal-g wrapper the unit runs |
| `/etc/ddclient.conf` | 309 B | dynamic-DNS credentials — not regenerable |
| `/etc/ssh/ssh_host_*_key` | 4 keys | the box's identity; losing them changes its fingerprint |
| `/etc/letsencrypt` | 1.7 MB | `mezin.by`; reissuable, but cheap and avoids rate limits |
| `/etc/crontab`, `/etc/cron.d` | ~1 KB | `certbot`, `php` and others, hand-installed |
| `/etc/fstab`, `/etc/hosts` | ~600 B | three-disk layout is not obvious from a fresh image |

The rest of `/etc/systemd/system` is stock Ubuntu and snap units. `/root/.docker/config.json`
does not exist on this host, so there is no registry credential to archive — Kamal authenticates
from CI. `kamal-proxy-config` (69 KB) is deliberately excluded: `config/deploy.yml` documents
that the proxy rebuilds its whole route table from that file on every deploy, so archiving it
would preserve a copy of something CI regenerates.

Note `/usr/local/bin/encounter-engine-backup.bak-20260807` sitting beside the live wrapper. Not
archived; noticed here because a `.bak` file next to a production script is worth resolving
rather than backing up.

**Staged and verified, not streamed.** The draft streamed `tar` straight to blob with no staging
file, reasoning that "`/` has 13 GB free and the archive must not compete with the application
for it". At single-digit megabytes that constraint is gone, and streaming costs something real:
a truncated or corrupt archive uploads and is indistinguishable from a good one — the timer
succeeds, the blob exists, its size is plausible. So: write locally, checksum, upload, read back,
compare, then delete the local copy. Fail loudly on mismatch.

This is the draft's own standard applied to itself. It blocks on rehearsing a restore because
"a recovery procedure that has never been executed is a hypothesis"; a backup that has never
been read back is the same claim about the same evidence.

**Retention: 90 daily.** The draft proposed 14 daily plus 8 weekly, which was a cost compromise
at 2.2 GB per copy and quietly shortened retention from the vault's 12 weeks. At this size the
compromise has no purchase — 90 copies of a few megabytes is pennies — and there is no reason to
retain less than the thing being replaced.

**By Azure lifecycle policy, not by script.** A deletion rule that lives in the storage account
cannot be skipped by a failing timer, and cannot delete the wrong thing because a variable was
empty.

### Encryption

Both tiers, with `age`, **public key only on the VM**.

Not optional, and not contingent: tier 2 contains three private keys by definition, and tier 1
contains `wp-config.php` (database credentials) and a MySQL data directory (user password
hashes). An unencrypted archive is an offsite copy of the machine's credentials, held under
different access controls from the machine. The vault being replaced never had that property,
because it was never a fetchable tarball.

Asymmetric rather than a repository password (which is what restic would need): the VM can write
backups it cannot read, nothing on the host needs rotating, and a compromised VM leaks its
current state but not its history. This preserves the "no new secret on the machine" property
the draft claimed for plain `tar` — a claim that stopped being true once the payload contained
credentials.

**Encrypt to two recipients.** `age` accepts several `-r` flags. One private key turns "key lost"
into "every backup is worthless", which is a worse failure than the one being fixed. One key held
by the operator, one kept offline.

**The rehearsal must include decrypting.** Otherwise this adds a cryptographic step to a recovery
path in exactly the place untested procedures fail.

### Storage account

**Change `eewalxypkl1ft` to GRS.** It is `Standard_LRS` today — single region, three replicas —
while the vault is GeoRedundant. The disaster this design exists for is losing the VM, and the
largest form of that is losing the region: as written, the replacement is *worse than the vault
at its own job*. The draft noted this and left it in Open Questions, which is where it would have
been lost. Roughly doubles the storage cost, from approximately nothing to approximately nothing.

### Cost

Tier 1 about 7 GB at Cool, tier 2 90 copies of a few megabytes, both after the GRS doubling:
comfortably under **$1/month** against the vault's $7.48. Uploads move from a seven-day RPO to
one day.

## The RPO mismatch, and why it is survivable

Postgres restores to any instant; the uploads restore to the last daily archive. Restore both
and the database is *newer* than the volume: `game_files` rows exist whose blobs were written
after the last archive.

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
`kamal setup` from CI → wal-g restore per `docs/runbooks/restore.md` → decrypt and untar the
daily archive → reissue certificates. Call it 1–3 hours against roughly 30 minutes.

**One precondition, blocking:**

**The rebuild path is written down and rehearsed once, decryption included.**
`docs/runbooks/restore.md` covers the database and nothing else. A recovery procedure that has
never been executed is a hypothesis, and this design adds a decryption step to it.

The draft carried a second precondition — inventory `/var/www/root` and `/var/www/Keys` — which
the 2026-08-14 measurements discharge.

Until the rehearsal holds, keep paying the $7.48. It buys a restore path that works without
anyone having practised it, which is precisely what the alternative does not yet have.

## Open questions

The draft's four are answered above. What remains:

1. **Does `/var/www/root` need to come back at all?** It is archived once either way, but if the
   site is retired for good rather than paused, the tier 1 copy is the last thing anyone ever
   needs from it — which is an argument for verifying that archive particularly carefully, since
   nothing will ever regenerate it.
2. **Where does the second `age` recipient live?** It has to survive the loss of both the VM and
   the operator's laptop, or it is not a second recipient in any useful sense.

## Rejected alternatives

**Tune the vault down.** Not possible: the cost is a fixed protected-instance fee. Measured,
not assumed.

**Keep the vault and add the daily job.** Correct on every axis except price, and price is the
reason this document exists. Worth reconsidering if the rehearsal proves expensive.

**Back up the whole filesystem daily.** ~17 GB per copy for single-digit megabytes of changing
information, most of the rest reconstructible by CI in minutes.

**A recurring fsarchiver job** (the draft's quarterly proposal). The estate it would capture is
frozen; one push of the existing image covers it. Revisit if services are turned back on.

**restic.** Deduplication and encryption are real advantages, and at this size dedup buys
nothing. Its encryption needs a repository password stored on the VM; `age` with a public key
needs no secret there at all, which is strictly better for the same property.

**Azure Files or a second managed disk.** A disk attached to the VM shares the VM's fate — the
existing `/backup` disk, holding the only fsarchiver images, demonstrates exactly this.
