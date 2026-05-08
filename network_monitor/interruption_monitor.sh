#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

if [ ! -f "$SCRIPT_DIR/setup.conf" ]; then
  echo "Error: setup.conf not found in $SCRIPT_DIR"
  exit 1
fi
source "$SCRIPT_DIR/setup.conf"

INTERRUPTIONS_TABLE="${INTERRUPTIONS_TABLE:-interruptions}"

target_ip=""
source_ip=""
interface=""

require_value() {
  local flag="$1"
  local value="${2:-}"
  if [ -z "$value" ]; then
    echo "Error: $flag requires a value."
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target-ip)
      require_value "$1" "${2:-}"
      target_ip="$2"
      shift 2
      ;;
    --source-ip)
      require_value "$1" "${2:-}"
      source_ip="$2"
      shift 2
      ;;
    --interface)
      require_value "$1" "${2:-}"
      interface="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [ -z "$target_ip" ]; then
  echo "Error: --target-ip is required."
  exit 1
fi

db_host="${DB_HOST:-}"
db_port="${DB_PORT:-}"

mysql_cmd=(mysql -u "$DB_USER" -p"$DB_PASS")
if [ -n "$db_host" ]; then
  mysql_cmd+=(-h "$db_host")
fi
if [ -n "$db_port" ]; then
  mysql_cmd+=(-P "$db_port")
fi
mysql_cmd+=("$DB_NAME")

ping_args=(ping -c 1 -W 2)
if [ -n "$source_ip" ]; then
  ping_args+=(-I "$source_ip")
elif [ -n "$interface" ]; then
  ping_args+=(-I "$interface")
fi
ping_args+=("$target_ip")

kill_descendants() {
  local parent_pid="$1"
  local signal="${2:-TERM}"
  local child_pid

  for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null || true); do
    kill_descendants "$child_pid" "$signal"
    kill "-$signal" "$child_pid" 2>/dev/null || true
  done
}

first_failure_time=0
first_success_after_down_time=0
disconnected=false
consecutive_failures=0
consecutive_successes=0
failure_threshold=5
recovery_threshold=3
min_interruption_duration=2.0

cleanup() {
  local status=$?
  kill_descendants "$$" TERM
  wait 2>/dev/null || true
  exit "$status"
}

trap cleanup INT TERM EXIT

while true; do
  if "${ping_args[@]}" >/dev/null 2>&1; then
    consecutive_failures=0
    consecutive_successes=$((consecutive_successes + 1))

    if $disconnected && [ "$first_success_after_down_time" = "0" ]; then
      first_success_after_down_time=$(date +%s.%N)
    fi

    if $disconnected && [ $consecutive_successes -ge $recovery_threshold ]; then
      interruption_time=$(awk "BEGIN {printf \"%.3f\", $first_success_after_down_time - $first_failure_time}")
      if [ -n "$interruption_time" ] && [ "$(awk "BEGIN {print ($interruption_time >= $min_interruption_duration)}")" = "1" ]; then
        timestamp=$(date +"%Y-%m-%d %H:%M:%S.%3N")
        "${mysql_cmd[@]}" -e "INSERT INTO \`$INTERRUPTIONS_TABLE\` (timestamp, interruption_time) VALUES ('$timestamp', $interruption_time);" 2>/dev/null || \
          echo "Warning: failed to insert interruption at $timestamp"
      fi
      disconnected=false
      consecutive_successes=0
      first_failure_time=0
      first_success_after_down_time=0
    elif ! $disconnected; then
      consecutive_successes=0
      first_failure_time=0
    fi
  else
    consecutive_successes=0
    consecutive_failures=$((consecutive_failures + 1))

    if [ "$first_failure_time" = "0" ]; then
      first_failure_time=$(date +%s.%N)
    fi

    if ! $disconnected && [ $consecutive_failures -ge $failure_threshold ]; then
      disconnected=true
      first_success_after_down_time=0
    fi
  fi
  sleep 1
done

trap - INT TERM EXIT
