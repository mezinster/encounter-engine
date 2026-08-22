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
set -euo pipefail
RG="${RG:-MEZINEU}"
VM="${VM:-web}"

ID="$(az vm show -g "$RG" -n "$VM" --query id -o tsv)"
SIZE="$(az vm show -g "$RG" -n "$VM" --query hardwareProfile.vmSize -o tsv)"
LOC="$(az vm show -g "$RG" -n "$VM" --query location -o tsv)"

# list-skus, not the deprecated list-sizes, which warns on every invocation.
CAPS="$(az vm list-skus -l "$LOC" --size "$SIZE" --resource-type virtualMachines \
  --query "[0].capabilities[?name=='vCPUs' || name=='MemoryGB'].[name,value]" -o tsv)"
VCPU="$(awk '$1=="vCPUs"    {print $2}' <<<"$CAPS")"
RAM="$(awk  '$1=="MemoryGB" {print $2}' <<<"$CAPS")"

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
