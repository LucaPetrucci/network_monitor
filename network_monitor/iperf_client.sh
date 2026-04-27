#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

if [ ! -f "$SCRIPT_DIR/setup.conf" ]; then
  echo "Error: setup.conf not found in $SCRIPT_DIR"
  exit 1
fi
source "$SCRIPT_DIR/setup.conf"

IPERF_TABLE="${IPERF_TABLE:-iperf_results}"

mode=""
target_ip=""
source_ip=""
bind_ip=""
interface=""
port=5050
duration=30
protocol="udp"
bandwidth=""
metadata=""

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
    --client)
      mode="client"
      shift
      ;;
    --server)
      mode="server"
      shift
      ;;
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
    --bind-ip)
      require_value "$1" "${2:-}"
      bind_ip="$2"
      shift 2
      ;;
    --interface)
      require_value "$1" "${2:-}"
      interface="$2"
      shift 2
      ;;
    --port)
      require_value "$1" "${2:-}"
      port="$2"
      shift 2
      ;;
    --duration)
      require_value "$1" "${2:-}"
      duration="$2"
      shift 2
      ;;
    --protocol)
      require_value "$1" "${2:-}"
      protocol="$2"
      shift 2
      ;;
    --bandwidth)
      require_value "$1" "${2:-}"
      bandwidth="$2"
      shift 2
      ;;
    --metadata)
      require_value "$1" "${2:-}"
      metadata="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [ -z "$mode" ]; then
  echo "Error: choose either --client or --server."
  exit 1
fi

if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -le 0 ]; then
  echo "Error: port must be a positive integer."
  exit 1
fi

db_host="${DB_HOST:-}"
db_port="${DB_PORT:-}"

make_mysql_cmd() {
  local name="$1"
  local -a cmd=(mysql -u "$DB_USER" -p"$DB_PASS")
  if [ -n "$db_host" ]; then
    cmd+=(-h "$db_host")
  fi
  if [ -n "$db_port" ]; then
    cmd+=(-P "$db_port")
  fi
  cmd+=("$DB_NAME")
  eval "$name=(\"\${cmd[@]}\")"
}

escape_sql() {
  local value="$1"
  printf '%s' "${value//"'"/"''"}"
}

normalize_bitrate() {
  local value="$1"
  local unit="${2^^}"
  case "$unit" in
    K)
      awk -v val="$value" 'BEGIN {printf "%.3f", val / 1000}'
      ;;
    G)
      awk -v val="$value" 'BEGIN {printf "%.3f", val * 1000}'
      ;;
    *)
      awk -v val="$value" 'BEGIN {printf "%.3f", val}'
      ;;
  esac
}

extended_columns_supported="no"
detect_schema_capabilities() {
  local -a mysql_cmd=()
  make_mysql_cmd mysql_cmd

  local has_executed_command
  local has_protocol
  local has_packet_size
  has_executed_command=$("${mysql_cmd[@]}" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='$IPERF_TABLE' AND COLUMN_NAME='executed_command';" 2>/dev/null || echo 0)
  has_protocol=$("${mysql_cmd[@]}" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='$IPERF_TABLE' AND COLUMN_NAME='protocol';" 2>/dev/null || echo 0)
  has_packet_size=$("${mysql_cmd[@]}" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='$IPERF_TABLE' AND COLUMN_NAME='packet_size';" 2>/dev/null || echo 0)

  if [ "$has_executed_command" = "1" ] && [ "$has_protocol" = "1" ] && [ "$has_packet_size" = "1" ]; then
    extended_columns_supported="yes"
  fi
}

insert_sample() {
  local timestamp="$1"
  local bitrate="$2"
  local jitter="${3:-0}"
  local loss="${4:-0}"
  local -a mysql_cmd=()
  local escaped_command

  make_mysql_cmd mysql_cmd
  escaped_command=$(escape_sql "$metadata")

  if [ "$extended_columns_supported" = "yes" ]; then
    "${mysql_cmd[@]}" -e "INSERT INTO \`$IPERF_TABLE\` (timestamp, bitrate, jitter, lost_percentage, executed_command, protocol, packet_size) VALUES ('$timestamp', $bitrate, $jitter, $loss, '$escaped_command', '$protocol', NULL);" \
      2>/dev/null || echo "Warning: failed to insert iperf sample at $timestamp"
  else
    "${mysql_cmd[@]}" -e "INSERT INTO \`$IPERF_TABLE\` (timestamp, bitrate, jitter, lost_percentage) VALUES ('$timestamp', $bitrate, $jitter, $loss);" \
      2>/dev/null || echo "Warning: failed to insert iperf sample at $timestamp"
  fi
}

detect_schema_capabilities

throughput_regex='\[[[:space:]]*[0-9]+\][[:space:]]+([0-9.]+)-([0-9.]+)[[:space:]]+sec[[:space:]]+[0-9.]+[[:space:]]+[KMG]?Bytes[[:space:]]+([0-9.]+)[[:space:]]+([KMG]?)bits/sec'
udp_regex='\[[[:space:]]*[0-9]+\][[:space:]]+([0-9.]+)-([0-9.]+)[[:space:]]+sec[[:space:]]+[0-9.]+[[:space:]]+[KMG]?Bytes[[:space:]]+([0-9.]+)[[:space:]]+([KMG]?)bits/sec[[:space:]]+([0-9.]+)[[:space:]]+ms[[:space:]]+([0-9]+)/([0-9]+)[[:space:]]+\(([0-9.]+)%\)'

if [ "$mode" = "server" ]; then
  server_args=(iperf3 -s -p "$port")
  if [ -n "$bind_ip" ]; then
    server_args+=(-B "$bind_ip")
  fi
  if [ -n "$interface" ]; then
    server_args+=(--bind-dev "$interface")
  fi

  if [ -z "$metadata" ]; then
    metadata="$(printf '%q ' "${server_args[@]}")"
    metadata="${metadata% }"
  fi

  current_stream_base_time=""
  echo "Starting iperf3 server on port $port"
  stdbuf -oL -eL "${server_args[@]}" 2>&1 | while IFS= read -r line; do
    echo "$line"
    if [[ $line =~ $throughput_regex ]]; then
      elapsed_start="${BASH_REMATCH[1]}"
      elapsed_end="${BASH_REMATCH[2]}"
      bitrate_raw="${BASH_REMATCH[3]}"
      unit="${BASH_REMATCH[4]}"

      if [ "$elapsed_start" = "0.00" ] || [ -z "$current_stream_base_time" ]; then
        current_stream_base_time=$(date +%s.%N)
      fi

      bitrate=$(normalize_bitrate "$bitrate_raw" "$unit")
      measurement_time=$(awk -v base="$current_stream_base_time" -v offset="$elapsed_end" 'BEGIN {printf "%.3f", base + offset}')
      timestamp=$(date -d "@$measurement_time" +"%Y-%m-%d %H:%M:%S.%3N")
      insert_sample "$timestamp" "$bitrate" 0 0
    fi
  done
  exit 0
fi

if [ -z "$target_ip" ]; then
  echo "Error: --target-ip is required in client mode."
  exit 1
fi

if ! [[ "$duration" =~ ^[0-9]+$ ]] || [ "$duration" -le 0 ]; then
  echo "Error: duration must be a positive integer."
  exit 1
fi

protocol="$(printf '%s' "$protocol" | tr '[:upper:]' '[:lower:]')"
if [ "$protocol" != "udp" ] && [ "$protocol" != "tcp" ]; then
  echo "Error: protocol must be udp or tcp."
  exit 1
fi

iperf_args=(iperf3 -c "$target_ip" -p "$port" -t "$duration" -f m -i 1)
if [ "$protocol" = "udp" ]; then
  iperf_args+=(-u)
  if [ -n "$bandwidth" ]; then
    iperf_args+=(-b "$bandwidth")
  fi
fi
if [ -n "$source_ip" ]; then
  iperf_args+=(-B "$source_ip")
fi

if [ -z "$metadata" ]; then
  metadata="$(printf '%q ' "${iperf_args[@]}")"
  metadata="${metadata% }"
fi

start_time=$(date +%s.%N)
echo "Running iperf3 client against $target_ip"
stdbuf -oL -eL "${iperf_args[@]}" | while IFS= read -r line; do
  echo "$line"
  if [ "$protocol" = "udp" ] && [[ $line =~ $udp_regex ]]; then
    elapsed_end="${BASH_REMATCH[2]}"
    bitrate_raw="${BASH_REMATCH[3]}"
    unit="${BASH_REMATCH[4]}"
    jitter="${BASH_REMATCH[5]}"
    loss="${BASH_REMATCH[8]}"

    bitrate=$(normalize_bitrate "$bitrate_raw" "$unit")
    measurement_time=$(awk -v base="$start_time" -v offset="$elapsed_end" 'BEGIN {printf "%.3f", base + offset}')
    timestamp=$(date -d "@$measurement_time" +"%Y-%m-%d %H:%M:%S.%3N")
    insert_sample "$timestamp" "$bitrate" "$jitter" "$loss"
  elif [[ $line =~ $throughput_regex ]]; then
    elapsed_end="${BASH_REMATCH[2]}"
    bitrate_raw="${BASH_REMATCH[3]}"
    unit="${BASH_REMATCH[4]}"

    bitrate=$(normalize_bitrate "$bitrate_raw" "$unit")
    measurement_time=$(awk -v base="$start_time" -v offset="$elapsed_end" 'BEGIN {printf "%.3f", base + offset}')
    timestamp=$(date -d "@$measurement_time" +"%Y-%m-%d %H:%M:%S.%3N")
    insert_sample "$timestamp" "$bitrate" 0 0
  fi
done
