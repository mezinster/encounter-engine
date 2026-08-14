# Restoring the database

For someone under pressure who did not build this. Commands are copy-pasteable.
Read §0 before typing anything.

**Rehearsed 2026-08-07** — both a `latest` restore and a point-in-time restore
to `2026-08-06 09:00:00+00` were performed into a scratch container and
verified. The point-in-time restore correctly omitted a game created at
`2026-08-06 10:02:54`.

**Re-rehearsed 2026-08-08, after `ops/db-restore-scratch.sh` changed.** The
script stopped passing `POSTGRES_PASSWORD` on the `docker run` command line
(it was readable by any local process via `/proc/<pid>/cmdline`, on a host we
share with other tenants). The argument that it was safe to remove — `initdb`
never runs because `--entrypoint sleep` replaces the entrypoint, and the later
`psql` calls use the local socket, where libpq reads `PGPASSWORD` and never
`POSTGRES_PASSWORD` — was reasoning, not evidence, until this run. A `latest`
restore now completes end to end: WAL replayed through
`000000010000000000000060`, promotion reached `still in recovery: f`, and the
row counts printed as **integers rather than `?`**, which is the signal that
proves the psql calls authenticated without it. The cleanup trap removed both
the container and its volume.

Restored state at that moment, for reference: 8 users, 6 teams, 3 games,
75 levels, 0 game_passings, no log rows.

---

## 0. Before you restore anything

**Restoring is not the first move.** It throws away every write since the
target instant. Answer these first:

1. **Is the database actually damaged, or is the app just down?**
   `docker ps` on the host. If `encounter-engine-db` is up and `psql` answers,
   you probably do not want a restore.
2. **Is a game in progress?** A restore erases teams' progress. If one is
   running, say so to the organiser before you act.
3. **How far back do you need?** Get an actual timestamp, not "this morning".
   §2 shows you the window.

**Never restore straight over production.** Restore to a scratch container
first (§3), look at the data, *then* decide. §4 is the production path and it
starts by preserving what is there.

---

## 1. What the system is

| | |
|---|---|
| Database | PostgreSQL 16, Kamal accessory `encounter-engine-db` on `23.100.7.86` |
| Data | Docker volume `encounter_engine_pg_data` |
| Archive tool | wal-g, **inside** the database image (`archive_command` runs as the postgres process, so a host-installed wal-g is unreachable) |
| Archive target | Azure Blob `azure://encounter-engine-wal`, account `eewalxypkl1ft` |
| Auth | VM managed identity via IMDS. **There is no storage key to leak or lose.** |
| WAL | `archive_mode = on`, pushed continuously, `archive_timeout = 300` |
| Base backups | Nightly, host systemd timer `encounter-engine-backup.timer`, 03:00 UTC + up to 15m jitter |
| Backup script | `/usr/local/bin/encounter-engine-backup` on the host — tracked in this repo at `ops/host/` |
| Retention | 7 most recent full backups, plus the WAL they need |

**Worst-case data loss is `archive_timeout`, 5 minutes** — WAL still sitting in
the current segment when the disk died was never pushed.

The schedule lives on the **host**, not in the container, deliberately: Kamal
recreates that container on every deploy, so a crontab inside it would vanish
silently at the next release.

---

## 2. What can I restore, and to when?

**Via the workflow** — Actions → **Database** → Run workflow → `action: list`.
Needs one approval click (the Azure credential is scoped to the `production`
environment).

**Or directly on the host:**

```bash
ssh mezin 'bash -s' < ops/db-list.sh
```

You get the base backups with timestamps, the WAL chain integrity, the restore
window, and paste-ready values for §3.

**Read the WAL chain line.** If it does not say `OK`, point-in-time recovery is
not available and you can only restore to the exact instant of a base backup.

```bash
# the same check on its own
ssh mezin 'docker exec -e PGUSER=encounter -e PGDATABASE=encounter_production \
  encounter-engine-db wal-g wal-verify integrity'
```

---

## 3. Restore into a scratch container (safe — do this first)

Creates a throwaway container with its own volume beside production, restores
into it, prints what it found, and destroys it. **The live database is never
touched.** Safe to run during a game.

**Via the workflow** — Actions → **Database** → Run workflow:

| input | value |
|---|---|
| `action` | `restore-to-scratch` |
| `restore_point` | `latest`, `point_in_time`, or `named_backup` |
| `target_time` | for `point_in_time`, e.g. `2026-08-06 09:00:00+00` |
| `backup_name` | for `named_backup`, e.g. `base_000000010000000000000041` |
| `keep_scratch` | tick to leave it running so you can inspect it |

**Or directly on the host:**

```bash
# newest possible
ssh mezin 'RESTORE_POINT=latest bash -s' < ops/db-restore-scratch.sh

# a specific instant
ssh mezin "RESTORE_POINT=point_in_time TARGET_TIME='2026-08-06 09:00:00+00' bash -s" \
  < ops/db-restore-scratch.sh

# keep it up to poke at
ssh mezin "RESTORE_POINT=point_in_time TARGET_TIME='2026-08-06 09:00:00+00' KEEP_SCRATCH=yes bash -s" \
  < ops/db-restore-scratch.sh
```

**Check the report against what you expected.** It prints row counts and the
newest `created_at` in `users` and `games`. If those are *later* than your
target, the recovery target was not applied — do not proceed to §4.

If you kept the container:

```bash
ssh mezin 'docker ps --filter name=ee-restore-scratch'
ssh mezin 'docker exec -u postgres -it <name> psql -U encounter -d encounter_production'
# when done — BOTH lines, or the volume leaks
ssh mezin 'docker rm -f <name> && docker volume rm <name>-data'
```

---

## 4. Restore over production

**Not automated, on purpose.** No CI workflow can reach this path. Do it by
hand, having read §3's output.

### 4.1 Stop writes

```bash
ssh mezin 'docker stop $(docker ps -q --filter name=encounter-engine-web)'
ssh mezin 'docker ps'          # confirm only the db, proxy and parked remain
```

### 4.2 Preserve what is there — do not skip this

The current data may be your only copy of writes made since the last base
backup. A restore overwrites it.

```bash
ssh mezin 'docker stop encounter-engine-db'
ssh mezin 'docker run --rm \
  -v encounter_engine_pg_data:/from \
  -v /var/backups:/to \
  alpine tar czf /to/pg_data_before_restore_$(date -u +%Y%m%dT%H%M%SZ).tgz -C /from .'
ssh mezin 'ls -lh /var/backups/pg_data_before_restore_*'
```

### 4.3 Restore into a fresh volume

Into a **new** volume, not over the old one, so §4.2's copy is not the only way
back.

```bash
ssh mezin 'docker volume create encounter_engine_pg_data_restored'

# choose ONE of these for BACKUP_SPEC:
#   LATEST                          newest base backup
#   base_0000000100000000000000NN   a specific one (from §2)
#
# For point-in-time, pick the newest base backup taken BEFORE your target —
# wal-g's backup-fetch has NO --target-time flag; recovery_target_time below
# is what stops the replay.

ssh mezin 'docker run -d --name ee-restore \
  -v encounter_engine_pg_data_restored:/var/lib/postgresql/data \
  -e PGUSER=encounter -e PGDATABASE=encounter_production \
  -e WALG_AZ_PREFIX=azure://encounter-engine-wal \
  -e AZURE_STORAGE_ACCOUNT=eewalxypkl1ft \
  --entrypoint sleep \
  ghcr.io/mezinster/encounter-engine-postgres:latest infinity'

ssh mezin 'docker exec ee-restore wal-g backup-fetch /var/lib/postgresql/data LATEST'
```

Configure recovery. **`archive_mode = off` is not optional** — a recovering
cluster left archiving pushes its own divergent timeline into the same Azure
prefix and corrupts the archive you are restoring from:

```bash
ssh mezin "docker exec ee-restore bash -c \"cat > /var/lib/postgresql/data/postgresql.auto.conf <<'CONF'
archive_mode = off
restore_command = 'wal-g wal-fetch %f %p'
recovery_target_action = 'promote'
CONF\""

# point-in-time only — append your target
ssh mezin "docker exec ee-restore bash -c \\
  \\\"echo \\\\\\\"recovery_target_time = '2026-08-06 09:00:00+00'\\\\\\\" >> /var/lib/postgresql/data/postgresql.auto.conf\\\""

ssh mezin 'docker exec ee-restore bash -c "touch /var/lib/postgresql/data/recovery.signal && \
  chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data"'

ssh mezin 'docker exec -u postgres ee-restore \
  pg_ctl -D /var/lib/postgresql/data -o "-c config_file=/usr/share/postgresql/postgresql.conf.sample" -w -t 300 start'
```

Verify **before** swapping:

```bash
ssh mezin "docker exec -u postgres ee-restore psql -U encounter -d encounter_production -c '
  SELECT pg_is_in_recovery() AS still_recovering,
         (SELECT count(*) FROM users) AS users,
         (SELECT count(*) FROM games) AS games,
         (SELECT max(created_at) FROM games) AS newest_game;'"
```

`still_recovering` must be `f` and the timestamps must match your target. If
not, **stop** — §4.2's archive is intact and nothing has been swapped yet.

### 4.4 Swap the volume in

```bash
ssh mezin 'docker stop ee-restore && docker rm ee-restore'
ssh mezin 'docker volume rm encounter_engine_pg_data'
ssh mezin 'docker volume create encounter_engine_pg_data'
ssh mezin 'docker run --rm \
  -v encounter_engine_pg_data_restored:/from \
  -v encounter_engine_pg_data:/to \
  alpine sh -c "cd /from && cp -a . /to/"'
```

### 4.5 Bring it back up

```bash
cd /path/to/encounter-engine
bundle exec kamal accessory boot db
bundle exec kamal deploy
curl -sS -o /dev/null -w '%{http_code}\n' https://game.mezin.eu/up   # expect 200
```

### 4.6 Afterwards

```bash
# take a base backup immediately — the restored cluster is a new timeline
ssh mezin '/usr/local/bin/encounter-engine-backup'

# keep the pre-restore copies until you are certain; then
ssh mezin 'docker volume rm encounter_engine_pg_data_restored'
ssh mezin 'ls /var/backups/pg_data_before_restore_*'
```

---

## 5. Things that will bite you

**`role "root" does not exist`** — `docker exec` runs as root, so libpq defaults
`PGUSER` to `root`. Every wal-g command that talks to the database needs
`-e PGUSER=encounter -e PGDATABASE=encounter_production`. WAL *archiving* keeps
working without it, because `wal-g wal-push` needs no connection — which is
exactly how this system once looked healthy for hours while being unable to
restore anything.

**`unknown flag: --target-time`** — `wal-g backup-fetch` has no such flag in
v3.0.3. Choose the base backup yourself: the newest one at or before your
target. `recovery_target_time` does the rest.

**The scratch container must not archive.** See §4.3. `ops/db-restore-scratch.sh`
sets `archive_mode = off` for you; a hand-rolled restore must too.

**Backups stop silently.** Nothing alerts if the timer fails. Check it:

```bash
ssh mezin 'systemctl status encounter-engine-backup.timer'
ssh mezin 'systemctl list-timers encounter-engine-backup.timer'
ssh mezin 'journalctl -u encounter-engine-backup.service -n 40 --no-pager'
```

The same is true of the offsite archive timer, and it has no `OnFailure=` either — check it the
same way:

```bash
ssh mezin 'systemctl status encounter-engine-archive.timer'
ssh mezin 'systemctl list-timers encounter-engine-archive.timer'
ssh mezin 'journalctl -u encounter-engine-archive.service -n 40 --no-pager'
```

**A backup list is not a working backup.** Only a rehearsed restore proves
recoverability. Re-run §3 after any change to the database image, wal-g, or the
storage account — it costs a few minutes and needs no downtime.

---

## 6. Reinstalling the schedule on a rebuilt host

Beyond the units and script below, a rebuilt host also needs:

- `age` (`apt-get install -y age`) — required to decrypt any archive written after 2026-08-14.
- `azcopy` (`https://aka.ms/downloadazcopy-v10-linux`, installed to `/usr/local/bin`) — the
  archive scripts' only route to blob storage. wal-g does not use it and does not install it.

Both `encounter-engine-archive` and `archive-verify.sh` read `AZURE_STORAGE_ACCOUNT` off the
**`encounter-engine-db`** container, and the daily archive also reads the **`encounter_engine_storage`**
Docker volume — neither exists on a freshly rebuilt host. Starting the archive service therefore
has to wait until **after** `kamal deploy` has brought the app up, not before, even though the
commands below look independent of it.

The units and script are tracked at `ops/host/`:

```bash
scp ops/host/encounter-engine-backup mezin:/tmp/
ssh mezin 'sudo install -m 755 /tmp/encounter-engine-backup /usr/local/bin/encounter-engine-backup'
scp ops/host/encounter-engine-backup.{service,timer} mezin:/tmp/
ssh mezin 'sudo install -m 644 /tmp/encounter-engine-backup.service /tmp/encounter-engine-backup.timer /etc/systemd/system/'
ssh mezin 'sudo systemctl daemon-reload && sudo systemctl enable --now encounter-engine-backup.timer'
ssh mezin 'sudo systemctl start encounter-engine-backup.service && journalctl -u encounter-engine-backup.service -n 20 --no-pager'
```

The offsite archive script, unit and timer are tracked the same way, at `ops/host/`, and need
installing too — a rebuild that stops here gets the Postgres schedule back with no host-state
archive, and nothing says so:

```bash
scp ops/host/encounter-engine-archive mezin:/tmp/
ssh mezin 'sudo install -m 755 /tmp/encounter-engine-archive /usr/local/bin/encounter-engine-archive'
scp ops/host/encounter-engine-archive.{service,timer} mezin:/tmp/
ssh mezin 'sudo install -m 644 /tmp/encounter-engine-archive.service /tmp/encounter-engine-archive.timer /etc/systemd/system/'
ssh mezin 'sudo systemctl daemon-reload && sudo systemctl enable --now encounter-engine-archive.timer'
ssh mezin 'sudo systemctl start encounter-engine-archive.service && journalctl -u encounter-engine-archive.service -n 20 --no-pager'
```

It also needs `/etc/encounter-engine/archive-recipients.txt` back in place before that last command
can succeed — see §7.

---

## 7. Retrieving and decrypting an archive

Archives written after 2026-08-14 are encrypted with `age` to two recipients. The host holds
only the public keys (`/etc/encounter-engine/archive-recipients.txt`) and cannot read what it
writes. Everything in this section is done **on a laptop that holds a private key**, not on the
VM — and it must work when the VM no longer exists, which is what this whole system is for.

| Key | Held where |
|---|---|
| primary | <fill in: password manager entry name> |
| secondary | <fill in: must survive losing both the VM and the laptop> |

**Where the archives are.** Storage account `eewalxypkl1ft`, two containers:

| Container | Blob | Written by |
|---|---|---|
| `archive-daily` | `<YYYY-MM-DD>/host-state.tar.zst.age` | `encounter-engine-archive`, daily |
| `archive-once` | `2026-08-14/<name>.age` — see §8 for the four names | `ops/archive-once.sh`, once |

The account name is **also** in `config/deploy.yml` (`AZURE_STORAGE_ACCOUNT`, under the `db`
accessory). Read it from there, not from the `encounter-engine-db` container: `ops/` scripts read
it off that container because they run beside it, but the disaster this section is written for is
the one where that container — and the host under it — is gone.

**Retrieve, decrypt, unpack.**

```bash
az login                                # an account with Storage Blob Data Reader on the account
export AZCOPY_AUTO_LOGIN_TYPE=AZCLI     # azcopy does NOT use the az CLI token unless told to
azcopy list "https://eewalxypkl1ft.blob.core.windows.net/archive-daily/"   # pick a date
azcopy copy "https://eewalxypkl1ft.blob.core.windows.net/archive-daily/2026-08-14/host-state.tar.zst.age" .
age -d -i <private key file> host-state.tar.zst.age > host-state.tar.zst
tar --zstd -xf host-state.tar.zst
```

Keep the `export`. AzCopy does not pick up an Azure CLI session implicitly, so without it every
command above fails on authorization even though `az login` succeeded — and it fails in the one
section written for the case where the VM is gone. (`AZCOPY_AUTO_LOGIN_TYPE` is azcopy 10.22+; the
host uses the same variable with `MSI` instead, from
`ops/host/encounter-engine-archive.service`.)

That unpacks to the paths as they were on the host, relative to the current directory:

- `var/www/Keys` — three private keys
- `etc/ssh` — all four host key pairs, and `sshd_config`
- `etc/letsencrypt`
- `etc/ddclient.conf` — contains the dynamic-DNS credentials
- `etc/encounter-engine/archive-recipients.txt` — the age recipients file (see below)
- `etc/systemd/system/` — `encounter-engine-backup.{service,timer}`,
  `encounter-engine-archive.{service,timer}`, `ddclient.service`
- `usr/local/bin/` — `encounter-engine-backup`, `encounter-engine-archive`
- `etc/crontab`, `etc/cron.d`, `etc/fstab`, `etc/hosts`
- `uploads/` — the `encounter_engine_storage` Docker volume

Unpack into an empty directory and copy out what you need — do not extract over `/`.

The one-off archive works identically; only the container, prefix and blob names differ (§8).

**Getting `/etc/encounter-engine/archive-recipients.txt` back** (needed by §6 after a rebuild,
before the archive service can start): **it is inside the archive** — `etc/encounter-engine/archive-recipients.txt`
in the listing above. If you have unpacked any daily archive, copy it out and you are done. It is
public keys, not a secret, which is why it is in the tar at all.

Reconstruct it by hand only when you have the private keys but no archive to unpack yet — a
first-ever run, or a loss of every blob. Format: one `age1…` public recipient per line, plain
text. The scripts require **two distinct recipients**, not two lines: they strip carriage returns
and trailing whitespace and then de-duplicate, so the same key entered twice is counted once and
refused. Recover each public recipient from its private key rather than trying to remember it:

    age-keygen -y <private key file>

Run that against both the primary and secondary private keys above and put both `age1…` outputs,
one per line, into the file.

---

## 8. The one-off archive (the frozen WordPress estate)

> **NOT YET EXECUTED.** Nothing in this section has happened; `ops/archive-once.sh` has never run.
> Everything below, including the opening sentence, describes what this section will record once
> it has, not anything that is true yet — do not cite it as current.

Written once to `archive-once/2026-08-14/`. Never updated, never expires — the lifecycle rule
applies only to `archive-daily/`. Nothing regenerates these.

| Blob | sha256 (ciphertext) |
|---|---|
| `wordpress-tree.tar.zst.age` | <fill in> |
| `mysql-datadir.tar.zst.age` | <fill in> |
| `home-mezinster.tar.zst.age` | <fill in> |
| `system-2026-08-04.fsa.age` | <fill in> |

The MySQL copy is meant to be taken cold (server stopped since 2026-08-04) and, once
`ops/archive-once.sh` has actually run, verified by restoring it into a throwaway `mysql:8`
container and counting `wordpress.wp_posts` — see the offsite-backup plan, Task 5 Step 5. The
fsarchiver image is a bare-metal image of the OS only: it predates the MySQL shutdown by
fifteen hours, so the database inside it is torn. Use `mysql-datadir.tar.zst.age` for the
database, always, once it exists.
