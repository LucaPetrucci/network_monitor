#!/usr/bin/env bash
set -u -o pipefail

# Cedex base-measurement campaign for NUC2 -> NUC1.
# Edit only the config block below for your lab setup.

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Command used for every test case.
NETWORK_MONITOR_CMD="network_monitor2"

# network_monitor2 arguments shared by all cases.
PORT=5050
DURATION=60
PAUSE=20
REPETITIONS=1
DRY_RUN=false
LOG_DIR="$REPO_ROOT/tests/logs"

# Edit these lists directly when you want to narrow the campaign.
# Use comma-separated strings, for example: PROTOCOLS="udp,tcp".
PROTOCOLS="udp,tcp"
BANDWIDTHS="1M,10M,50M,100M,250M,500M,750M,1G"
PACKET_SIZES="500,1000,1472"

# Empty means "use all test paths".
VLAN_FILTER=""

# Format: vlan|channel|source_ip_nuc2|target_ip_nuc1.
TEST_PATHS="28|5|10.10.28.11|10.10.28.10,29|6|10.10.29.11|10.10.29.10"

log_file=""

log() {
  local ts
  ts="$(date '+%F %T')"
  printf '[%s] %s\n' "$ts" "$*" | tee -a "$log_file"
}

contains_item() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

load_list() {
  local raw_value="${1:-}"
  local -n list_ref="$2"
  local normalized="$raw_value"
  normalized="${normalized//;/,}"
  normalized="${normalized//$'\n'/,}"
  normalized="${normalized//$'\r'/,}"
  IFS=, read -r -a list_ref <<< "$normalized"
}

sanitize_list() {
  local -n list_ref="$1"
  local cleaned=()
  local item
  for item in "${list_ref[@]}"; do
    item="${item//[[:space:]]/}"
    if [ -n "$item" ]; then
      cleaned+=("$item")
    fi
  done
  list_ref=("${cleaned[@]}")
}

validate_positive_int() {
  local value="$1"
  local label="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
    echo "Error: $label must be a positive integer." >&2
    exit 1
  fi
}

load_list "$PROTOCOLS" PROTOCOLS
load_list "$BANDWIDTHS" BANDWIDTHS
load_list "$PACKET_SIZES" PACKET_SIZES
load_list "$VLAN_FILTER" VLAN_FILTER
load_list "$TEST_PATHS" TEST_PATHS

sanitize_list PROTOCOLS
sanitize_list BANDWIDTHS
sanitize_list PACKET_SIZES
sanitize_list VLAN_FILTER
sanitize_list TEST_PATHS

validate_positive_int "$PORT" "port"
validate_positive_int "$DURATION" "duration"
validate_positive_int "$PAUSE" "pause"
validate_positive_int "$REPETITIONS" "repetitions"

if [ "${#PROTOCOLS[@]}" -eq 0 ]; then
  echo "Error: at least one protocol is required." >&2
  exit 1
fi

if [ "${#PACKET_SIZES[@]}" -eq 0 ]; then
  echo "Error: at least one packet size is required." >&2
  exit 1
fi

if ! command -v "$NETWORK_MONITOR_CMD" >/dev/null 2>&1; then
  echo "Error: '$NETWORK_MONITOR_CMD' not found in PATH." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
log_file="$LOG_DIR/nuc2_to_nuc1_base_measurements_$(date +%Y%m%d_%H%M%S).log"
: > "$log_file"

log "Starting NUC2 -> NUC1 base-measurement campaign"
log "Log file: $log_file"
log "Command: $NETWORK_MONITOR_CMD"
log "Duration: $DURATION"
log "Pause: $PAUSE"
log "Repetitions per combination: $REPETITIONS"
log "Protocols: ${PROTOCOLS[*]}"
log "Bandwidths: ${BANDWIDTHS[*]}"
log "Packet sizes: ${PACKET_SIZES[*]}"
if [ "${#VLAN_FILTER[@]}" -gt 0 ]; then
  log "VLAN filter: ${VLAN_FILTER[*]}"
else
  log "VLAN filter: all configured TEST_PATHS entries"
fi

selected_paths=()
for entry in "${TEST_PATHS[@]}"; do
  IFS='|' read -r vlan channel source_ip target_ip <<< "$entry"
  if [ "${#VLAN_FILTER[@]}" -gt 0 ] && ! contains_item "$vlan" "${VLAN_FILTER[@]}"; then
    continue
  fi
  selected_paths+=("$entry")
done

if [ "${#selected_paths[@]}" -eq 0 ]; then
  log "No TEST_PATHS entries matched the selected VLAN filter."
  exit 1
fi

count_cases() {
  local total=0
  local path_entry protocol packet_size bandwidth rep
  for path_entry in "${selected_paths[@]}"; do
    for protocol in "${PROTOCOLS[@]}"; do
      for packet_size in "${PACKET_SIZES[@]}"; do
        for bandwidth in "${BANDWIDTHS[@]}"; do
          for ((rep = 1; rep <= REPETITIONS; rep++)); do
            total=$((total + 1))
          done
        done
      done
    done
  done
  printf '%s' "$total"
}

total_cases="$(count_cases)"
log "Total planned cases: $total_cases"

format_command() {
  local -a cmd=("$@")
  local printable
  printf -v printable '%q ' "${cmd[@]}"
  printf '%s' "${printable% }"
}

run_one_case() {
  local vlan="$1"
  local channel="$2"
  local source_ip="$3"
  local target_ip="$4"
  local protocol="$5"
  local packet_size="$6"
  local bandwidth="$7"
  local repetition="$8"
  local case_no="$9"
  local -a cmd=(
    "$NETWORK_MONITOR_CMD"
    "$target_ip"
    --source-ip "$source_ip"
    --port "$PORT"
    --duration "$DURATION"
    --packet-size "$packet_size"
  )

  if [ "$protocol" = "udp" ]; then
    cmd+=(--udp --bandwidth "$bandwidth")
  else
    cmd+=(--tcp)
  fi

  local bandwidth_note="$bandwidth"
  if [ "$protocol" != "udp" ]; then
    bandwidth_note="${bandwidth} (ignored for tcp)"
  fi

  log "Case $case_no/$total_cases vlan=$vlan channel=$channel protocol=$protocol packet_size=$packet_size bandwidth=${bandwidth_note} repetition=$repetition/$REPETITIONS src=$source_ip dst=$target_ip"
  log "Command: $(format_command "${cmd[@]}")"

  if [ "$DRY_RUN" = true ]; then
    log "Dry-run only, command not executed."
    return 0
  fi

  if "${cmd[@]}" 2>&1 | tee -a "$log_file"; then
    log "Case $case_no completed successfully."
    return 0
  fi

  local status=$?
  log "Case $case_no failed with exit code $status."
  return 0
}

case_no=0
for entry in "${selected_paths[@]}"; do
  IFS='|' read -r vlan channel source_ip target_ip <<< "$entry"
  log "Starting VLAN $vlan / channel $channel ($source_ip -> $target_ip)"

  for protocol in "${PROTOCOLS[@]}"; do
    for packet_size in "${PACKET_SIZES[@]}"; do
      for bandwidth in "${BANDWIDTHS[@]}"; do
        for ((repetition = 1; repetition <= REPETITIONS; repetition++)); do
          case_no=$((case_no + 1))
          run_one_case "$vlan" "$channel" "$source_ip" "$target_ip" "$protocol" "$packet_size" "$bandwidth" "$repetition" "$case_no"
          if [ "$DRY_RUN" = false ] && [ "$case_no" -lt "$total_cases" ]; then
            sleep "$PAUSE"
          fi
        done
      done
    done
  done
done

log "Campaign completed. Successful or failed runs were logged in $log_file."
