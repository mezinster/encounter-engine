#!/bin/bash
# One-off archive of the frozen WordPress estate. Run ONCE, by hand.
#
# Why once: MySQL and WordPress are stopped deliberately, to free CPU and
# memory for this application. Data that cannot change does not need a daily
# copy; a recurring job would re-upload 1.5 GB a day to reproduce a
# byte-identical blob.
#
# Why only while MySQL is stopped: a file-level copy of a QUIESCENT
# /var/lib/mysql is a consistent database. A live InnoDB directory copies torn.
# The guard below is not paranoia -- it is the entire reason this is safe
# without a mysqldump step.
set -euo pipefail

if systemctl is-active --quiet mysql || systemctl is-active --quiet mariadb; then
  echo "FATAL: MySQL is running. A file-level copy would be torn." >&2
  echo "Either stop it, or take a mysqldump instead -- see the spec, Tier 1." >&2
  exit 1
fi
# Verify 'ss' actually exists rather than silently trusting its absence. The
# old `2>/dev/null` swallowed a missing binary the same way it swallowed "not
# listening" -- both look identical once redirected to /dev/null, and only one
# of them means the guard actually ran. This guard is the entire reason a
# plain file-level copy of /var/lib/mysql is safe below; fail closed.
if ! command -v ss >/dev/null 2>&1; then
  echo "FATAL: 'ss' is not available; cannot verify nothing is listening on 3306" >&2
  exit 1
fi
if ss -ltn | grep -q ':3306'; then
  echo "FATAL: something is listening on 3306; refusing a cold-copy assumption" >&2
  exit 1
fi
echo "MySQL confirmed stopped; cold copy is safe"

RECIPIENTS=/etc/encounter-engine/archive-recipients.txt
if [ ! -s "$RECIPIENTS" ]; then
  echo "FATAL: no age recipients at $RECIPIENTS; refusing to stage gigabytes with nothing to encrypt them to" >&2
  exit 1
fi
# Two recipients is the whole point -- so losing one key does not make every
# backup worthless. A recipients file with only one line satisfies -s above
# and would silently defeat that; counting DISTINCT age1 lines also catches
# the same key listed twice, which would otherwise pass a plain line count.
# `tr -d '\r'` + trailing-whitespace strip before the dedup: a CRLF-edited
# file would otherwise make "age1abc" and "age1abc\r" count as two distinct
# recipients when they are the same key once.
RECIPIENT_COUNT=$(grep '^age1' "$RECIPIENTS" | tr -d '\r' | sed 's/[[:space:]]*$//' | sort -u | wc -l) || true
if [ "$RECIPIENT_COUNT" -lt 2 ]; then
  echo "FATAL: only ${RECIPIENT_COUNT} distinct age1 recipient(s) in $RECIPIENTS; need at least two" >&2
  exit 1
fi

# Free-space gate, sized in gigabytes: on a 13 GB-free root that also holds
# the production Postgres data directory (Global Constraints in the
# offsite-backup plan), filling it is a production outage, not a failed
# backup. Measure the actual candidates rather than guess: `du` each source
# directory and `stat` the fsarchiver image, and take the largest.
#
# Sized at ~2x the largest item, not 3x: push() and the fsarchiver step below
# both delete each intermediate the moment it is dead (the plaintext tar right
# after encryption, the uploaded .age right after azcopy confirms it landed --
# see the `rm -f` lines below), so at most one item's compressed/encrypted
# size is ever on disk at a time, plus a brief second copy while the next
# stage is being written or the read-back is being downloaded. 2x the largest
# candidate's UNCOMPRESSED size is a safe upper bound for that -- tar --zstd
# only shrinks from there, and the fsarchiver image is already compressed, so
# its own size is exact rather than an overestimate. The previous 3x, measured
# the same way, required ~17 GiB against 13 GB free and made this script
# unrunnable on the host it targets.
#
# The two measurements below need opposite treatment on failure, the same way
# as the daily script's equivalent gate. FREE_MB coerces an unreadable `df` to
# 0 and fails CLOSED (0 free is always less than any positive requirement).
# LARGEST_MB's inputs (SZ, FSA_BYTES) FATAL instead of coercing to 0 on
# failure: a 0 there would fail OPEN, collapsing REQUIRED_MB to just the
# margin and staging a payload nobody actually measured -- exactly backwards
# for a check whose entire job is refusing to stage something too big.
LARGEST_MB=0
for p in /var/www/root /var/lib/mysql /home/mezinster; do
  [ -e "$p" ] || continue
  SZ=$(du -sm "$p" 2>/dev/null | cut -f1) || true
  case "$SZ" in
    ''|*[!0-9]*)
      echo "FATAL: could not measure the size of $p; refusing to stage an unmeasured payload" >&2
      exit 1
      ;;
  esac
  [ "$SZ" -gt "$LARGEST_MB" ] && LARGEST_MB=$SZ
done
FSA=/backup/system-2026-08-04.fsa
if [ -e "$FSA" ]; then
  FSA_BYTES=$(stat -c%s "$FSA" 2>/dev/null) || true
  case "$FSA_BYTES" in
    ''|*[!0-9]*)
      echo "FATAL: could not measure the size of $FSA; refusing to stage an unmeasured payload" >&2
      exit 1
      ;;
  esac
  FSA_MB=$(( FSA_BYTES / 1024 / 1024 ))
  [ "$FSA_MB" -gt "$LARGEST_MB" ] && LARGEST_MB=$FSA_MB
fi
MARGIN_MB=2048
REQUIRED_MB=$(( LARGEST_MB * 2 + MARGIN_MB ))
FREE_MB=$(df --output=avail -m /var/tmp 2>/dev/null | tail -1 | tr -d ' ') || true
case "$FREE_MB" in ''|*[!0-9]*) FREE_MB=0 ;; esac
if [ "$FREE_MB" -lt "$REQUIRED_MB" ]; then
  echo "FATAL: only ${FREE_MB} MiB free on /var/tmp; need at least ${REQUIRED_MB} MiB (largest item ~${LARGEST_MB} MiB x2 + ${MARGIN_MB} MiB margin)" >&2
  exit 1
fi

CONTAINER=archive-once
DATE=2026-08-14
STAGE=$(mktemp -d /var/tmp/ee-once.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

# AZURE_STORAGE_ACCOUNT lives on the encounter-engine-db container's
# environment, not on the encounter-engine-backup systemd unit -- see
# ops/db-restore-scratch.sh, which reads it the same way.
DB_CONTAINER=encounter-engine-db
env_of() { docker inspect "$DB_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^$1=" | head -1 | cut -d= -f2-; }
# The `|| true` matters: under pipefail, env_of's internal grep exits 1 when
# nothing matches, which would otherwise fail this assignment and terminate
# the script here -- before the FATAL message below ever runs.
ACCT=$(env_of AZURE_STORAGE_ACCOUNT) || true
if [ -z "$ACCT" ]; then
  echo "FATAL: could not read AZURE_STORAGE_ACCOUNT off the ${DB_CONTAINER} container" >&2
  exit 1
fi
BASE="https://${ACCT}.blob.core.windows.net/${CONTAINER}/${DATE}"
azcopy login --identity >/dev/null

# /var/tmp, not /tmp: these are gigabytes and /tmp may be a tmpfs on a 1 GB box.
push() {  # push <name> <tar-source-dir> <tar-target>
  local name="$1" dir="$2" target="$3"
  echo "=== $name"
  tar --create --zstd --file "$STAGE/$name.tar.zst" --directory "$dir" "$target"
  age -R "$RECIPIENTS" -o "$STAGE/$name.tar.zst.age" "$STAGE/$name.tar.zst"
  # Dead the moment encryption succeeds -- this is also the plaintext tar
  # (potentially a database, a home directory, a WordPress tree with
  # credentials in wp-config.php); no reason to let it sit on disk any longer
  # than the encryption step itself needs it, and the free-space gate above is
  # sized assuming it doesn't.
  rm -f "$STAGE/$name.tar.zst"
  local up; up=$(sha256sum "$STAGE/$name.tar.zst.age" | cut -d' ' -f1)
  azcopy copy "$STAGE/$name.tar.zst.age" "$BASE/$name.tar.zst.age" --overwrite=true >/dev/null
  # Dead once uploaded -- what's compared below is the read-back, not this
  # local copy.
  rm -f "$STAGE/$name.tar.zst.age"
  azcopy copy "$BASE/$name.tar.zst.age" "$STAGE/rt.age" >/dev/null
  local down; down=$(sha256sum "$STAGE/rt.age" | cut -d' ' -f1)
  [ "$up" = "$down" ] || { echo "FATAL: read-back mismatch for $name" >&2; exit 1; }
  echo "$name verified, sha256 $up"
  rm -f "$STAGE/rt.age"
}

push wordpress-tree  /var/www  root
push mysql-datadir   /var/lib  mysql
push home-mezinster  /home     mezinster

# The fsarchiver image is already a compressed file; tar would only wrap it.
# Encrypt and upload directly. It is archived as a bare-metal image of the OS
# ONLY -- it was written at 06:11 on 4 August against a MySQL shutdown at
# 21:36, so the database inside it was captured live and is torn. The
# mysql-datadir archive above is the trustworthy copy of that database.
echo "=== fsarchiver image"
age -R "$RECIPIENTS" -o "$STAGE/system.fsa.age" /backup/system-2026-08-04.fsa
UP=$(sha256sum "$STAGE/system.fsa.age" | cut -d' ' -f1)
azcopy copy "$STAGE/system.fsa.age" "$BASE/system-2026-08-04.fsa.age" --overwrite=true >/dev/null
# Dead once uploaded, same reasoning as push(): the source file it was
# encrypted from lives on /backup, not /var/tmp, so this is the only copy of
# it counting against the free-space gate above.
rm -f "$STAGE/system.fsa.age"
azcopy copy "$BASE/system-2026-08-04.fsa.age" "$STAGE/rt.age" >/dev/null
DOWN=$(sha256sum "$STAGE/rt.age" | cut -d' ' -f1)
[ "$UP" = "$DOWN" ] || { echo "FATAL: read-back mismatch for fsarchiver image" >&2; exit 1; }
echo "fsarchiver image verified, sha256 $UP"
rm -f "$STAGE/rt.age"

echo
echo "ALL FOUR ARCHIVES VERIFIED. Record the four sha256 values in"
echo "docs/runbooks/restore.md section 8 -- nothing will ever regenerate these."
