#!/usr/bin/env bash
# cluster-snapshot.sh — compact read-only cluster state for cron prompt injection.
#
# Runs as a `hermes cron create --script` data-collection step (see
# scripts/setup-crons.sh): stdout is injected into the agent's prompt, not
# delivered directly. Output is raw facts only — no verdict, no prose — the
# agent does the interpreting.
#
# Defensive by design: a single kubectl call failing (API server hiccup,
# CRD not installed, empty result set) must not abort the whole snapshot —
# the cron job still wants whatever sections succeeded. `set -e` stays on to
# catch real bugs in this script; every kubectl call that can legitimately
# fail/empty is individually guarded.

set -euo pipefail

export KUBECONFIG=/var/lib/leandro/kubeconfig

echo "=== cluster-snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

echo
echo "-- Nodes NotReady --"
if ! kubectl get nodes --no-headers 2>/dev/null \
  | awk '$2 !~ /^Ready/ {print}' \
  | grep -q .; then
  echo "(none)"
else
  kubectl get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {print}'
fi

echo
echo "-- Pods not Running (top 15 by restarts) --"
pods_not_running="$(kubectl get pods --all-namespaces --no-headers 2>/dev/null \
  | awk '$4 != "Running" && $4 != "Completed" {print}' || true)"
if [ -z "${pods_not_running}" ]; then
  echo "(none)"
else
  echo "${pods_not_running}" | sort -k5 -rn | head -15
fi

echo
echo "-- Warning events (last hour) --"
# No jq on this VM (not provisioned) — extract lastTimestamp via grep instead
# of parsing JSON properly. ISO-8601 UTC strings sort/compare correctly as
# plain text, so a lexicographic >= cutoff comparison is enough. Best-effort:
# events using the newer events.k8s.io eventTime field instead of
# lastTimestamp are undercounted here.
cutoff="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
warning_count=0
timestamps="$(kubectl get events --all-namespaces --field-selector type=Warning \
  -o json 2>/dev/null \
  | grep -o '"lastTimestamp": *"[^"]*"' \
  | grep -o '[0-9TZ:.-]*Z' || true)"
if [ -n "${timestamps}" ]; then
  warning_count="$(printf '%s\n' "${timestamps}" | awk -v cutoff="${cutoff}" '$0 >= cutoff' | wc -l)"
fi
echo "Warning events (cluster-wide, last hour): ${warning_count}"

echo
echo "-- PVCs not Bound --"
pvcs_not_bound="$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null \
  | awk '$3 != "Bound" {print}' || true)"
if [ -z "${pvcs_not_bound}" ]; then
  echo "(none)"
else
  echo "${pvcs_not_bound}"
fi
