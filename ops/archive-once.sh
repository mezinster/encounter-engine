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

# Stage on /backup, not on / (/tmp or /var/tmp). / is the filesystem that also
# holds the production Postgres data directory, and filling it is a production
# outage rather than a failed backup; /backup is a separate 30 GB filesystem
# whose only contents are two fsarchiver images, i.e. scratch by definition,
# and the 5.1 GB image this script encrypts already lives there. Staging here
# keeps the database's filesystem out of the blast radius entirely.
#
# ONE variable for both the `df` target and the `mktemp` template, deliberately.
# These were two independent literals across five sites; a free-space gate that
# measures a different filesystem from the one being written to is the same
# class of defect as reading a storage-account name off the wrong place, and it
# reappears the moment somebody edits four of the five.
STAGE_ROOT=/backup

# Free-space gate, sized in gigabytes. Measure the actual candidates rather
# than guess: `du` each source directory and `stat` the fsarchiver image.
#
# The two staging shapes have DIFFERENT peaks, so they are sized separately and
# the larger of the two results wins. Applying one multiplier to the max of both
# sets (what this did before) charges the fsarchiver image the tar shape's 2x and
# inflates the requirement by a spurious ~5 GB -- the term that dominates the
# measurement is exactly the term that needs the smallest multiplier.
#
#   TAR_LARGEST_MB -> 2x. push() tars the directory, then encrypts it, so
#     $name.tar.zst and $name.tar.zst.age both exist at the peak. Both are
#     compressed, so 2x the UNCOMPRESSED `du` figure is a safe upper bound --
#     tar --zstd only shrinks from there.
#
#   FSA_MB -> 1x. The fsarchiver step has no tar intermediate; it encrypts the
#     image in place. The source is already on /backup and already counted as
#     used space, so it costs nothing against `df --output=avail`, and
#     system.fsa.age is deleted before rt.age is downloaded -- at no instant is
#     more than one 5.1 GB derived file present. The image is already
#     compressed, so its size is exact rather than an overestimate.
#
# Sizing them separately also keeps the gate satisfiable as the tar candidates
# grow: /home/mezinster has no stated bound, and folding it into a single
# fsa-dominated maximum hides the moment it becomes the real constraint.
#
# The two sides of the comparison need opposite treatment on failure, the same
# way as the daily script's equivalent gate. FREE_MB coerces an unreadable `df`
# to 0 and fails CLOSED (0 free is always less than any positive requirement).
# The requirement side (SZ, FSA_BYTES) FATALs instead of coercing to 0: a 0
# there would fail OPEN, collapsing REQUIRED_MB to just the margin and staging a
# payload nobody actually measured -- exactly backwards for a check whose entire
# job is refusing to stage something too big.
#
# `du` is checked on its EXIT STATUS, not only on whether its output parses.
# It prints a total AND exits non-zero when a subdirectory is unreadable, so a
# swallowed status yields a real number that is too small -- a guard that fails
# open while looking like it measured something. Running as root makes that
# unlikely, not impossible (a stale NFS mount, a broken bind mount, an
# immutable/permission oddity under /home). stderr is deliberately NOT
# redirected: `du` is silent on a clean run, so the only thing it can print is
# the name of the path that could not be read, which is the one thing the
# operator needs to see when this FATALs.
TAR_LARGEST_MB=0
for p in /var/www/root /var/lib/mysql /home/mezinster; do
  [ -e "$p" ] || continue
  if ! DU_OUT=$(du -sm "$p"); then
    echo "FATAL: du failed on $p (see its error above); its total would be an" >&2
    echo "       under-count, not a measurement -- refusing to size the gate on it" >&2
    exit 1
  fi
  SZ=$(printf '%s\n' "$DU_OUT" | tail -1 | cut -f1)
  case "$SZ" in
    ''|*[!0-9]*)
      echo "FATAL: could not measure the size of $p; refusing to stage an unmeasured payload" >&2
      exit 1
      ;;
  esac
  if [ "$SZ" -gt "$TAR_LARGEST_MB" ]; then TAR_LARGEST_MB=$SZ; fi
done
FSA=/backup/system-2026-08-04.fsa
FSA_MB=0
if [ -e "$FSA" ]; then
  FSA_BYTES=$(stat -c%s "$FSA" 2>/dev/null) || true
  case "$FSA_BYTES" in
    ''|*[!0-9]*)
      echo "FATAL: could not measure the size of $FSA; refusing to stage an unmeasured payload" >&2
      exit 1
      ;;
  esac
  FSA_MB=$(( FSA_BYTES / 1024 / 1024 ))
fi
MARGIN_MB=2048
PEAK_MB=$(( TAR_LARGEST_MB * 2 ))
if [ "$FSA_MB" -gt "$PEAK_MB" ]; then PEAK_MB=$FSA_MB; fi
REQUIRED_MB=$(( PEAK_MB + MARGIN_MB ))
FREE_MB=$(df --output=avail -m "$STAGE_ROOT" 2>/dev/null | tail -1 | tr -d ' ') || true
case "$FREE_MB" in ''|*[!0-9]*) FREE_MB=0 ;; esac
if [ "$FREE_MB" -lt "$REQUIRED_MB" ]; then
  echo "FATAL: only ${FREE_MB} MiB free on ${STAGE_ROOT}; need at least ${REQUIRED_MB} MiB" >&2
  echo "       (peak ${PEAK_MB} MiB = max of tar shape ~${TAR_LARGEST_MB} MiB x2 and fsarchiver ~${FSA_MB} MiB x1, plus ${MARGIN_MB} MiB margin)" >&2
  exit 1
fi

CONTAINER=archive-once
DATE=2026-08-14
STAGE=$(mktemp -d "${STAGE_ROOT}/ee-once.XXXXXX")
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

# Everything below stages under $STAGE, i.e. on $STAGE_ROOT -- see the comment
# above the free-space gate for why that is /backup and not anywhere on /.
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
#
# "$FSA", not the path spelled out again: the gate above sized the fsarchiver
# term from that variable, and a second literal is how the file that gets
# measured stops being the file that gets encrypted.
echo "=== fsarchiver image"
if [ ! -e "$FSA" ]; then
  echo "FATAL: $FSA does not exist; the one-off archive would be missing its largest member" >&2
  exit 1
fi
age -R "$RECIPIENTS" -o "$STAGE/system.fsa.age" "$FSA"
UP=$(sha256sum "$STAGE/system.fsa.age" | cut -d' ' -f1)
azcopy copy "$STAGE/system.fsa.age" "$BASE/system-2026-08-04.fsa.age" --overwrite=true >/dev/null
# Dead once uploaded, same reasoning as push(). The source file it was
# encrypted from is pre-existing space on $STAGE_ROOT -- already counted as
# used, not free -- so this .age, and then rt.age after it, is the only copy
# charged against the free-space gate at any instant. That is exactly the 1x
# the gate above sizes the fsarchiver shape at, and this `rm -f` is what makes
# it true.
rm -f "$STAGE/system.fsa.age"
azcopy copy "$BASE/system-2026-08-04.fsa.age" "$STAGE/rt.age" >/dev/null
DOWN=$(sha256sum "$STAGE/rt.age" | cut -d' ' -f1)
[ "$UP" = "$DOWN" ] || { echo "FATAL: read-back mismatch for fsarchiver image" >&2; exit 1; }
echo "fsarchiver image verified, sha256 $UP"
rm -f "$STAGE/rt.age"

echo
echo "ALL FOUR ARCHIVES VERIFIED. Record the four sha256 values in"
echo "docs/runbooks/restore.md section 8 -- nothing will ever regenerate these."
