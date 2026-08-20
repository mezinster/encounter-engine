#!/usr/bin/env bash
#
# Gathers everything ops/vmscale/policy.rb needs and prints it as one JSON
# document on stdout. Every `az` call in the VM scaling system lives here, and
# no threshold, comparison or verdict does -- the shell gathers, the Ruby
# decides. See docs/superpowers/specs/2026-08-20-vm-scaling-track-1-design.md.
#
# Requires: az (already logged in) and jq. Both are present on ubuntu-latest.
set -euo pipefail

RG="${RG:-MEZINEU}"
VM="${VM:-web}"
LADDER="${LADDER:-ops/vmscale/ladder.json}"
BUDGET_CEILING_USD="${BUDGET_CEILING_USD:-45}"
BASELINE_USD="${BASELINE_USD:-7.5}"

ID="$(az vm show -g "$RG" -n "$VM" --query id -o tsv)"
SIZE="$(az vm show -g "$RG" -n "$VM" --query hardwareProfile.vmSize -o tsv)"
OPTIONS="$(az vm list-vm-resize-options -g "$RG" -n "$VM" --query '[].name' -o json)"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FROM_3H="$(date -u -d '3 hours ago'  +%Y-%m-%dT%H:%M:%SZ)"
FROM_7D="$(date -u -d '7 days ago'   +%Y-%m-%dT%H:%M:%SZ)"
FROM_14D="$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)"

window() {  # $1 = interval, $2 = start time
  az monitor metrics list --resource "$ID" \
     --metric "Percentage CPU" "Available Memory Bytes" "CPU Credits Remaining" \
     --interval "$1" --start-time "$2" --end-time "$NOW" \
     --aggregation Average Minimum -o json
}

W3H="$(window PT5M "$FROM_3H")"
W14D="$(window PT1H "$FROM_14D")"

# What "30% of peak credits" is measured against. Taken as an observed maximum
# rather than assumed from the SKU, because the banked ceiling depends on how
# long the VM has been up.
CREDITS_MAX_7D="$(az monitor metrics list --resource "$ID" \
    --metric "CPU Credits Remaining" --interval PT1H \
    --start-time "$FROM_7D" --end-time "$NOW" --aggregation Maximum -o json \
  | jq '[.value[0].timeseries[0].data[] | .maximum // empty] | max // 0')"

# The Activity Log is a SUBSCRIPTION-level resource and this identity is scoped
# to one VM, so this query may legitimately be forbidden. It must not be fatal
# -- but it must not be silent either, so the failure is reported in the output
# and policy.rb says on every verdict that the cooldown is not in force.
#
# Microsoft.Compute/virtualMachines/write also covers any VM update, not only a
# resize. Erring wide is correct: the worst case is an unrelated tag edit
# postponing a proposal by up to 48 hours.
ACTIVITY_READABLE=true
if ! LAST_RESIZE="$(az monitor activity-log list --resource-id "$ID" --offset 30d \
      --query "sort_by([?authorization.action=='Microsoft.Compute/virtualMachines/write' && status.value=='Succeeded'], &eventTimestamp)[-1].eventTimestamp" \
      -o tsv 2>/dev/null)"; then
  ACTIVITY_READABLE=false
  LAST_RESIZE=""
fi
[ "$LAST_RESIZE" = "None" ] && LAST_RESIZE=""

# A point for an interval Azure had no data for arrives with its aggregation key
# ABSENT, not zero. `select(has($key))` drops those. This is load-bearing: a
# missing `minimum` on Available Memory Bytes coerced to 0 would manufacture the
# most severe breach the engine can see, out of nothing.
jq -n \
  --arg     size        "$SIZE" \
  --argjson options     "$OPTIONS" \
  --argjson ladder      "$(cat "$LADDER")" \
  --argjson ceiling     "$BUDGET_CEILING_USD" \
  --argjson baseline    "$BASELINE_USD" \
  --arg     now         "$NOW" \
  --arg     last        "$LAST_RESIZE" \
  --argjson readable    "$ACTIVITY_READABLE" \
  --argjson credits_max "$CREDITS_MAX_7D" \
  --argjson w3h         "$W3H" \
  --argjson w14d        "$W14D" \
  '
  def pick($src; $metric; $key; $out):
    [ $src.value[]
      | select(.name.value == $metric)
      | .timeseries[0].data[]
      | select(has($key))
      | { t: .timeStamp, ($out): .[$key] } ];

  def shape($src):
    {
      cpu_percent:            pick($src; "Percentage CPU";         "average"; "avg"),
      available_memory_bytes: pick($src; "Available Memory Bytes"; "minimum"; "min"),
      cpu_credits_remaining:  pick($src; "CPU Credits Remaining";  "minimum"; "min")
    };

  {
    current_size:           $size,
    resize_options:         $options,
    ladder:                 $ladder,
    budget_ceiling_usd:     $ceiling,
    baseline_usd:           $baseline,
    now_utc:                $now,
    last_resize_utc:        (if $last == "" then null else $last end),
    activity_log_readable:  $readable,
    metrics: (
      shape($w3h)
      + { credits_max_7d: $credits_max, hourly_14d: shape($w14d) }
    )
  }'
