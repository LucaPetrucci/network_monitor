#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output="$($repo_root/tests/scripts/run_nuc2_base_measurements.sh --dry-run)"

grep -q 'Total planned cases: 54' <<<"$output"

tcp_cases="$(grep -c 'protocol=tcp' <<<"$output")"
udp_cases="$(grep -c 'protocol=udp' <<<"$output")"

if [ "$tcp_cases" -ne 6 ]; then
  echo "Expected 6 TCP cases, found $tcp_cases." >&2
  exit 1
fi

if [ "$udp_cases" -ne 48 ]; then
  echo "Expected 48 UDP cases, found $udp_cases." >&2
  exit 1
fi

if grep 'protocol=tcp' <<<"$output" | grep -qv 'bandwidth=n/a'; then
  echo "A TCP matrix entry has an unexpected bandwidth value." >&2
  exit 1
fi

if grep 'protocol=tcp' <<<"$output" | grep -q -- '--bandwidth'; then
  echo "A TCP command unexpectedly contains --bandwidth." >&2
  exit 1
fi

printf 'base measurement matrix tests passed.\n'
