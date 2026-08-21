#!/usr/bin/env bash
# Measures what THIS generator's network costs, before any load is applied.
#
# The generator is selectable, so a result from a GitHub runner and one from a
# westeurope VM are not the same measurement. Measured 2026-08-21: a warm
# request cost 94ms from a laptop in Georgia and 13.5ms from a VM in the app's
# own region, against an application time of 16-17ms. Recording this per run is
# what lets those two results be compared at all.
#
# WARM connections only. k6 reuses connections, so a cold-handshake number would
# overstate what a run actually pays -- from Georgia the same request measured
# 300ms cold and 94ms warm, and the cold figure describes nothing k6 does. curl
# reuses the connection across URLs given in one invocation, which is why the
# URL is passed twice and only the second timing is kept.
#
# Exits non-zero if it cannot measure. That is deliberate and the caller must
# treat it as fatal: a result with no baseline cannot be compared to anything,
# and is not worth the traffic it would cost to produce.
set -euo pipefail
URL="${1:?usage: baseline.sh <url>}"
SAMPLES="${SAMPLES:-5}"

readings=()
for _ in $(seq 1 "$SAMPLES"); do
  warm="$(curl -fsS -o /dev/null -o /dev/null -w '%{time_total}\n' "$URL" "$URL" 2>/dev/null | tail -1)" || {
    echo "baseline: could not reach $URL" >&2
    exit 1
  }
  readings+=("$warm")
done

printf '%s\n' "${readings[@]}" | sort -n | awk '
  { a[NR] = $1 }
  END {
    if (NR == 0) { print "baseline: no samples" > "/dev/stderr"; exit 1 }
    printf "{\"baseline_warm_ms\": %.1f}\n", a[int(NR/2)+1] * 1000
  }'
