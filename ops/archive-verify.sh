#!/bin/bash
# Read-only. What was archived, and when. Safe to run during a game.
#
# Does NOT decrypt -- the host holds no private key, by design. This answers
# "is the daily job still producing archives of a plausible size", which is the
# question a silent failure makes urgent. Decrypting is a laptop operation:
# see docs/runbooks/restore.md §7.
set -euo pipefail

ACCT=$(systemctl show encounter-engine-backup.service -p Environment --value \
       | tr ' ' '\n' | grep '^AZURE_STORAGE_ACCOUNT=' | cut -d= -f2)

azcopy login --identity >/dev/null
echo "daily archives (newest last):"
azcopy list "https://${ACCT}.blob.core.windows.net/archive-daily/" --output-type text \
  | grep -E 'host-state\.tar\.zst\.age' | tail -10

echo
echo "one-off archive:"
azcopy list "https://${ACCT}.blob.core.windows.net/archive-once/" --output-type text | tail -10
