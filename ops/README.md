# ops/

Operational scripts for the production host, kept here so they are reviewable,
diffable and recoverable. Nothing in this directory is loaded by the Rails app.

| | |
|---|---|
| `db-list.sh` | Read-only. What can be restored, and to when. Safe during a game. |
| `db-restore-scratch.sh` | Restores into a throwaway container beside production and destroys it. Never touches the live database. |
| `host/` | Files that live on the host outside Docker (see below). |

Both scripts run **on the host** and are piped over ssh:

```bash
ssh mezin 'bash -s' < ops/db-list.sh
```

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

They are on the **host** rather than in the database container on purpose:
Kamal recreates that container on every deploy, so a crontab installed inside
it would disappear at the next release — and a backup schedule that stops
without telling you is worse than none.

Reinstalling on a rebuilt host: `docs/runbooks/restore.md` §6.

**These are copies, not the live files.** After editing anything here, install
it and diff to confirm:

```bash
ssh mezin 'cat /usr/local/bin/encounter-engine-backup' | diff - ops/host/encounter-engine-backup
```
