#!/bin/bash
# What can we restore, and to when?
#
# Read-only. Touches nothing, starts nothing, deletes nothing. Safe to run at
# any time, including during a game.
#
# Runs ON THE HOST -- the workflow pipes it over ssh (`ssh host 'bash -s' <
# this`). It can also be pasted into a shell on the host verbatim.
set -euo pipefail

CONTAINER=encounter-engine-db

# PGUSER and PGDATABASE are not optional. `docker exec` runs as root, so libpq
# defaults PGUSER to "root" and wal-g dies with `role "root" does not exist`.
# WAL *archiving* keeps working regardless, because `wal-g wal-push` needs no
# database connection -- which is exactly how this system once looked healthy
# for hours while being unable to restore anything.
WG=(docker exec -e PGUSER=encounter -e PGDATABASE=encounter_production "$CONTAINER" wal-g)

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "FATAL: ${CONTAINER} is not running. Nothing can be queried or restored" >&2
  echo "       until it is back up: wal-g lives inside that container." >&2
  exit 1
fi

echo "==================================================================="
echo " BASE BACKUPS"
echo "==================================================================="
"${WG[@]}" backup-list --detail --pretty 2>&1 | grep -v '^INFO:' || true

echo
echo "==================================================================="
echo " WAL CHAIN"
echo "==================================================================="
# The integrity check is what says whether point-in-time recovery is actually
# possible. A full backup list with a broken chain restores only to the exact
# instant of a base backup, not to a time of your choosing.
"${WG[@]}" wal-verify integrity 2>&1 | grep -vE '^INFO:' || true

echo
echo "==================================================================="
echo " RESTORE WINDOW"
echo "==================================================================="

# Captured ONCE and parsed from the variable, not piped three times. An
# `awk ... {exit}` mid-pipe closes the pipe while wal-g is still writing to it,
# which raises SIGPIPE -- and under `set -e` with `pipefail` that silently kills
# this script right here, after printing everything above it. It looks exactly
# like the script simply stopping.
BACKUPS=$("${WG[@]}" backup-list 2>/dev/null || true)

EARLIEST=$(awk '$1 ~ /^base_/ {print $2; found=1} found {exit}' <<<"$BACKUPS")
LATEST_BACKUP=$(awk '$1 ~ /^base_/ {n=$1; t=$2} END {if (n) print n" "t}' <<<"$BACKUPS")

# archive_timeout is 300s, so a segment is pushed at least every five minutes
# even on an idle database. The newest restorable instant therefore trails now
# by at most that, plus however long the push takes.
LAG=$(docker exec "$CONTAINER" bash -c 'grep -h "^archive_timeout" /etc/postgresql/conf.d/*.conf 2>/dev/null || true' | head -1 | awk '{print $3}')

echo "  earliest restorable : ${EARLIEST:-unknown}  (start of the oldest base backup)"
echo "  newest base backup  : ${LATEST_BACKUP:-unknown}"
echo "  latest restorable   : now, minus up to ${LAG:-300}s of un-pushed WAL"
echo
echo "  Any instant BETWEEN those two is a valid recovery target, provided the"
echo "  WAL chain above reports OK."

echo
echo "==================================================================="
echo " TO RESTORE, RUN THE 'Database' WORKFLOW WITH"
echo "==================================================================="
echo
echo "  newest data:"
echo "      action        = restore-to-scratch"
echo "      restore_point = latest"
echo
echo "  a specific moment (copy the format exactly, including the offset):"
echo "      action        = restore-to-scratch"
echo "      restore_point = point_in_time"
echo "      target_time   = $(date -u '+%Y-%m-%d %H:%M:%S+00')"
echo
echo "  a specific base backup, ignoring later WAL:"
echo "      action        = restore-to-scratch"
echo "      restore_point = named_backup"
echo "      backup_name   = ${LATEST_BACKUP%% *}"
echo
echo "  All three restore into a throwaway container. None of them touches the"
echo "  live database -- see docs/runbooks/restore.md for the production path."
