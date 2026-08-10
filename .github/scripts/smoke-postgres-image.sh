#!/usr/bin/env bash
#
# Smoke-tests a built PostgreSQL image: wal-g has to be runnable inside it, and
# the server has to start with the tuning file actually applied.
#
# Called by BOTH .github/workflows/images.yml (on every push) and
# .github/workflows/deploy.yml (before the image is pushed to GHCR). One file on
# purpose: the bug this grew out of was a wait loop whose comment and code had
# drifted apart, and two copies of a script drift the same way.
#
# Usage: smoke-postgres-image.sh <image-tag>

# -e and -u, but deliberately NOT -o pipefail. The readiness check below is
# `docker logs ... | grep -qF`, and grep -q exits the moment it matches, which
# can hand `docker logs` a SIGPIPE and a 141 exit status. Under pipefail that
# turns a SUCCESSFUL match into a failed pipeline, and whether it happens
# depends on whether the log fits the pipe buffer -- a race, on the exact code
# path that already cost this repository three red builds.
set -eu

IMAGE="${1:?usage: smoke-postgres-image.sh <image-tag>}"
CONTAINER="pg-smoke-$$"

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> wal-g must be runnable INSIDE the image"
# archive_command is executed by the PostgreSQL process itself, so a wal-g on
# the host is unreachable -- see Dockerfile.postgres.
docker run --rm "$IMAGE" wal-g --version

echo "==> PostgreSQL must still start with the tuning file"
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=smoke "$IMAGE" >/dev/null

# pg_isready alone is not enough, and neither is the server's own startup
# banner. The official entrypoint runs initdb against a TEMPORARY server before
# starting the real one, and that temp server is a full PostgreSQL start: it
# logs "database system is ready to accept connections" to the container's
# stdout exactly like the real one (pg_ctl sends its output there, the
# entrypoint redirects nothing), and `listen_addresses=''` still leaves it on
# the usual unix socket -- the one pg_isready and `docker exec psql` both use.
# Waiting on either signal therefore breaks DURING initdb, and the assertions
# below land in the temp server's shutdown window with "FATAL: the database
# system is shutting down". Seen twice on 2026-08-07 and again on 2026-08-10.
#
# "PostgreSQL init process complete; ready for start up." is echoed by the
# entrypoint script itself, after docker_temp_server_stop returns. It is the one
# line in the stream the temp server cannot produce. -F because it is a fixed
# string containing regex metacharacters, not a pattern.
ready=no
for i in $(seq 1 60); do
  if docker logs "$CONTAINER" 2>&1 | grep -qF "PostgreSQL init process complete; ready for start up." \
     && docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
    ready=yes
    echo "real server accepting connections after ${i}s"
    break
  fi
  sleep 1
done

# Fail here rather than letting the assertions below fail instead. That is how
# this arrived the first time: a FATAL from psql, with no container log to read,
# reporting a symptom of the wait rather than the wait itself.
if [ "$ready" != yes ]; then
  echo "FAILED: PostgreSQL never finished starting within 60s"
  docker logs "$CONTAINER"
  exit 1
fi

# Values come from the tuning file in Dockerfile.postgres. If include_dir is
# ever dropped from postgresql.conf.sample these still read as the stock
# defaults, which is exactly what this is here to catch.
docker exec "$CONTAINER" psql -U postgres -tAc "SHOW max_connections;"      | grep -qx 20
docker exec "$CONTAINER" psql -U postgres -tAc "SHOW effective_cache_size;" | grep -qx 512MB
docker exec "$CONTAINER" psql -U postgres -tAc "SHOW archive_mode;"         | grep -qx on
echo "tuning applied"
