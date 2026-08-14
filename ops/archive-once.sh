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
#
# RUN AS ROOT:  ssh mezin 'sudo bash -s' < ops/archive-once.sh
set -euo pipefail

# Root is required, and without it the first failure is misleading rather than
# obvious: /var/lib/mysql is 0700 mysql:mysql, so `du -sm` on it exits non-zero
# and trips the fail-closed measurement check below as "FATAL: du failed on
# /var/lib/mysql" -- which reads as a disk or mount problem, not as "you forgot
# sudo". The mktemp on /backup and the tar of the datadir need root too. The
# documented invocation (ops/README.md, and the plan) pipes this over ssh, which
# connects as mezinster, so the sudo is easy to leave off; say so here rather
# than let it surface three checks later as something else.
if [ "$(id -u)" -ne 0 ]; then
  echo "FATAL: this script must run as root -- it reads /var/lib/mysql (0700) and stages on /backup." >&2
  echo "       Run it as:  ssh mezin 'sudo bash -s' < ops/archive-once.sh" >&2
  exit 1
fi

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

# The four sources, named once. TAR_SOURCES is exactly the three push() calls at
# the bottom of this script, in the same order -- keep them in step.
TAR_SOURCES=(/var/www/root /var/lib/mysql /home/mezinster)
FSA=/backup/system-2026-08-04.fsa

# Every source checked HERE, up front, before the free-space gate and before
# anything is staged. Tolerating a missing one and discovering it later buys
# nothing: this archive is written once, and a run that uploads three of four
# members is not a partial success, it is a job somebody has to do again. The
# earlier shape was actively misleading -- a missing fsarchiver image sized as
# FSA_MB=0, sailed through the gate, and FATALed only after three multi-GB
# tar/encrypt/upload/read-back cycles had already run. This script gets one
# supervised run on a production host, at night; precondition failures belong at
# precondition time.
for p in "${TAR_SOURCES[@]}" "$FSA"; do
  if [ ! -e "$p" ]; then
    echo "FATAL: $p does not exist; refusing to write a one-off archive that is" >&2
    echo "       missing one of its four members -- fix the path or the mount first" >&2
    exit 1
  fi
done

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
for p in "${TAR_SOURCES[@]}"; do
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
FSA_BYTES=$(stat -c%s "$FSA" 2>/dev/null) || true
case "$FSA_BYTES" in
  ''|*[!0-9]*)
    echo "FATAL: could not measure the size of $FSA; refusing to stage an unmeasured payload" >&2
    exit 1
    ;;
esac
FSA_MB=$(( FSA_BYTES / 1024 / 1024 ))
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

# azcopy reports what a transfer actually did on STDOUT -- per-transfer errors
# and a closing "Final Job Status:" line. Sending that to /dev/null leaves a
# failure with nothing but a non-zero exit status to investigate, and this
# script is watched once, at night, by someone who will not run it again. So:
# capture it, stay silent when it worked, print all of it to stderr when it did
# not. The status line is checked as well as the exit status because a job can
# end CompletedWithErrors -- some transfers failed -- and a partial upload here
# is exactly what the read-back below exists to refuse.
azcopy_quiet() {
  local out status=0
  out=$(azcopy "$@" 2>&1) || status=$?
  if [ "$status" -ne 0 ] || printf '%s\n' "$out" | grep -qE 'Final Job Status: (Failed|CompletedWithErrors)'; then
    echo "FATAL: azcopy $1 reported failure (exit ${status}); its full output follows" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  return 0
}
azcopy_quiet login --identity

# --block-blob-tier=Cool on every upload: the spec puts this tier-1 archive on
# Cool (about 7 GB, written once, read only in a disaster), and the account
# default is Hot. Setting it at upload time avoids a second pass to re-tier
# blobs nobody will look at again, and Cool's higher read cost is irrelevant for
# something read once or never.
BLOB_TIER=Cool

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
  azcopy_quiet copy "$STAGE/$name.tar.zst.age" "$BASE/$name.tar.zst.age" \
    --overwrite=true --block-blob-tier="$BLOB_TIER"
  # Dead once uploaded -- what's compared below is the read-back, not this
  # local copy.
  rm -f "$STAGE/$name.tar.zst.age"
  azcopy_quiet copy "$BASE/$name.tar.zst.age" "$STAGE/rt.age"
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
# "$FSA" and "$FSA_BLOB", not either path spelled out again: the gate above
# sized this term from $FSA, and the upload and the read-back below must name
# one and the same blob. A second literal is how the file that gets measured
# stops being the file that gets encrypted, and how a blob gets uploaded under
# one name and verified under another. Existence was checked with the other
# three sources, before the gate.
FSA_BLOB="$(basename "$FSA").age"
echo "=== fsarchiver image"
age -R "$RECIPIENTS" -o "$STAGE/system.fsa.age" "$FSA"
UP=$(sha256sum "$STAGE/system.fsa.age" | cut -d' ' -f1)
azcopy_quiet copy "$STAGE/system.fsa.age" "$BASE/$FSA_BLOB" \
  --overwrite=true --block-blob-tier="$BLOB_TIER"
# Dead once uploaded, same reasoning as push(). The source file it was
# encrypted from is pre-existing space on $STAGE_ROOT -- already counted as
# used, not free -- so this .age, and then rt.age after it, is the only copy
# charged against the free-space gate at any instant. That is exactly the 1x
# the gate above sizes the fsarchiver shape at, and this `rm -f` is what makes
# it true.
rm -f "$STAGE/system.fsa.age"
azcopy_quiet copy "$BASE/$FSA_BLOB" "$STAGE/rt.age"
DOWN=$(sha256sum "$STAGE/rt.age" | cut -d' ' -f1)
[ "$UP" = "$DOWN" ] || { echo "FATAL: read-back mismatch for fsarchiver image" >&2; exit 1; }
echo "fsarchiver image verified, sha256 $UP"
rm -f "$STAGE/rt.age"

echo
echo "ALL FOUR ARCHIVES VERIFIED. Record the four sha256 values in"
echo "docs/runbooks/restore.md section 8 -- nothing will ever regenerate these."
