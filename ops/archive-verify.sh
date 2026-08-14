#!/bin/bash
# Read-only. What was archived, and when. Safe to run during a game.
#
# Does NOT decrypt -- the host holds no private key, by design. This answers
# "is the daily job still producing archives of a plausible size", which is the
# question a silent failure makes urgent. Decrypting is a laptop operation:
# see docs/runbooks/restore.md §7.
set -euo pipefail

# AZURE_STORAGE_ACCOUNT lives on the encounter-engine-db container's
# environment, not on the encounter-engine-backup systemd unit -- see
# ops/db-restore-scratch.sh, which reads it the same way. `docker inspect`
# works on a stopped container too (only a removed one fails), which matters
# here: this is the read-only diagnostic tool, so it is the one most likely to
# be run when something is already broken, and it should keep answering for as
# long as there is anything left to inspect.
DB_CONTAINER=encounter-engine-db
env_of() { docker inspect "$DB_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^$1=" | head -1 | cut -d= -f2-; }
# The `|| true` matters: under pipefail, env_of's internal grep exits 1 when
# nothing matches, which would otherwise fail this assignment and terminate
# the script here -- before the FATAL message below ever runs.
ACCT=$(env_of AZURE_STORAGE_ACCOUNT) || true
if [ -z "$ACCT" ]; then
  echo "FATAL: could not read AZURE_STORAGE_ACCOUNT off the ${DB_CONTAINER} container" >&2
  echo "       (it needs to exist, even stopped, for docker inspect to see it)" >&2
  exit 1
fi

azcopy login --identity >/dev/null
echo "daily archives (newest last):"
azcopy list "https://${ACCT}.blob.core.windows.net/archive-daily/" --output-type text \
  | grep -E 'host-state\.tar\.zst\.age' | tail -10 \
  || echo "NO DAILY ARCHIVES FOUND -- the timer has never succeeded"

echo
echo "one-off archive:"
azcopy list "https://${ACCT}.blob.core.windows.net/archive-once/" --output-type text | tail -10 \
  || echo "NO ONE-OFF ARCHIVE FOUND -- ops/archive-once.sh has not run yet"
