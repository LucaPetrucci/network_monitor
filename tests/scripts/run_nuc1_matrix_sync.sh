#!/usr/bin/env bash
set -euo pipefail

IFACE="${IFACE:-enp114s0}"
LOCAL_IP="${LOCAL_IP:-10.10.27.10}"
TARGET_IP="${TARGET_IP:-10.10.27.11}"
PORT="${PORT:-5050}"
RUN_SECONDS="${RUN_SECONDS:-120}"
PAUSE_SECONDS="${PAUSE_SECONDS:-5}"

# Optional shared start time in HH:MM:SS (same value on both NUCs).
START_AT="${START_AT:-}"
START_DELAY_SEC="${START_DELAY_SEC:-60}"

if [[ -z "$START_AT" ]]; then
  START_AT="$(date -d "+${START_DELAY_SEC} seconds" +%H:%M:%S)"
fi

echo "[NUC1] iface=$IFACE local=$LOCAL_IP target=$TARGET_IP port=$PORT"
echo "[NUC1] run_seconds=$RUN_SECONDS pause_seconds=$PAUSE_SECONDS"
echo "[NUC1] START_AT=$START_AT"

echo "[NUC1] Waiting for start time..."
while [[ "$(date +%H:%M:%S)" < "$START_AT" ]]; do
  sleep 0.2
done

echo "[NUC1] START $(date '+%F %T')"

for mode in udp tcp; do
  for size in 500 1000 1472; do
    echo "[NUC1] CASE mode=$mode size=$size begin $(date '+%T')"
    timeout "${RUN_SECONDS}s" bash -lc "printf '\n' | network_monitor2 -i $IFACE -t $TARGET_IP -S $LOCAL_IP -I $IFACE -p $PORT -m $mode -l $size" || true
    echo "[NUC1] CASE mode=$mode size=$size end   $(date '+%T')"
    sleep "$PAUSE_SECONDS"
  done
done

echo "[NUC1] DONE $(date '+%F %T')"
