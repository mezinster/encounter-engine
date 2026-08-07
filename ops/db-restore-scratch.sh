#!/bin/bash
# Restore a backup into a THROWAWAY container beside production, verify it, and
# destroy it. The live database is never touched.
#
# Runs ON THE HOST -- the workflow pipes it over ssh. Arguments come from the
# environment so the same script serves the workflow and a human shell:
#
#   RESTORE_POINT   latest | point_in_time | named_backup     (default latest)
#   TARGET_TIME     '2026-08-07 03:30:00+00'   (point_in_time only)
#   BACKUP_NAME     base_0000000100000000000000NN  (named_backup only)
#   KEEP_SCRATCH    yes  -- leave the container up for poking at afterwards
#
# For restoring OVER production, see docs/runbooks/restore.md. That is
# deliberately not automated.
set -euo pipefail

PROD=encounter-engine-db
SCRATCH="ee-restore-scratch-$$"
SCRATCH_VOL="${SCRATCH}-data"
PGDATA=/var/lib/postgresql/data

RESTORE_POINT="${RESTORE_POINT:-latest}"
TARGET_TIME="${TARGET_TIME:-}"
BACKUP_NAME="${BACKUP_NAME:-}"
KEEP_SCRATCH="${KEEP_SCRATCH:-no}"

if ! docker ps --format '{{.Names}}' | grep -qx "$PROD"; then
  echo "FATAL: ${PROD} is not running; its image and wal-g config are the" >&2
  echo "       source of truth for this restore." >&2
  exit 1
fi

# Read the image and wal-g settings off the RUNNING production container rather
# than repeating them here. A restore rehearsed against different settings than
# production uses is a rehearsal of something else.
IMAGE=$(docker inspect "$PROD" --format '{{.Config.Image}}')
env_of() { docker inspect "$PROD" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^$1=" | head -1 | cut -d= -f2-; }
WALG_AZ_PREFIX=$(env_of WALG_AZ_PREFIX)
AZURE_STORAGE_ACCOUNT=$(env_of AZURE_STORAGE_ACCOUNT)
# POSTGRES_PASSWORD is deliberately NOT read or passed: --entrypoint sleep below
# skips initdb, which is its only consumer, and the psql calls later go over the
# local socket as unix user postgres. Passing it on the docker run command line
# published the production password to every local UID via /proc/<pid>/cmdline
# for the life of the call, on a host we share with other tenants
# (ansible/playbook.yml:2-4).

[ -n "$WALG_AZ_PREFIX" ] || { echo "FATAL: WALG_AZ_PREFIX not set on ${PROD}" >&2; exit 1; }

echo "image           : ${IMAGE}"
echo "archive         : ${WALG_AZ_PREFIX}"
echo "restore point   : ${RESTORE_POINT}${TARGET_TIME:+ @ ${TARGET_TIME}}${BACKUP_NAME:+ = ${BACKUP_NAME}}"
echo "scratch         : ${SCRATCH} (volume ${SCRATCH_VOL})"
echo

cleanup() {
  if [ "$KEEP_SCRATCH" = "yes" ]; then
    echo
    echo "KEEP_SCRATCH=yes -- leaving ${SCRATCH} running. Destroy it with:"
    echo "    docker rm -f ${SCRATCH} && docker volume rm ${SCRATCH_VOL}"
    return
  fi
  echo
  echo "--- cleaning up scratch ---"
  docker rm -f "$SCRATCH" >/dev/null 2>&1 || true
  docker volume rm "$SCRATCH_VOL" >/dev/null 2>&1 || true
  echo "removed ${SCRATCH} and ${SCRATCH_VOL}"
}
trap cleanup EXIT

# --entrypoint sleep, because the official entrypoint would run initdb and
# create an empty cluster on the fresh volume -- the restore has to land on a
# directory postgres has never initialised.
#
# Its own named volume, never the production one. That is the property that
# makes this safe to run during a game.
docker run -d --name "$SCRATCH" \
  -v "${SCRATCH_VOL}:${PGDATA}" \
  -e PGUSER=encounter -e PGDATABASE=encounter_production \
  -e "WALG_AZ_PREFIX=${WALG_AZ_PREFIX}" \
  -e "AZURE_STORAGE_ACCOUNT=${AZURE_STORAGE_ACCOUNT}" \
  --entrypoint sleep "$IMAGE" infinity >/dev/null

echo "--- fetching base backup ---"
case "$RESTORE_POINT" in
  latest)
    docker exec "$SCRATCH" wal-g backup-fetch "$PGDATA" LATEST
    ;;
  named_backup)
    [ -n "$BACKUP_NAME" ] || { echo "FATAL: backup_name is required for named_backup" >&2; exit 1; }
    docker exec "$SCRATCH" wal-g backup-fetch "$PGDATA" "$BACKUP_NAME"
    ;;
  point_in_time)
    [ -n "$TARGET_TIME" ] || { echo "FATAL: target_time is required for point_in_time" >&2; exit 1; }
    # wal-g 3.0.3's backup-fetch has NO --target-time flag (it exists on some
    # other wal-g subcommands, which is the easy mistake). The base backup has
    # to be chosen here: the newest one taken at or before the target, so WAL
    # replay travels forward the shortest distance. recovery_target_time then
    # stops the replay at the requested instant.
    TARGET_EPOCH=$(date -u -d "$TARGET_TIME" +%s) || {
      echo "FATAL: could not parse target_time '${TARGET_TIME}'." >&2
      echo "       Use the format the list action prints, e.g. 2026-08-07 03:30:00+00" >&2
      exit 1
    }
    PICKED=$(docker exec -e PGUSER=encounter -e PGDATABASE=encounter_production \
               "$PROD" wal-g backup-list 2>/dev/null |
             awk -v t="$TARGET_EPOCH" '
               $1 ~ /^base_/ {
                 cmd = "date -u -d \"" $2 "\" +%s 2>/dev/null"
                 cmd | getline e; close(cmd)
                 if (e != "" && e+0 <= t) pick = $1
               }
               END { if (pick) print pick }')
    if [ -z "$PICKED" ]; then
      echo "FATAL: no base backup exists at or before ${TARGET_TIME}." >&2
      echo "       The archive cannot reach that far back. Run the list action" >&2
      echo "       to see the earliest restorable point." >&2
      exit 1
    fi
    echo "chose base backup ${PICKED} (newest at or before the target)"
    docker exec "$SCRATCH" wal-g backup-fetch "$PGDATA" "$PICKED"
    ;;
  *)
    echo "FATAL: restore_point must be latest, point_in_time or named_backup" >&2
    exit 1
    ;;
esac

echo
echo "--- configuring recovery ---"
# archive_mode = off is THE critical line in this script.
#
# The restored data directory carries production's settings, including
# archive_mode = on and archive_command = 'wal-g wal-push %p' pointed at the
# SAME Azure prefix. A scratch cluster left to archive would push its own
# divergent timeline into the production archive and corrupt the thing being
# restored from. Recovery is also read-only until promotion, so nothing here
# needs archiving.
RECOVERY_TARGET=""
if [ "$RESTORE_POINT" = "point_in_time" ]; then
  RECOVERY_TARGET="recovery_target_time = '${TARGET_TIME}'"
fi

docker exec "$SCRATCH" bash -c "cat > ${PGDATA}/postgresql.auto.conf <<'CONF'
archive_mode = off
restore_command = 'wal-g wal-fetch %f %p'
recovery_target_action = 'promote'
${RECOVERY_TARGET}
CONF"

# recovery.signal is what puts PostgreSQL 12+ into archive recovery at startup.
docker exec "$SCRATCH" bash -c "touch ${PGDATA}/recovery.signal && chown -R postgres:postgres ${PGDATA} && chmod 700 ${PGDATA}"
docker exec "$SCRATCH" bash -c "grep -v '^\s*$' ${PGDATA}/postgresql.auto.conf | sed 's/^/    /'"

echo
echo "--- replaying WAL and starting ---"
docker exec -u postgres "$SCRATCH" \
  pg_ctl -D "$PGDATA" -o "-c config_file=/usr/share/postgresql/postgresql.conf.sample" -w -t 300 start

# recovery_target_action = promote ends recovery once the target is reached,
# but pg_ctl returns as soon as the server accepts connections -- which happens
# while it is still read-only. Without this wait the report says
# "still in recovery: t" on a perfectly good restore, which reads like a
# failure.
echo
echo -n "--- waiting for promotion "
for _ in $(seq 1 60); do
  IN_REC=$(docker exec -u postgres "$SCRATCH" psql -U encounter -d encounter_production -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || echo t)
  [ "$IN_REC" = "f" ] && break
  echo -n "."
  sleep 2
done
echo " ${IN_REC}"

echo
echo "==================================================================="
echo " WHAT WAS RESTORED"
echo "==================================================================="
q() { docker exec -u postgres "$SCRATCH" psql -U encounter -d encounter_production -tAc "$1" 2>/dev/null || echo "?"; }

echo "  recovery finished at : $(q 'SELECT pg_last_wal_replay_lsn();')"
echo "  still in recovery    : $(q 'SELECT pg_is_in_recovery();')"
echo
printf '  %-22s %s\n' "users"        "$(q 'SELECT count(*) FROM users;')"
printf '  %-22s %s\n' "teams"        "$(q 'SELECT count(*) FROM teams;')"
printf '  %-22s %s\n' "games"        "$(q 'SELECT count(*) FROM games;')"
printf '  %-22s %s\n' "levels"       "$(q 'SELECT count(*) FROM levels;')"
printf '  %-22s %s\n' "game_passings" "$(q 'SELECT count(*) FROM game_passings;')"
echo
echo "  newest user   : $(q "SELECT coalesce(max(created_at)::text, 'none') FROM users;")"
echo "  newest game   : $(q "SELECT coalesce(max(created_at)::text, 'none') FROM games;")"
echo "  newest log    : $(q "SELECT coalesce(max(time)::text, 'none') FROM logs;")"
echo
echo "  Compare those timestamps against the moment you meant to restore to."
echo "  If they are later than expected, the recovery target was not applied."
echo "==================================================================="
