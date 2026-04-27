#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

if [ ! -f "$SCRIPT_DIR/setup.conf" ]; then
  echo "Error: setup.conf not found in $SCRIPT_DIR"
  exit 1
fi
source "$SCRIPT_DIR/setup.conf"

PING_TABLE="${PING_TABLE:-ping_results}"

target_ip=""
source_ip=""
interface=""
count=""
timeout=1
check_only=false

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
    --count)
      require_value "$1" "${2:-}"
      count="$2"
      shift 2
      ;;
    --timeout)
      require_value "$1" "${2:-}"
      timeout="$2"
      shift 2
      ;;
    --check-only)
      check_only=true
      shift
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

ping_args=(ping -W "$timeout")
if [ -n "$count" ]; then
  ping_args+=(-c "$count")
fi
if [ -n "$source_ip" ]; then
  ping_args+=(-I "$source_ip")
elif [ -n "$interface" ]; then
  ping_args+=(-I "$interface")
fi
ping_args+=("$target_ip")

if [ "$check_only" = true ]; then
  "${ping_args[@]}" >/dev/null 2>&1
  exit $?
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

stdbuf -oL -eL "${ping_args[@]}" | while IFS= read -r line; do
  if [[ $line =~ time=([0-9.]+)[[:space:]]ms ]]; then
    timestamp=$(date +"%Y-%m-%d %H:%M:%S.%3N")
    latency="${BASH_REMATCH[1]}"
    "${mysql_cmd[@]}" -e "INSERT INTO \`$PING_TABLE\` (timestamp, latency) VALUES ('$timestamp', $latency);" 2>/dev/null || \
      echo "Warning: failed to insert ping sample at $timestamp"
  fi
done
