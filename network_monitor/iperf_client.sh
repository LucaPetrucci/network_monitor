#!/bin/bash

# Source setup.conf
source /opt/network_monitor/setup.conf

# Initialize variables
interface=""
target_ip=""
bandwidth=""
port=""
mode="udp"
packet_size=""
db_host="${DB_HOST:-}"
db_port="${DB_PORT:-}"

usage() {
  echo "Usage: $0 -i <interface> -t <target_ip> -p <port> [-b <bandwidth>] [-m <mode>] [-l <packet_size>]"
  echo "  -b: Bandwidth limit for UDP runs"
  echo "  -m: Protocol mode (udp|tcp, default: udp)"
  echo "  -l: Packet size to pass via iperf3 -l"
}

while getopts "i:t:b:p:m:l:" opt; do
  case $opt in
    i) interface="$OPTARG" ;;
    t) target_ip="$OPTARG" ;;
    b) bandwidth="$OPTARG" ;;
    p) port="$OPTARG" ;;
    m) mode="$OPTARG" ;;
    l) packet_size="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage; exit 1 ;;
  esac
done

if [ -z "$interface" ] || [ -z "$target_ip" ] || [ -z "$port" ]; then
  echo "Error: Missing required parameters."
  usage
  exit 1
fi

mode="$(echo "$mode" | tr '[:upper:]' '[:lower:]')"
if [[ "$mode" != "udp" && "$mode" != "tcp" ]]; then
  echo "Error: Invalid mode '$mode'. Expected 'udp' or 'tcp'."
  exit 1
fi

if [ -n "$packet_size" ] && ! [[ "$packet_size" =~ ^[0-9]+$ ]]; then
  echo "Error: Packet size must be a positive integer."
  exit 1
fi

if [ "$mode" = "tcp" ] && [ -n "$bandwidth" ]; then
  echo "⚠️  Bandwidth (-b) is ignored in TCP mode."
  bandwidth=""
fi

# Get the local IP address
local_ip=$(ip -4 addr show dev "$interface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -z "$local_ip" ]; then
  echo "Error: Could not retrieve IP address for interface $interface"
  exit 1
fi

echo "Using interface: $interface"
echo "Local IP address: $local_ip"
echo "Target IP address: $target_ip"
echo "Bandwidth: ${bandwidth:-not specified}"
echo "Port: $port"
echo "Mode: $mode"
if [ -n "$packet_size" ]; then
  echo "Packet size: $packet_size"
fi

start_time=$(date +%s.%N)

iperf_args=("-c" "$target_ip" "-p" "$port" "-t" "0" "-f" "m" "-i" "1" "-R")
if [ "$mode" = "udp" ]; then
  iperf_args+=("-u")
  if [ -n "$bandwidth" ]; then
    iperf_args+=("-b" "$bandwidth")
  fi
fi
if [ -n "$packet_size" ]; then
  iperf_args+=("-l" "$packet_size")
fi

executed_command="iperf3 $(printf '%q ' "${iperf_args[@]}")"
executed_command=${executed_command% }

escape_sql() {
  local value="$1"
  printf '%s' "${value//"'"/"''"}"
}

escaped_command=$(escape_sql "$executed_command")

if [ -n "$packet_size" ]; then
  packet_size_sql="$packet_size"
else
  packet_size_sql="NULL"
fi

extended_columns_supported=""

detect_schema_capabilities() {
  local mysql_cmd=(mysql -u "$DB_USER" -p"$DB_PASS")
  if [ -n "$db_host" ]; then
    mysql_cmd+=(-h "$db_host")
  fi
  if [ -n "$db_port" ]; then
    mysql_cmd+=(-P "$db_port")
  fi
  mysql_cmd+=("$DB_NAME")

  local has_executed_command has_protocol has_packet_size
  has_executed_command=$("${mysql_cmd[@]}" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='iperf_results' AND COLUMN_NAME='executed_command';" 2>/dev/null || echo 0)
  has_protocol=$("${mysql_cmd[@]}" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='iperf_results' AND COLUMN_NAME='protocol';" 2>/dev/null || echo 0)
  has_packet_size=$("${mysql_cmd[@]}" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='iperf_results' AND COLUMN_NAME='packet_size';" 2>/dev/null || echo 0)

  if [ "$has_executed_command" = "1" ] && [ "$has_protocol" = "1" ] && [ "$has_packet_size" = "1" ]; then
    extended_columns_supported="yes"
  else
    extended_columns_supported="no"
  fi
}

insert_sample() {
  local timestamp="$1"
  local bitrate="$2"
  local jitter="${3:-0}"
  local loss="${4:-0}"
  local mysql_cmd=(mysql -u "$DB_USER" -p"$DB_PASS")

  if [ -n "$db_host" ]; then
    mysql_cmd+=(-h "$db_host")
  fi
  if [ -n "$db_port" ]; then
    mysql_cmd+=(-P "$db_port")
  fi
  mysql_cmd+=("$DB_NAME")

  if [ "$extended_columns_supported" = "yes" ]; then
    "${mysql_cmd[@]}" -e \
      "INSERT INTO iperf_results (timestamp, bitrate, jitter, lost_percentage, executed_command, protocol, packet_size) VALUES ('$timestamp', $bitrate, $jitter, $loss, '$escaped_command', '$mode', $packet_size_sql);" 2>/dev/null || \
      echo "⚠️  Failed to insert sample at $timestamp"
  else
    "${mysql_cmd[@]}" -e \
      "INSERT INTO iperf_results (timestamp, bitrate, jitter, lost_percentage) VALUES ('$timestamp', $bitrate, $jitter, $loss);" 2>/dev/null || \
      echo "⚠️  Failed to insert sample at $timestamp"
  fi
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

udp_regex='\[[[:space:]]*[0-9]+\][[:space:]]+([0-9.]+)-([0-9.]+)[[:space:]]+sec[[:space:]]+[0-9.]+[[:space:]]+[KMG]?Bytes[[:space:]]+([0-9.]+)[[:space:]]+([KMG]?)bits/sec[[:space:]]+([0-9.]+)[[:space:]]+ms[[:space:]]+([0-9]+)/([0-9]+)[[:space:]]\(([0-9.]+)%\)'
throughput_regex='\[[[:space:]]*[0-9]+\][[:space:]]+([0-9.]+)-([0-9.]+)[[:space:]]+sec[[:space:]]+[0-9.]+[[:space:]]+[KMG]?Bytes[[:space:]]+([0-9.]+)[[:space:]]+([KMG]?)bits/sec'

detect_schema_capabilities

stdbuf -oL -eL iperf3 "${iperf_args[@]}" | while IFS= read -r line; do
  echo "DEBUG: $line"
  if [ "$mode" = "udp" ] && [[ $line =~ $udp_regex ]]; then
    elapsed_end="${BASH_REMATCH[2]}"
    bitrate_raw="${BASH_REMATCH[3]}"
    unit="${BASH_REMATCH[4]}"
    jitter="${BASH_REMATCH[5]}"
    lost_percentage="${BASH_REMATCH[8]}"

    bitrate=$(normalize_bitrate "$bitrate_raw" "$unit")
    measurement_time=$(awk -v base="$start_time" -v offset="$elapsed_end" 'BEGIN {printf "%.3f", base + offset}')
    timestamp=$(date -d "@$measurement_time" +"%Y-%m-%d %H:%M:%S.%3N")

    insert_sample "$timestamp" "$bitrate" "$jitter" "$lost_percentage"
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
