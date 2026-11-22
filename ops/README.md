# ops/

Operational scripts for the production host, kept here so they are reviewable,
diffable and recoverable. Nothing in this directory is loaded by the Rails app.

| | |
|---|---|
| `db-list.sh` | Read-only. What can be restored, and to when. Safe during a game. |
| `db-restore-scratch.sh` | Restores into a throwaway container beside production and destroys it. Never touches the live database. |
| `archive-verify.sh` | Read-only. What has been archived and when. Safe during a game. |
| `archive-once.sh` | Run ONCE, by hand. Archives the frozen WordPress estate. Refuses to run if MySQL is up. |
| `host/` | Files that live on the host outside Docker (see below). |

These scripts run **on the host** and are piped over ssh:

```bash
ssh mezin 'bash -s' < ops/db-list.sh
ssh mezin 'sudo bash -s' < ops/archive-once.sh   # this one needs root
```

`archive-once.sh` is the exception that needs `sudo`: it reads `/var/lib/mysql`
(mode 0700) and stages gigabytes on `/backup`. Without it the script stops on
its own root check rather than failing later as something that looks like a
disk problem.

**Anything added here that calls `azcopy` must redirect its stdin.** `bash -s`
reads the script *from stdin*, and **`azcopy` consumes stdin** — so the first
`azcopy` call swallows the remainder of the script, bash reaches end-of-input,
and the run **exits 0 having done part of the work**. This is not hypothetical:
the first real run of `archive-once.sh` archived one of its four items and
reported success, with a genuine digest and a correctly-sized blob in the right
container. Nothing looked wrong except a log that stopped early, which on an
unattended run nobody reads.

Both scripts now pass `</dev/null` on every `azcopy` invocation, so the pattern
above is safe again. Keep it that way: the alternative — "copy the script to the
host and run it as a file" — makes correctness depend on how someone happens to
invoke it, and this file documents the other way.

The `Database` GitHub Actions workflow does exactly that. Running them by hand
and running them through the workflow execute the same code — which is the
point of keeping the logic here rather than inline in the YAML.

Restoring **over** production is deliberately not scripted. See
`docs/runbooks/restore.md` §4.

## host/

These are installed on the VM, outside any container, and were previously
untracked — they existed only on the host, so a rebuilt VM would have lost the
backup schedule with no record of what it had been.

| | installed to |
|---|---|
| `encounter-engine-backup` | `/usr/local/bin/encounter-engine-backup` (mode 755, root) |
| `encounter-engine-backup.service` | `/etc/systemd/system/` |
| `encounter-engine-backup.timer` | `/etc/systemd/system/` |
| `encounter-engine-archive` | `/usr/local/bin/encounter-engine-archive` (mode 755, root) |
| `encounter-engine-archive.service` | `/etc/systemd/system/` |
| `encounter-engine-archive.timer` | `/etc/systemd/system/` |
| `encounter-engine-patch-health` | `/usr/local/bin/encounter-engine-patch-health` (mode 755, root) |
| `encounter-engine-patch-health.service` | `/etc/systemd/system/` |
| `encounter-engine-patch-health.timer` | `/etc/systemd/system/` |

They are on the **host** rather than in the database container on purpose:
Kamal recreates that container on every deploy, so a crontab installed inside
it would disappear at the next release — and a backup schedule that stops
without telling you is worse than none.

Reinstalling on a rebuilt host: `docs/runbooks/restore.md` §6.

**`encounter-engine-patch-health`** reports on OS patching and decides nothing.
Every day at 08:10 it writes `patch-health/<hostname>.json` to the WAL storage
account. The contents are `dpkg --audit`, when apt last updated successfully,
pending `-security` upgrades with the date each was first seen, how long a
reboot has been pending, and the last unattended-upgrades run. It never takes
the apt or dpkg lock. `.github/workflows/patch-health.yml` reads the report
every day at 09:37 with the read-only `ee-vmscale-reader-oidc` identity, runs
`ops/patchhealth/policy.rb`, and files a `patch-health` issue when anything is
unhealthy, including a report that is missing or more than 30 hours old. It was
added after unattended-upgrades installed nothing for four weeks (2026-10-25 to
2026-11-21) behind a green systemd unit.

Azure setup it depends on, done by hand on 2026-11-22 and not in any template:
the private `patch-health` container on `eewalxypkl1ft`, and **Storage Blob
Data Reader for `ee-vmscale-reader-oidc`, scoped to that container only**.
Container scope, not account scope: the WAL archive is in the same account.
The VM's own identity already had Blob Data Contributor on the account, for
wal-g. To recreate the grant:

```bash
az storage container-rm create --storage-account eewalxypkl1ft -g mezineu -n patch-health --public-access off
az role assignment create --role "Storage Blob Data Reader" --assignee-principal-type ServicePrincipal \
  --assignee-object-id "$(az identity show -g MEZINEU -n ee-vmscale-reader-oidc --query principalId -o tsv)" \
  --scope "$(az storage account show -n eewalxypkl1ft --query id -o tsv)/blobServices/default/containers/patch-health"
```

**These are copies, not the live files.** After editing anything here, install
it and diff to confirm:

```bash
ssh mezin 'cat /usr/local/bin/encounter-engine-backup' | diff - ops/host/encounter-engine-backup
```
