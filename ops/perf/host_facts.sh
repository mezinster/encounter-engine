#!/usr/bin/env bash
# The host's shape and its CPU credit standing, at the moment of the run.
#
# The credit fields look like noise and are not. This is a burstable VM: the
# same load against a full credit bank and a drained one gives different
# answers, and a k6 summary knows nothing about it. Without them, two runs a
# month apart could differ by host shape, by game, by code -- or purely by how
# idle the machine happened to be beforehand.
#
# CALLED TWICE, and the two calls are different facts wearing similar names.
#
#   ./host_facts.sh              -> the host's shape and the balance the run
#                                   STARTS with. Must run before any load: taken
#                                   afterwards it would record the balance the
#                                   run itself produced.
#   RUN_SECONDS=2430 ./host_facts.sh after
#                                -> what the run COST. Emits only the two credit
#                                   fields, for the caller to merge onto the
#                                   document from the first call.
#
# The second call exists because `hold` could not answer its own question
# without it. That scenario is 40 minutes of steady play, and the thing it is
# for is what an hour does to a burstable VM's credit bank -- yet version 2 of
# the record carried the starting balance alone. Establishing that the run of
# 2026-08-27 cost essentially nothing (287.5 of 288 at its lowest, back to 288.0
# by the end, steady CPU 9-13% against a 20% baseline) meant querying Azure by
# hand the next day. Metric retention is 93 days and the record is meant to
# outlive that by years.
#
# TWO readings after, not one, and the minimum is the load-bearing half: a bank
# that dipped during the run and recovered by the end reads as untouched if you
# only look at the end. On the 2026-08-27 hold run the entire cost landed in one
# five-minute bucket -- the login burst at t=0 -- and an end-only reading would
# have missed it completely.
#
# TWO credit fields, not one, and the second is what makes the first mean
# anything. "CPU Credits Remaining" is an absolute COUNT, not a percentage --
# a Standard_B1ms banks up to 288, so a reading of 287.7 is a nearly full tank
# rather than an alarming number. Different sizes have different ceilings, so a
# bare count cannot be compared across shapes; the observed 7-day maximum is the
# denominator that lets a reader normalise. ops/vmscale/policy.rb takes the same
# approach, calling it credits_max_7d.
#
# ops/vmscale/gather.sh already reads these for the scaling policy. This is the
# same queries kept separate, because that script returns a much larger document
# shaped for policy.rb rather than for a record.
#
# Every az call below is read-only and VM-scoped: `az vm show` and
# `az monitor metrics list` against one virtual machine, which is exactly what
# ee-vmscale-reader-oidc holds (Reader + Monitoring Reader on `web`, and
# nothing else). Keep it that way. The NSG identity that the rest of the probe
# runs under, ee-deploy-oidc, cannot read any of this and is not meant to --
# see the comment on the workflow step that calls this script.
set -euo pipefail
RG="${RG:-MEZINEU}"
VM="${VM:-web}"
MODE="${1:-start}"

ID="$(az vm show -g "$RG" -n "$VM" --query id -o tsv)"
SIZE="$(az vm show -g "$RG" -n "$VM" --query hardwareProfile.vmSize -o tsv)"
LOC="$(az vm show -g "$RG" -n "$VM" --query location -o tsv)"

# Read from ops/vmscale/ladder.json, not from `az vm list-skus`.
#
# Not a preference -- the az call cannot work here. `list-skus` reads
# /subscriptions/<id>/providers/Microsoft.Compute/skus, a SUBSCRIPTION-scoped
# resource, while every identity this repository gives to CI is scoped to a
# single VM or a single NSG. Buying two integers that are already committed in
# this repository would mean widening a credential from one VM to the whole
# subscription, which is a bad trade in the direction that matters.
#
# The ladder is the same file ops/vmscale/policy.rb decides against, so the two
# cannot disagree about what a Standard_B1ms is. A size that is not on it yields
# null rather than a guess, on the same reasoning as the credit fields below:
# absent data is never read as reassuring, and a shape nobody has costed is
# exactly the shape a reader should be told nothing about.
LADDER="${LADDER:-$(dirname "$0")/../vmscale/ladder.json}"
VCPU="$(jq -r --arg s "$SIZE" '.[] | select(.size == $s) | .vcpu    // empty' "$LADDER")"
RAM="$( jq -r --arg s "$SIZE" '.[] | select(.size == $s) | .ram_gib // empty' "$LADDER")"

credit_metric() {
  az monitor metrics list --resource "$ID" \
    --metric "CPU Credits Remaining" --aggregation "$1" \
    --interval "$2" --offset "$3" \
    --query "value[0].timeseries[0].data[?$4!=null] | $5" -o tsv 2>/dev/null || true
}

if [ "$MODE" = "after" ]; then
  # The window has to cover the whole run and nothing much before it. Azure
  # takes `--offset` as a duration back from now, so RUN_SECONDS is rounded UP
  # to whole minutes and given 10 minutes of margin: the metric pipeline lags a
  # few minutes, and a window that stops short of the run's own start would
  # report the calm after the burst as the whole story. Floor of 15m so a very
  # short aborted run still gets a usable window.
  SECS="${RUN_SECONDS:-0}"
  case "$SECS" in ''|*[!0-9]*) SECS=0 ;; esac
  MINS=$(( (SECS + 59) / 60 + 10 ))
  [ "$MINS" -ge 15 ] || MINS=15
  END="$(credit_metric Minimum PT5M 30m minimum '[-1].minimum')"
  MIN="$(credit_metric Minimum PT5M "${MINS}m" minimum 'min_by(@, &minimum).minimum')"
  jq -n --arg end "${END:-}" --arg min "${MIN:-}" --arg win "${MINS}m" \
    'def num($s): if $s == "" or $s == "None" then null else ($s | tonumber) end;
     { cpu_credits_remaining_end: num($end),
       cpu_credits_min_during:    num($min),
       cpu_credits_window:        $win }'
  exit 0
fi

# Absent data is never read as reassuring: a missing reading is UNKNOWN, and
# null says so. Defaulting to 0 would mean "credits exhausted", the opposite
# conclusion, and would make an unmeasured run look like a throttled one.
NOW="$(credit_metric Minimum PT5M 30m minimum '[-1].minimum')"
MAX7D="$(credit_metric Maximum PT1H 7d maximum 'max_by(@, &maximum).maximum')"

jq -n \
  --arg size "$SIZE" --arg vcpu "${VCPU:-}" --arg ram "${RAM:-}" \
  --arg now "${NOW:-}" --arg max7d "${MAX7D:-}" \
  'def num($s): if $s == "" or $s == "None" then null else ($s | tonumber) end;
   { size: $size,
     vcpu:    num($vcpu),
     ram_gib: num($ram),
     cpu_credits_remaining_start: num($now),
     cpu_credits_max_7d:          num($max7d) }'
