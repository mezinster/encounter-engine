# Running a load test against production

For someone under pressure who did not build this. Commands are
copy-pasteable. Read §0 before you seed anything.

This drives a real production run: real accounts, real database rows, real
CPU on the shared host. Nothing here is a dry run. If in doubt, stop and ask
rather than guess — see `CLAUDE.local.md`'s working style if this is your
first time touching this codebase.

---

## 0. Before you start

**This app shares its host with other tenants.** `ansible/playbook.yml`'s own
header records it: danted on port 1080, squid-family proxies on
3128-3130/8080-8081, and two inReach APRS forwarders, none of which belong to
this application. We are a tenant on that box, not the owner. That is *why*
the ramp phase (§4) is built to stop itself at the first sign of an SLO
breach instead of running to failure, and it is why §6 below hands a human,
not k6, the final word on whether to keep going.

**The generator holds live production credentials the moment the manifest
lands on it** — a password for every seeded captain, plus every level's
answer codes. §3 provisions it closed to the internet on purpose; §7 shows
you how to prove that before you trust it. Do not widen the NSG.

**Never commit a manifest, and never paste one — or a password, IP address,
or token from this run — into this file, a commit, or a chat log.** This
runbook only ever holds commands and placeholders like `<ip>`.

What you need before starting:
- `az` CLI logged in to the subscription that owns resource group `mezineu`.
- SSH access to the production host (the `mezin` alias — see
  `docs/runbooks/restore.md` if that isn't set up yet).
- `bundle exec kamal app exec` working from your machine (same prerequisites
  as an ordinary deploy — see `docs/manual/deployment.en.md`).
- Superadmin access to `/admin/load_test` on the production instance.
- `k6` on your own machine only if you want to smoke-test locally first
  (`export PATH="$HOME/.local/bin:$PATH"` — see `load_test/README.md`). The
  generator VM gets its own `k6` from cloud-init; you do not need to install
  anything on it by hand.

---

## 1. Pre-flight

Do all three before touching `/admin/load_test`. Skipping any of these turns
"we ran a load test" into "we broke a real game."

### 1a. Confirm no real game is scheduled

```bash
bundle exec kamal app exec -i "bin/rails console"
```

Paste, adjusting the window to cover the whole time you expect to be running
(ramp + hold + margin — 6 hours is generous):

```ruby
window = Time.now..(Time.now + 6.hours)
runs = GameRun.where(starts_at: window, is_testing: false)
if runs.any?
  puts "ABORT -- #{runs.count} real game(s) start in this window:"
  runs.each { |r| puts "  game_run #{r.id}: game #{r.game_id} starts_at #{r.starts_at}" }
else
  puts "clear: no real games scheduled in the window"
end
```

If this prints anything other than "clear", **stop**. Pick a different night
or a different window.

### 1b. Confirm the backup is current

```bash
ssh mezin 'bash -s' < ops/db-list.sh
```

Read the WAL chain line — it must say `OK` — and confirm there is a base
backup from the last 24 hours. Full detail: `docs/runbooks/restore.md` §2.
This does not touch anything; it only tells you what you could recover to if
tonight goes badly wrong.

### 1c. Record the idle baseline — p95 and starting CPU credits

**The ramp and hold numbers only mean something next to this baseline.**
Without it, a slow app under load and an app that was already slow cannot be
told apart. This is a box-health check against an anonymous route, not a
like-for-like comparand for the ramp/hold numbers below — those drive the
authenticated, per-team `/play/:id` path, which costs more per request than
`/` does.

p95 with no load, ~10 minutes, from your own machine:

```bash
for i in $(seq 1 120); do
  curl -o /dev/null -s -w '%{time_total}\n' https://game.mezin.eu/
  sleep 5
done | sort -n | awk '{a[NR]=$1} END { print "idle p95 (s):", a[int(NR*0.95)] }'
```

Starting CPU credit balance (find the VM name first if you don't already
have it memorized — this resource group also hosts other things):

```bash
az vm list --resource-group mezineu --output table
az monitor metrics list \
  --resource-group mezineu --resource-type Microsoft.Compute/virtualMachines \
  --resource <production-vm-name> \
  --metric "CPU Credits Remaining" --interval PT1M
```

Write both numbers down somewhere outside this repository — you'll compare
against them in §5.

---

## 2. Seed the cohort

Go to `/admin/load_test` on the production instance:

1. Pick a source game to clone, and a team count (start with the top of the
   ramp ladder in mind — 120 teams matches `load_test/main.js`'s plateaus).
2. Type the cohort id into both the cohort field and the confirmation field
   — the console refuses a mismatch.
3. Submit. The screen will show the cohort id and row counts on success.
4. Download the manifest from the console (the "manifest" link/button) to
   your machine. **Do not open it in anything that logs its contents** (a
   browser devtools network tab, a shared clipboard manager) — it is full of
   live passwords.
5. **Log in by hand as one seeded captain before launching k6.** Pick any
   `email`/`password` pair from the manifest, log in at the real `/login`
   form in a browser, and confirm you land on a real play screen for the
   cloned game. This is the cheapest possible check that the seed actually
   produced something playable, before you point 120 virtual users at it.

If step 5 doesn't work — wrong password, the play screen 404s, the game
looks unstarted — **do not proceed to provisioning**. Tear the cohort down
(§8) and re-seed rather than debugging live against a broken cohort while a
generator VM burns money.

---

## 3. Provision the generator

From your own machine, in this repo:

```bash
./load_test/provision.sh create
```

This takes a few minutes. It prints the VM's public IP and a reminder of the
next two commands. Read the printed inbound-rule summary — it should say SSH
is open only from your current address. **Confirm it properly before you
copy the manifest up — §7 has the exact command and the expected output.**
Do that now, then come back here.

Copy the manifest and the k6 script up (use the IP the previous command
printed):

```bash
scp ~/Downloads/<cohort-id>.json azureuser@<ip>:~/manifest.json
scp -r load_test azureuser@<ip>:~/
```

SSH in and confirm k6 actually installed (cloud-init runs on first boot and
can take a minute or two after the VM reports "running"):

```bash
ssh azureuser@<ip> k6 version
```

If that fails right after the VM comes up, it's worth one retry after a
minute — `az vm create` returning does not mean cloud-init has finished yet.
**But if it is still failing after that, do not keep waiting: a missing `k6`
is not a timing problem, it's a sign cloud-init did not run `runcmd` at all**
(most likely `load_test/cloud-init.yml`'s `#cloud-config` header is no longer
the file's literal first line — cloud-init only recognizes it there, and
silently treats anything else as plain text with no error). Check what
actually happened on the VM instead of retrying blind:

```bash
ssh azureuser@<ip> sudo cat /var/log/cloud-init-output.log
```

---

## 4. Ramp: find the burst ceiling

On the generator (`ssh azureuser@<ip>`):

```bash
cd ~
k6 run --env PHASE=ramp --env MANIFEST=~/manifest.json load_test/main.js
```

**Do not add `--vus`, `--iterations`, or `--duration`** — the script defines
its own scenarios per phase and k6 refuses to start if you pass any of
those (`function 'default' not found in exports`). See
`load_test/README.md`'s "Running" section if you need the reason again.

This steps concurrent teams through 10 → 20 → 40 → 80 → 120, each a 30s ramp
followed by a 4-minute hold, and aborts automatically (exit code 99) if
`p(95)` crosses 2000ms or the error rate crosses 2% for 30 seconds straight.

**Record the last plateau that completed its full 4-minute hold without
aborting.** That number is the burst ceiling — the capacity of a VM that
still has a full bank of CPU credits, which is what players actually get for
the first several minutes of a real game. It is not the number that predicts
an hour into a real run; §5 gets you that one.

While this runs, watch the terminal's periodic `running (...)` progress
lines and keep an eye on Azure Monitor per §6 — don't just start it and walk
away.

---

## 5. Hold: find the sustained ceiling

**The ceiling is two numbers, not one, and reporting only the first is a
defect.** The VM is burstable (`Standard_B1s`): it banks CPU credit while
idle and spends it under load. §4's ramp measures a machine running on a
full battery — the few minutes right after a real game starts, before the
credit bank has had time to drain. The hold phase below is run deliberately
*past* credit exhaustion, and the number it gives you is the one that
predicts what teams see in hour two of a real game, once the battery is
spent. Skipping this step and reporting only the ramp's ceiling tells you
about the first five minutes of a real game and nothing about the rest of
it.

Pick `TEAMS` as roughly 70% of the ceiling you recorded in §4 (round down):

```bash
k6 run --env PHASE=hold --env TEAMS=<70pct-of-ceiling> --env MANIFEST=~/manifest.json load_test/main.js
```

This runs 40 minutes at a constant team count with **no** abort brake — that
is deliberate (`load_test/README.md`, "Mutation-testing the abort brake"):
the entire point of `hold` is to keep running past the point the ramp would
have stopped itself.

In a second terminal (your own machine, not the generator), poll the
production VM's credit balance every few minutes:

```bash
az monitor metrics list \
  --resource-group mezineu --resource-type Microsoft.Compute/virtualMachines \
  --resource <production-vm-name> \
  --metric "CPU Credits Remaining" --interval PT1M
```

**The number you actually want is the latency at the moment the credit
balance reaches zero and stays there**, not the run's overall summary line —
read it off the k6 terminal's `running (...)` output around the same
wall-clock time the credits graph flatlines. That is the sustained ceiling:
the number that predicts hour two of a real game, when the burst battery is
long gone.

---

### 5a. Reading the plateau numbers — not obvious, read this before you interpret §4's output

k6's `ramping-vus` executor starts every newly-added VU with no stagger, so
**each plateau's step-up is a synchronous burst of logins** — and every
login is a bcrypt verify, deliberately expensive. This produces three traps,
all real, all seen on this harness:

- A latency spike in the **first seconds** of a plateau's 30-second ramp
  window is **expected** and is not, by itself, evidence that the app hit a
  ceiling. It's the login burst, not steady play.
- k6's end-of-run `p(95)` is computed **across the whole run**, so five
  step-up bursts inflate it relative to the steady-play latency that
  actually matters. Read the settled four-minute portion of each plateau —
  the periodic `running (...)` progress lines, or a time-series sink via
  `--out` — rather than trusting the single aggregate `p(95)` as "the"
  ceiling.
- `abortOnFail` is likewise evaluated over the run so far, so a large enough
  login burst can trip it while steady-state latency at that plateau is
  actually fine. **If the ramp aborts immediately after a step-up, check
  whether the burst itself caused it before concluding the app is over
  capacity at that plateau** — it may just mean the next plateau up needs a
  longer or staggered ramp, not that the ceiling is the one below it.

---

## 6. Abort criteria a human owns

k6's thresholds catch what it can see in `http_req_duration` and
`http_req_failed`. They cannot see the rest of the host. **Stop the run by
hand** (Ctrl-C on the k6 process — it prints a partial summary and exits
cleanly) if any of the following show up, whether or not k6's own thresholds
have tripped:

- **CPU credits draining faster than the plateau schedule predicts.** If the
  balance is heading toward zero well before you expected the hold phase to
  reach it, something is costing more than the plan assumed — stop and
  investigate before continuing.
- **Distress in danted, the squid proxies (3128-3130, 8080-8081), or the two
  inReach APRS forwarders.** These are other tenants' services on the same
  box (`ansible/playbook.yml`). If they're slow, erroring, or their logs
  show anything unusual during the run, that's this test's CPU pressure
  spilling onto someone else's traffic — stop.
- **Any sign of a real user on the box** — a real game starting, a real
  team logging in, anything that suggests §1a's check missed something.

None of this is optional or a judgment call to defer: if you see any of
these, stop the run first and figure out what happened afterward.

---

## 7. Verify the generator is closed

**Do this right after §3 provisions the box, before you copy the manifest
up, and again any time you're unsure during the run.** The box holds live
production credentials from the moment the manifest lands on it, so this is
not a final-checklist item — it matters most right at the start.

```bash
az network nsg rule list \
  --resource-group encounter-loadgen --nsg-name loadgenNSG --output table
```

Expect **exactly one** inbound allow rule, scoped to your own `/32`. If you
see anything else — a broader source range, a second rule, an
allow-from-anywhere default — stop and fix the NSG before copying the
manifest up or running anything.

---

## 8. Teardown — mandatory

**Every run ends here, whether it went well, badly, or you aborted early.**
A cohort left standing is live production accounts with live passwords and a
publicly-visible scratch game.

1. From `/admin/load_test`, tear the cohort down (type the cohort id into
   both fields, same confirmation pattern as seeding). This also removes the
   manifest copy sitting in the container's temp directory (or, if you seeded
   from rake instead, run `bin/rails load_test:teardown[<cohort-id>]` — it
   does the same cleanup for the copy `rake` wrote).
2. **Delete your own local copy of the manifest too** — the file you
   downloaded from the console in §2 step 4 (or `scp`'d down, if you went
   that route). It carries the same live captain passwords as the copy the
   teardown above just removed, and nothing deletes it for you. The
   generator's own copy (the one you `scp`'d *up* to it in §3) does not need
   separate handling — it goes away with the resource group in step 4 below.
3. Confirm it's actually gone:
   ```bash
   bundle exec kamal app exec 'bin/rails load_test:status'
   ```
   Expect `{:cohort_id=>nil, :users=>0}`. If `cohort_id` is not nil, the
   teardown did not finish — do not walk away; go back to the console and
   retry, or use the recovery path below.
4. Destroy the generator's resource group:
   ```bash
   ./load_test/provision.sh destroy
   az group exists --name encounter-loadgen   # poll until it prints false
   ```
   `provision.sh destroy` is asynchronous (`--no-wait`) — give it a minute
   before you trust `az group exists`.
5. If Puma's memory looks high (check via `kamal app logs` or your usual
   monitoring) after a heavy run, reboot the app:
   ```bash
   bundle exec kamal app boot
   ```
   On roughly 1.1 GB of spare memory on the host, a Puma worker that grew
   under load does not necessarily shrink back on its own once the load
   stops.

### Recovery: the cohort's game was removed by hand

If someone deleted the seeded game directly (console, `bin/rails console`,
anything outside the normal teardown path) before running teardown,
`load_test:status` can no longer name the cohort — its cohort id comes from
reading the game's own name back (see `lib/load_test/seeder.rb`, `status`).
The console and the `load_test:teardown` rake task will both refuse a blank
cohort id in production, on purpose: a blank id can never be confirmed, so it
is never treated as authorised.

The way out is a deliberate, out-of-band sweep — not a rake flag, because
this is exactly the kind of action that should require someone to step
outside the normal guard on purpose:

```bash
bundle exec kamal app exec "bin/rails runner 'puts LoadTest::Seeder.teardown!(nil)'"
```

This matches (and removes) everything under the load-test e-mail domain
regardless of the game row, which is why it bypasses the id-confirmation
guard — the operator is choosing to step outside it, not being let through
it by accident. Confirm afterward with `load_test:status` same as step 2
above.

---

## Quick reference

```text
1. Pre-flight:   game_runs window check, backup check, idle p95 + CPU credit baseline
2. Seed:         /admin/load_test -> download manifest -> log in by hand as one captain
3. Provision:    ./load_test/provision.sh create   ->  scp manifest + load_test/ up (verify closed first, see 7)
4. Ramp:         k6 run --env PHASE=ramp  --env MANIFEST=~/manifest.json load_test/main.js
5. Hold:         k6 run --env PHASE=hold  --env TEAMS=<70% of ceiling> --env MANIFEST=~/manifest.json load_test/main.js
6. Abort by hand on: credit drain, co-tenant distress, any real user
7. Verify closed: az network nsg rule list --resource-group encounter-loadgen --nsg-name loadgenNSG
8. Teardown:     console teardown -> delete your local manifest copy -> load_test:status nil -> provision.sh destroy -> kamal app boot if needed
```
