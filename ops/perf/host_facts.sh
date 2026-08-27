#!/usr/bin/env bash
# The host's shape and its CPU credit standing, at the moment of the run.
#
# The credit fields look like noise and are not. This is a burstable VM: the
# same load against a full credit bank and a drained one gives different
# answers, and a k6 summary knows nothing about it. Without them, two runs a
# month apart could differ by host shape, by game, by code -- or purely by how
# idle the machine happened to be beforehand.
#
# Read BEFORE load is applied. Afterwards it would record the balance the run
# itself produced, which is a different fact wearing the same name.
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
