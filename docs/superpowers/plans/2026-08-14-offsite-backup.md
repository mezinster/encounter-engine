# Offsite Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the $7.48/month Azure Backup vault with two encrypted blob archives — a one-off copy of the frozen WordPress estate and a 2.5 MB daily copy of the live set — and retire the vault only once a rehearsed restore proves the replacement works.

**Architecture:** Two mechanisms on the production host, both following the existing wal-g pattern: a shell script in `ops/host/` installed to `/usr/local/bin`, driven by a systemd timer, authenticating to Azure Blob by managed identity with no stored key. Archives are encrypted with `age` using a public key only — the host can write backups it cannot read. Retention is an Azure lifecycle policy, not script logic.

**Tech Stack:** bash, systemd, `age` 1.0.0 (Ubuntu 22.04 archive), `azcopy` (managed identity), Azure Blob Storage, Az PowerShell module.

**Spec:** `docs/superpowers/specs/2026-08-13-offsite-backup-design.md`

## Global Constraints

- **Host is Ubuntu 22.04.5 LTS**, 1 vCPU, `/` has 13 GB free of 30 GB.
- **No stored credentials on the host, ever.** wal-g authenticates by managed identity (`AZURE_STORAGE_ACCOUNT` + `WALG_AZ_PREFIX`, no key); everything added here does the same. This is the property `config/deploy.yml` argues for at length.
- **Only the age PUBLIC key goes on the VM.** Private keys are generated off-host and never copied to it.
- **Two age recipients**, so losing one key does not make every backup worthless.
- **`ops/host/` files are copies, not the live files.** After editing, install and diff — see `ops/README.md`.
- **Storage account:** the same one wal-g already uses (`AZURE_STORAGE_ACCOUNT` on `encounter-engine-backup.service`). Do not create a second account.
- **Azure control-plane work runs from Windows PowerShell with the Az module**, not `az` in WSL — see the `azure-access-is-windows-powershell` note. Neither `az` nor `azcopy` is installed on the VM today.
- **Nothing in this plan deletes the vault until Task 7**, and Task 7 is gated on Task 6 passing.

## Blocking inputs required before Task 2

- **Where does the second `age` recipient live?** It must survive losing both the VM and the operator's laptop. Until this is answered, Task 2 cannot be completed correctly — a "second" recipient stored beside the first is not a second recipient. Spec, Open Questions §2.

## File Structure

| File | Responsibility |
|---|---|
| `ops/host/encounter-engine-archive` | Create: the daily tier-2 archive. Stage, checksum, encrypt, upload, read back, compare, clean up. |
| `ops/host/encounter-engine-archive.service` | Create: oneshot unit invoking the above. |
| `ops/host/encounter-engine-archive.timer` | Create: daily schedule, `Persistent=true`, randomised delay. |
| `ops/archive-once.sh` | Create: the tier-1 one-off archive, piped over ssh like `ops/db-list.sh`. |
| `ops/archive-verify.sh` | Create: read-only. Downloads the newest daily archive, decrypts, lists it. Safe during a game. |
| `ops/README.md` | Modify: add the four files above to its two tables. |
| `docs/runbooks/restore.md` | Modify: add §7 (restore the daily archive) and §8 (restore the tier-1 estate), and record the rehearsal. |

Nothing in this plan touches the Rails application. `ops/` is not loaded by it.

---

### Task 1: Install `age` and `azcopy` on the host, proving managed identity works

**Files:**
- Modify: `docs/runbooks/restore.md` (§6 prerequisites list)

**Interfaces:**
- Produces: `age` at `/usr/bin/age`, `azcopy` at `/usr/local/bin/azcopy`, both usable by root. Later tasks call `age -r <recipient>` and `azcopy copy`/`azcopy list` with `--trusted-microsoft-suffixes` unset and identity login already performed.

- [ ] **Step 1: Confirm the current state before changing it**

```bash
ssh mezin 'command -v age azcopy || echo "neither installed"; . /etc/os-release; echo "$PRETTY_NAME"'
```

Expected: `neither installed`, `Ubuntu 22.04.5 LTS`.

- [ ] **Step 2: Install `age` from the Ubuntu archive**

```bash
ssh mezin 'sudo apt-get update -qq && sudo apt-get install -y age && age --version'
```

Expected: `v1.0.0`. Packaged rather than a downloaded binary so it receives security updates with the rest of the system.

- [ ] **Step 3: Install `azcopy`**

wal-g speaks to blob through its own SDK; nothing else on the host can. `azcopy` is a single static binary supporting managed identity, which keeps the no-stored-key property. The Microsoft `.deb` feed is not enabled on this host, so install the released tarball:

```bash
ssh mezin 'set -euo pipefail
  cd /tmp
  curl -sSL -o azcopy.tar.gz "https://aka.ms/downloadazcopy-v10-linux"
  tar -xzf azcopy.tar.gz --strip-components=1 --wildcards "*/azcopy"
  sudo install -o root -g root -m 0755 azcopy /usr/local/bin/azcopy
  rm -f azcopy azcopy.tar.gz
  azcopy --version'
```

Expected: a version string, e.g. `azcopy version 10.x.x`.

- [ ] **Step 4: Prove managed identity reaches the storage account, read-only**

```bash
ssh mezin 'set -euo pipefail
  ACCT=$(sudo systemctl show encounter-engine-backup.service -p Environment --value | tr " " "\n" | grep ^AZURE_STORAGE_ACCOUNT= | cut -d= -f2)
  echo "account: $ACCT"
  sudo azcopy login --identity >/dev/null
  sudo azcopy list "https://${ACCT}.blob.core.windows.net/" | head -5'
```

Expected: the container list prints. A failure here means the VM's managed identity lacks a data-plane role on the account — grant `Storage Blob Data Contributor` on the account before continuing, and note that wal-g may be using a different mechanism that this does not inherit.

- [ ] **Step 5: Record the prerequisites in the runbook**

Add to `docs/runbooks/restore.md` §6, in the list of what a rebuilt host needs:

```markdown
- `age` (`apt-get install -y age`) — required to decrypt any archive written after 2026-08-14.
- `azcopy` (`https://aka.ms/downloadazcopy-v10-linux`, installed to `/usr/local/bin`) — the
  archive scripts' only route to blob storage. wal-g does not use it and does not install it.
```

- [ ] **Step 6: Commit**

```bash
git add docs/runbooks/restore.md
git commit -m "Record age and azcopy as restore prerequisites"
```

---

### Task 2: Generate the age keypair off-host and install only the public key

**Files:**
- Modify: `docs/runbooks/restore.md` (new §7 stub recording where the private keys live)

**Interfaces:**
- Produces: `/etc/encounter-engine/archive-recipients.txt` on the host — one `age1…` public recipient per line, mode 0644, root-owned. Every later script reads recipients from this file rather than embedding a key.

**Blocked on:** the second recipient's location (see *Blocking inputs* above). Do not complete this task with both keys in the same place.

- [ ] **Step 1: Generate two keypairs OFF the production host**

On the operator's machine, not over ssh:

```bash
umask 077
age-keygen -o ~/encounter-archive-primary.key
age-keygen -o ~/encounter-archive-secondary.key
grep '^# public key:' ~/encounter-archive-*.key
```

Expected: two lines of the form `# public key: age1…`. The `.key` files contain the **private** keys — they must not be committed, and must not go to the VM.

- [ ] **Step 2: Place the private keys, deliberately**

Primary: the operator's password manager. Secondary: somewhere that survives losing both the VM and the laptop — a second password manager, a printed copy in a safe, or a hardware token. **Write down which, in the runbook, in Step 5.** A key nobody can find is identical to a key nobody generated.

- [ ] **Step 3: Install the public recipients on the host**

```bash
ssh mezin 'set -euo pipefail
  sudo mkdir -p /etc/encounter-engine
  sudo tee /etc/encounter-engine/archive-recipients.txt >/dev/null <<EOF
age1PRIMARYPUBLICKEYHERE
age1SECONDARYPUBLICKEYHERE
EOF
  sudo chmod 0644 /etc/encounter-engine/archive-recipients.txt
  cat /etc/encounter-engine/archive-recipients.txt'
```

Substitute the two `age1…` public strings from Step 1. Public keys are not secret; 0644 is correct and deliberate.

- [ ] **Step 4: Prove the host can encrypt and CANNOT decrypt**

This is the property the whole design rests on, so test it rather than assume it:

```bash
ssh mezin 'set -euo pipefail
  echo "canary" | age -R /etc/encounter-engine/archive-recipients.txt -o /tmp/canary.age
  echo "encrypted ok, $(stat -c%s /tmp/canary.age) bytes"
  if age -d /tmp/canary.age 2>/dev/null; then
    echo "FAIL: the host decrypted its own archive"; exit 1
  else
    echo "PASS: host cannot decrypt (no identity present)"
  fi
  rm -f /tmp/canary.age'
```

Expected: `encrypted ok`, then `PASS`. A `FAIL` means a private key reached the host — find it and remove it before going further.

- [ ] **Step 5: Verify BOTH recipients can decrypt, independently**

On the operator's machine:

```bash
ssh mezin 'echo "canary" | age -R /etc/encounter-engine/archive-recipients.txt' > /tmp/canary.age
age -d -i ~/encounter-archive-primary.key   /tmp/canary.age   # expect: canary
age -d -i ~/encounter-archive-secondary.key /tmp/canary.age   # expect: canary
rm -f /tmp/canary.age
```

Expected: `canary` twice. If only one works, the recipients file is wrong and half the redundancy is imaginary.

- [ ] **Step 6: Record key custody in the runbook**

Add `docs/runbooks/restore.md` §7 opening:

```markdown
## 7. Decrypting an archive

Archives written after 2026-08-14 are encrypted with `age` to two recipients. The host holds
only the public keys (`/etc/encounter-engine/archive-recipients.txt`) and cannot read what it
writes.

| Key | Held where |
|---|---|
| primary | <fill in: password manager entry name> |
| secondary | <fill in: must survive losing both the VM and the laptop> |

    age -d -i <private key file> archive.tar.zst.age > archive.tar.zst
```

Replace both `<fill in>` values before committing — an unfilled table here is the failure this task exists to prevent.

- [ ] **Step 7: Commit**

```bash
git add docs/runbooks/restore.md
git commit -m "Record age recipients and where the private keys live"
```

---

### Task 3: Storage account — GRS, containers, and a lifecycle policy

**Files:** none in the repo. Azure control plane only.

**Interfaces:**
- Produces: containers `archive-daily` and `archive-once` on the existing storage account; a lifecycle rule deleting `archive-daily/**` after 90 days; account replication `Standard_GRS`.

Run from **Windows PowerShell with the Az module** (see Global Constraints).

- [ ] **Step 0: Discover the account and resource group rather than assuming them**

The storage account is whichever one wal-g already uses; there must not be a second. Read it off the host, then find its resource group:

```bash
ssh mezin 'sudo systemctl show encounter-engine-backup.service -p Environment --value \
           | tr " " "\n" | grep ^AZURE_STORAGE_ACCOUNT= | cut -d= -f2'
```

Then in PowerShell, using that name:

```powershell
$acct = '<the name printed above>'
$rg   = (Get-AzStorageAccount | Where-Object StorageAccountName -eq $acct).ResourceGroupName
"account=$acct  rg=$rg"
```

Expected: both non-empty. If `$rg` is empty, the signed-in context is on the wrong subscription — the saved context carrying Owner is the one to use.

- [ ] **Step 1: Confirm current replication before changing it**

```powershell
Get-AzStorageAccount -ResourceGroupName $rg -Name $acct |
  Select-Object StorageAccountName, @{n='Sku';e={$_.Sku.Name}}, @{n='Location';e={$_.Location}}
```

Expected: `Standard_LRS`. If it already reads GRS, skip Step 2 and note it.

- [ ] **Step 2: Convert to GRS**

```powershell
Set-AzStorageAccount -ResourceGroupName $rg -Name $acct -SkuName Standard_GRS
Get-AzStorageAccount -ResourceGroupName $rg -Name $acct | Select-Object @{n='Sku';e={$_.Sku.Name}}
```

Expected: `Standard_GRS`. This is the one axis on which the replacement was otherwise worse than the vault (spec, *Storage account*). Cost impact is fractions of a cent at these volumes.

- [ ] **Step 3: Create the two containers**

```powershell
$ctx = (Get-AzStorageAccount -ResourceGroupName $rg -Name $acct).Context
New-AzStorageContainer -Name 'archive-daily' -Context $ctx -Permission Off
New-AzStorageContainer -Name 'archive-once'  -Context $ctx -Permission Off
Get-AzStorageContainer -Context $ctx | Select-Object Name, PublicAccess
```

Expected: both listed, `PublicAccess` empty/Off. Separate containers because only one of them gets an expiry rule — putting both under one container risks a rule reaching the copy that must never expire.

- [ ] **Step 4: Lifecycle rule — 90 days, `archive-daily` ONLY**

```powershell
$action = Add-AzStorageAccountManagementPolicyAction -BaseBlobAction Delete -daysAfterModificationGreaterThan 90
$filter = New-AzStorageAccountManagementPolicyFilter -PrefixMatch 'archive-daily/' -BlobType blockBlob
$rule   = New-AzStorageAccountManagementPolicyRule -Name 'expire-daily-archives' -Action $action -Filter $filter
Set-AzStorageAccountManagementPolicy -ResourceGroupName $rg -StorageAccountName $acct -Rule $rule
(Get-AzStorageAccountManagementPolicy -ResourceGroupName $rg -StorageAccountName $acct).Rules |
  Select-Object Name, @{n='Prefix';e={$_.Definition.Filters.PrefixMatch}}
```

Expected: one rule, prefix `archive-daily/`. **Verify the prefix reads `archive-daily/` and not `archive-`** — the latter would also match `archive-once` and delete the copy nothing regenerates.

- [ ] **Step 5: Prove the rule cannot reach `archive-once`**

```powershell
(Get-AzStorageAccountManagementPolicy -ResourceGroupName $rg -StorageAccountName $acct).Rules |
  ForEach-Object { "$($_.Name): $($_.Definition.Filters.PrefixMatch -join ',')" }
```

Expected: no rule whose prefix is a prefix of `archive-once`. This is a read-only assertion and takes ten seconds; the failure it guards against is silent and permanent.

- [ ] **Step 6: Record in the spec that this is done**

No repo change. Note the date and the confirmed SKU in the PR description for the plan's branch.

---

### Task 4: The daily archive (tier 2)

**Files:**
- Create: `ops/host/encounter-engine-archive`
- Create: `ops/host/encounter-engine-archive.service`
- Create: `ops/host/encounter-engine-archive.timer`
- Create: `ops/archive-verify.sh`
- Modify: `ops/README.md`

**Interfaces:**
- Consumes: `age` and `azcopy` (Task 1), `/etc/encounter-engine/archive-recipients.txt` (Task 2), container `archive-daily` (Task 3).
- Produces: blobs at `archive-daily/<YYYY-MM-DD>/host-state.tar.zst.age`, one per day. `ops/archive-verify.sh` reads the newest.

- [ ] **Step 1: Write the script**

Create `ops/host/encounter-engine-archive`:

```bash
#!/bin/bash
# Daily archive of the small, live, irreplaceable set on this host.
#
# Deliberately NOT the whole filesystem: the OS, Docker images and /opt are
# rebuilt by CI or by apt, and the WordPress estate is frozen and archived once
# (see ops/archive-once.sh). What is left is single-digit megabytes -- which is
# what makes the staging and read-back below affordable.
#
# STAGED AND VERIFIED, not streamed. An earlier draft piped tar straight to
# blob. At this size the "don't compete for disk" argument does not apply, and
# streaming has a real cost: a truncated archive uploads and is
# indistinguishable from a good one -- the timer succeeds, the blob exists, the
# size looks plausible. The design's own standard is that a procedure nobody has
# executed is a hypothesis; that is as true of a backup nobody has read back.
#
# ENCRYPTED to public keys only. This archive contains three private keys
# (/var/www/Keys) and the dynamic-DNS credentials in /etc/ddclient.conf, so an
# unencrypted copy in blob storage is an offsite copy of the machine's
# credentials. The host cannot decrypt what it writes -- see Task 2's canary.
set -euo pipefail

RECIPIENTS=/etc/encounter-engine/archive-recipients.txt
CONTAINER=archive-daily
STAGE=$(mktemp -d /tmp/ee-archive.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

DATE=$(date -u +%Y-%m-%d)
ARCHIVE="$STAGE/host-state.tar.zst"

ACCT=$(systemctl show encounter-engine-backup.service -p Environment --value \
       | tr ' ' '\n' | grep '^AZURE_STORAGE_ACCOUNT=' | cut -d= -f2)
if [ -z "$ACCT" ]; then
  echo "FATAL: could not read AZURE_STORAGE_ACCOUNT from the wal-g unit" >&2
  exit 1
fi

if [ ! -s "$RECIPIENTS" ]; then
  echo "FATAL: no age recipients at $RECIPIENTS; refusing to write a plaintext archive" >&2
  exit 1
fi

# The uploads volume is read out of Docker rather than from /var/lib/docker
# directly: the volume's on-disk path is an implementation detail Docker is
# entitled to change, and reading it live risks catching a half-written file.
UPLOADS="$STAGE/uploads"
mkdir -p "$UPLOADS"
docker run --rm \
  -v encounter_engine_storage:/from:ro \
  -v "$UPLOADS":/to \
  alpine:3 sh -c 'cp -a /from/. /to/' 

# /etc/ssh whole rather than an enumerated list of host keys: this box has FOUR
# pairs (dsa, ecdsa, ed25519, rsa), and naming three of them would archive three
# quarters of the machine's identity WITHOUT tar complaining -- the omission is
# only visible at restore time, which is the worst time to find it. 560 KB, and
# it brings sshd_config along.
#
# /etc/letsencrypt is included although certificates are reissuable: 1.7 MB, and
# it avoids hitting Let's Encrypt rate limits during a rebuild, which is exactly
# when a rate limit is least welcome.
echo "building archive"
tar --create --zstd --file "$ARCHIVE" \
    --directory / \
    --warning=no-file-changed \
    var/www/Keys \
    etc/systemd/system/encounter-engine-backup.service \
    etc/systemd/system/encounter-engine-backup.timer \
    etc/systemd/system/encounter-engine-archive.service \
    etc/systemd/system/encounter-engine-archive.timer \
    etc/systemd/system/ddclient.service \
    usr/local/bin/encounter-engine-backup \
    usr/local/bin/encounter-engine-archive \
    etc/ddclient.conf \
    etc/ssh \
    etc/letsencrypt \
    etc/crontab etc/cron.d \
    etc/fstab etc/hosts \
    --directory "$STAGE" uploads

PLAIN_SUM=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
echo "archive: $(stat -c%s "$ARCHIVE") bytes, sha256 $PLAIN_SUM"

echo "encrypting"
age -R "$RECIPIENTS" -o "$ARCHIVE.age" "$ARCHIVE"

URL="https://${ACCT}.blob.core.windows.net/${CONTAINER}/${DATE}/host-state.tar.zst.age"
echo "uploading to $URL"
azcopy login --identity >/dev/null
azcopy copy "$ARCHIVE.age" "$URL" --overwrite=true >/dev/null

# Read it back. Not "does the blob exist" -- does the blob, once downloaded,
# have the same bytes we uploaded. Decryption cannot be checked here by design
# (no private key on this host), so the ciphertext digest is what we compare.
echo "verifying by read-back"
UP_SUM=$(sha256sum "$ARCHIVE.age" | cut -d' ' -f1)
azcopy copy "$URL" "$STAGE/roundtrip.age" >/dev/null
DOWN_SUM=$(sha256sum "$STAGE/roundtrip.age" | cut -d' ' -f1)

if [ "$UP_SUM" != "$DOWN_SUM" ]; then
  echo "FATAL: read-back mismatch. uploaded $UP_SUM, downloaded $DOWN_SUM" >&2
  exit 1
fi

echo "OK: ${DATE} archive verified, ciphertext sha256 $UP_SUM"
```

- [ ] **Step 2: Run it by hand against a scratch date prefix, before installing any timer**

```bash
scp ops/host/encounter-engine-archive mezin:/tmp/ee-archive-test
ssh mezin 'sudo install -m 0755 -o root -g root /tmp/ee-archive-test /usr/local/bin/encounter-engine-archive && sudo /usr/local/bin/encounter-engine-archive'
```

Expected: `OK: <date> archive verified` and a ciphertext sha256. Any `FATAL:` line means stop and fix — do not install a timer around a script that has never succeeded.

- [ ] **Step 3: Prove the archive actually decrypts and contains what it claims**

On the operator's machine, with a private key:

```bash
# ACCT: the value discovered in Task 3 Step 0.
ACCT=<account>; DATE=$(date -u +%Y-%m-%d)
azcopy copy "https://${ACCT}.blob.core.windows.net/archive-daily/${DATE}/host-state.tar.zst.age" /tmp/a.age
age -d -i ~/encounter-archive-primary.key /tmp/a.age > /tmp/a.tar.zst
tar --zstd -tf /tmp/a.tar.zst | sort | head -30
tar --zstd -tf /tmp/a.tar.zst | grep -c '^uploads/'
```

Expected: the listing contains `var/www/Keys/`, `etc/ddclient.conf`, `etc/letsencrypt/`, the systemd units, and `uploads/`. This is the first end-to-end proof that the encryption is reversible; Task 2's canary only proved the keys work on a one-line file.

- [ ] **Step 4: Write the unit and timer**

Create `ops/host/encounter-engine-archive.service`:

```ini
[Unit]
Description=encounter-engine daily host-state archive to Azure Blob
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/encounter-engine-archive
```

Create `ops/host/encounter-engine-archive.timer`:

```ini
[Unit]
Description=Daily encounter-engine host-state archive

[Timer]
# 03:40, deliberately after the 03:00 wal-g base backup and its randomised
# 15-minute delay. This box has 1 vCPU; the two jobs overlapping would make
# both slower and neither more useful.
OnCalendar=*-*-* 03:40:00
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
```

- [ ] **Step 5: Install and enable**

```bash
scp ops/host/encounter-engine-archive.service ops/host/encounter-engine-archive.timer mezin:/tmp/
ssh mezin 'set -euo pipefail
  sudo install -m 0644 -o root -g root /tmp/encounter-engine-archive.service /etc/systemd/system/
  sudo install -m 0644 -o root -g root /tmp/encounter-engine-archive.timer   /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now encounter-engine-archive.timer
  systemctl list-timers --all --no-pager | grep encounter'
```

Expected: both `encounter-engine-backup.timer` and `encounter-engine-archive.timer` listed with a NEXT time.

- [ ] **Step 6: Confirm the installed copies match the repo**

The `ops/README.md` rule, applied:

```bash
ssh mezin 'cat /usr/local/bin/encounter-engine-archive' | diff - ops/host/encounter-engine-archive
ssh mezin 'cat /etc/systemd/system/encounter-engine-archive.service' | diff - ops/host/encounter-engine-archive.service
ssh mezin 'cat /etc/systemd/system/encounter-engine-archive.timer' | diff - ops/host/encounter-engine-archive.timer
```

Expected: no output from any of the three.

- [ ] **Step 7: Write the read-only verify script**

Create `ops/archive-verify.sh`:

```bash
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
```

- [ ] **Step 8: Run it**

```bash
ssh mezin 'bash -s' < ops/archive-verify.sh
```

Expected: today's daily archive listed with a non-zero size. `archive-once` is empty until Task 5.

- [ ] **Step 9: Update `ops/README.md`**

Add to the first table:

```markdown
| `archive-verify.sh` | Read-only. What has been archived and when. Safe during a game. |
```

Add to the `host/` table:

```markdown
| `encounter-engine-archive` | `/usr/local/bin/encounter-engine-archive` (mode 755, root) |
| `encounter-engine-archive.service` | `/etc/systemd/system/` |
| `encounter-engine-archive.timer` | `/etc/systemd/system/` |
```

- [ ] **Step 10: Commit**

```bash
git add ops/host/encounter-engine-archive ops/host/encounter-engine-archive.service \
        ops/host/encounter-engine-archive.timer ops/archive-verify.sh ops/README.md
git commit -m "Daily host-state archive, staged and read back rather than streamed"
```

---

### Task 5: The one-off archive (tier 1)

**Files:**
- Create: `ops/archive-once.sh`
- Modify: `ops/README.md`

**Interfaces:**
- Consumes: `age`, `azcopy`, recipients file, container `archive-once`.
- Produces: blobs under `archive-once/2026-08-14/` — `wordpress-tree.tar.zst.age`, `mysql-datadir.tar.zst.age`, `home-mezinster.tar.zst.age`, `system-2026-08-04.fsa.age`.

**Run once, and only while MySQL is stopped.** The spec's *Tier 1* section explains why: a cold copy of `/var/lib/mysql` is consistent, a live one is torn, and this decision expires the moment MySQL is restarted.

- [ ] **Step 1: Assert MySQL is still stopped, and refuse to run if not**

Create `ops/archive-once.sh`, opening with the guard:

```bash
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
```

- [ ] **Step 2: Add the four archives**

Append to `ops/archive-once.sh`:

```bash
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
```

- [ ] **Step 3: Check there is room to stage before running**

```bash
ssh mezin 'df -h / /var/tmp | tail -2; du -sh /var/www/root /var/lib/mysql /home/mezinster /backup/system-2026-08-04.fsa'
```

Expected: 13 GB free on `/`, against a largest single staged item of ~5.1 GB (the fsarchiver image, encrypted in place). If free space has dropped below ~8 GB, stage on `/backup` (18 GB free) instead by changing `mktemp -d /var/tmp/...` to `/backup/...`.

- [ ] **Step 4: Run it**

```bash
ssh mezin 'bash -s' < ops/archive-once.sh
```

Expected: four `verified, sha256 …` lines and `ALL FOUR ARCHIVES VERIFIED`. Roughly 7 GB uploaded; on this host expect tens of minutes.

- [ ] **Step 5: Prove the MySQL copy is actually a working database**

The strongest available check, and the one that matters most because nothing will regenerate this. Mirrors `ops/db-restore-scratch.sh` — a throwaway container beside production, destroyed after:

```bash
# On the operator's machine, with a private key.
# ACCT: the value discovered in Task 3 Step 0.
ACCT=<account>
azcopy copy "https://${ACCT}.blob.core.windows.net/archive-once/2026-08-14/mysql-datadir.tar.zst.age" /tmp/m.age
age -d -i ~/encounter-archive-primary.key /tmp/m.age | tar --zstd -x -C /tmp
docker run --rm -d --name mysql-scratch \
  -v /tmp/mysql:/var/lib/mysql \
  -e MYSQL_ALLOW_EMPTY_PASSWORD=1 mysql:8
sleep 30
docker exec mysql-scratch mysql -e "SHOW DATABASES; SELECT COUNT(*) FROM wordpress.wp_posts;"
docker rm -f mysql-scratch
rm -rf /tmp/mysql /tmp/m.age
```

Expected: `wordpress` appears in `SHOW DATABASES`, and `wp_posts` returns a row count. A non-zero count is the proof that the cold copy captured a usable database rather than an empty directory — which is the exact failure the original draft would have shipped.

- [ ] **Step 6: Record the digests and the restore path**

Add `docs/runbooks/restore.md` §8, filling in the four real sha256 values from Step 4:

```markdown
## 8. The one-off archive (the frozen WordPress estate)

Written once on 2026-08-14 to `archive-once/2026-08-14/`. Never updated, never expires — the
lifecycle rule applies only to `archive-daily/`. Nothing regenerates these.

| Blob | sha256 (ciphertext) |
|---|---|
| `wordpress-tree.tar.zst.age` | <fill in> |
| `mysql-datadir.tar.zst.age` | <fill in> |
| `home-mezinster.tar.zst.age` | <fill in> |
| `system-2026-08-04.fsa.age` | <fill in> |

The MySQL copy was taken cold (server stopped since 2026-08-04) and verified on 2026-08-14 by
restoring it into a throwaway `mysql:8` container and counting `wordpress.wp_posts`. The
fsarchiver image is a bare-metal image of the OS only: it predates the MySQL shutdown by
fifteen hours, so the database inside it is torn. Use `mysql-datadir.tar.zst.age` for the
database, always.
```

- [ ] **Step 7: Update `ops/README.md` and commit**

Add to the first table:

```markdown
| `archive-once.sh` | Run ONCE, by hand. Archives the frozen WordPress estate. Refuses to run if MySQL is up. |
```

```bash
git add ops/archive-once.sh ops/README.md docs/runbooks/restore.md
git commit -m "One-off archive of the frozen estate, with a cold-MySQL guard"
```

---

### Task 6: Rehearse the restore — the blocking precondition

**Files:**
- Modify: `docs/runbooks/restore.md` (§7 completion, rehearsal record)

This is the spec's one remaining blocking precondition. **Task 7 must not start until this passes.** A recovery procedure that has never been executed is a hypothesis, and this one now has a decryption step in the middle — the classic place for an untested procedure to fail.

- [ ] **Step 1: Restore the daily archive to a scratch directory, from nothing but the runbook**

Follow `docs/runbooks/restore.md` §7 literally, on the operator's machine, without referring to this plan. Using the runbook as the only source is the point: it is what a person will have in the actual emergency.

```bash
mkdir /tmp/rehearsal && cd /tmp/rehearsal
# ... follow §7 ...
tar --zstd -tf host-state.tar.zst | wc -l
```

Expected: the archive decrypts and lists. **If any step of §7 is wrong, incomplete or ambiguous, fix §7 — that is the deliverable of this task**, not the successful restore.

- [ ] **Step 2: Verify the pieces that matter individually**

```bash
cd /tmp/rehearsal && tar --zstd -xf host-state.tar.zst
ls -la var/www/Keys/                    # three private keys + three public
test -s etc/ddclient.conf && echo "ddclient config present"
ls etc/letsencrypt/live/                # mezin.by
ls uploads/                             # Rails ActiveStorage tree
ls etc/systemd/system/                  # our four units
```

Expected: all five present. Anything missing is a bug in Task 4's `tar` argument list, not in the rehearsal.

- [ ] **Step 3: Time it, and write the number down**

The spec claims "1–3 hours against roughly 30 minutes" for a full rebuild. That figure is currently a guess. Record the actual elapsed time of the archive half of the restore; a rebuild estimate nobody has measured is the same kind of hypothesis this task exists to retire.

- [ ] **Step 4: Record the rehearsal**

Append to `docs/runbooks/restore.md` §7:

```markdown
### Rehearsal record

| Date | By | Outcome | Elapsed |
|---|---|---|---|
| <fill in> | <fill in> | decrypted and extracted; Keys, ddclient, letsencrypt, uploads and units all present | <fill in> |

Re-rehearse whenever the archive's contents change (Task 4's `tar` list) or the age recipients
change. A restore path is only proven for the shape it was proven against.
```

- [ ] **Step 5: Clean up and commit**

```bash
rm -rf /tmp/rehearsal
git add docs/runbooks/restore.md
git commit -m "Rehearse the archive restore and record it"
```

---

### Task 7: Retire the vault

**Files:** none in the repo. Azure control plane only.

**Gated on Task 6.** Do not start this until the rehearsal in Task 6 has passed and is recorded. Until then the $7.48 is buying a restore path that works without anyone having practised it, which is exactly what the replacement does not yet have.

- [ ] **Step 1: Confirm the replacement has actually been running**

```bash
ssh mezin 'bash -s' < ops/archive-verify.sh
```

Expected: **at least 7 consecutive daily archives** listed, plus the four `archive-once` blobs. One successful run is not evidence of a schedule; a week is. Do not shorten this.

- [ ] **Step 2: Confirm the timer has not been quietly failing**

```bash
ssh mezin 'systemctl list-timers --all --no-pager | grep encounter
           sudo journalctl -u encounter-engine-archive.service --since "8 days ago" | grep -cE "FATAL|Failed" || echo "0 failures"'
```

Expected: the timer listed with a NEXT time, and `0 failures`.

- [ ] **Step 3: Stop protection, keeping the existing recovery points**

```powershell
$vault = Get-AzRecoveryServicesVault -Name 'vault712'
Set-AzRecoveryServicesVaultContext -Vault $vault
$item = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM
Disable-AzRecoveryServicesBackupProtection -Item $item -Confirm:$false
```

**Retains** the 12 existing recovery points while stopping new ones and the protected-instance fee. Deliberately not `-RemoveRecoveryPoints`: the cheap, reversible step first.

- [ ] **Step 4: Verify billing actually stopped**

Wait for the next full billing day, then re-run the cost query that produced the table in the spec. Expected: the `Backup - Azure VM Protected Instance - EU West` meter drops to zero. **If it does not, the vault has not actually been retired** and the whole exercise has added a backup without removing a cost.

- [ ] **Step 5: Only after Step 4 confirms, decide on the old recovery points**

Deleting them is irreversible and saves only the storage component. Keep them until the new archives have a track record measured in months. Record the decision and its date in the spec rather than leaving it implicit.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Tier 1 — archive, written once | 5 |
| Tier 2 — daily, enumerated set | 4 |
| Staged and verified, not streamed | 4 (Steps 1, 3) |
| Retention 90 daily, by lifecycle policy | 3 (Step 4) |
| Encryption, `age`, public key only, two recipients | 2, and used in 4 and 5 |
| Rehearsal must include decrypting | 6 |
| Storage account to GRS | 3 (Step 2) |
| Precondition: rebuild path rehearsed | 6, gating 7 |
| Retire the vault | 7 |
| Open question: second recipient's location | Blocking input, and Task 2 Step 2 |
| Open question: is `/var/www/root` retired for good | Task 5 Step 5 verifies the archive hard either way |

**Known gap, deliberately left:** the spec's full-rebuild estimate (1–3 hours) is measured only for the archive half, in Task 6 Step 3. A complete bare-metal rehearsal — provision, `kamal setup`, wal-g restore, untar — would cost a scratch VM and several hours. That is a separate exercise; this plan proves the part that is new, and says so rather than implying more coverage than it has.
