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
if ss -ltn 2>/dev/null | grep -q ':3306'; then
  echo "FATAL: something is listening on 3306; refusing a cold-copy assumption" >&2
  exit 1
fi
echo "MySQL confirmed stopped; cold copy is safe"

RECIPIENTS=/etc/encounter-engine/archive-recipients.txt
CONTAINER=archive-once
DATE=2026-08-14
STAGE=$(mktemp -d /var/tmp/ee-once.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

ACCT=$(systemctl show encounter-engine-backup.service -p Environment --value \
       | tr ' ' '\n' | grep '^AZURE_STORAGE_ACCOUNT=' | cut -d= -f2)
BASE="https://${ACCT}.blob.core.windows.net/${CONTAINER}/${DATE}"
azcopy login --identity >/dev/null

# /var/tmp, not /tmp: these are gigabytes and /tmp may be a tmpfs on a 1 GB box.
push() {  # push <name> <tar-source-dir> <tar-target>
  local name="$1" dir="$2" target="$3"
  echo "=== $name"
  tar --create --zstd --file "$STAGE/$name.tar.zst" --directory "$dir" "$target"
  age -R "$RECIPIENTS" -o "$STAGE/$name.tar.zst.age" "$STAGE/$name.tar.zst"
  local up; up=$(sha256sum "$STAGE/$name.tar.zst.age" | cut -d' ' -f1)
  azcopy copy "$STAGE/$name.tar.zst.age" "$BASE/$name.tar.zst.age" --overwrite=true >/dev/null
  azcopy copy "$BASE/$name.tar.zst.age" "$STAGE/rt.age" >/dev/null
  local down; down=$(sha256sum "$STAGE/rt.age" | cut -d' ' -f1)
  [ "$up" = "$down" ] || { echo "FATAL: read-back mismatch for $name" >&2; exit 1; }
  echo "$name verified, sha256 $up"
  rm -f "$STAGE/$name.tar.zst" "$STAGE/$name.tar.zst.age" "$STAGE/rt.age"
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
azcopy copy "$BASE/system-2026-08-04.fsa.age" "$STAGE/rt.age" >/dev/null
DOWN=$(sha256sum "$STAGE/rt.age" | cut -d' ' -f1)
[ "$UP" = "$DOWN" ] || { echo "FATAL: read-back mismatch for fsarchiver image" >&2; exit 1; }
echo "fsarchiver image verified, sha256 $UP"

echo
echo "ALL FOUR ARCHIVES VERIFIED. Record the four sha256 values in"
echo "docs/runbooks/restore.md section 8 -- nothing will ever regenerate these."
