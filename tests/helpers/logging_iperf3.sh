#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"${IPERF_ARGUMENT_LOG:?}"
printf '\n' >>"$IPERF_ARGUMENT_LOG"
exec /usr/bin/iperf3 "$@"
