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
DURATION=120
PAUSE=20
REPETITIONS=1
DRY_RUN=false
LOG_DIR="$REPO_ROOT/tests/logs"
EXPORT_DIR="$REPO_ROOT/export"
AUTO_EXPORT=true
RUN_TIMEOUT=0

# Edit these lists directly when you want to narrow the campaign.
# Use comma-separated strings, for example: PROTOCOLS="udp,tcp".
PROTOCOLS="udp,tcp"
# BANDWIDTHS="1M"
BANDWIDTHS="1M,10M,50M,100M,250M,500M,750M,1G"
PACKET_SIZES="500,1000,1460"
# PACKET_SIZES="500"

# Empty means "use all test paths".
VLAN_FILTER=""

# Format: vlan|channel|source_ip_nuc2|target_ip_nuc1.
TEST_PATHS="28|5|10.10.28.11|10.10.28.10,29|6|10.10.29.11|10.10.29.10"

usage() {
  cat <<EOF
Usage: $0 [--dry-run]

Runs the NUC2 -> NUC1 Cedex base-measurement matrix. UDP bandwidths are
tested independently; TCP is run once per path, packet size, and repetition.

Options:
  --dry-run  Print every planned case without generating traffic.
  -h, --help Show this help.
EOF
}

case "${1:-}" in
  "")
    ;;
  --dry-run)
    DRY_RUN=true
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

log_file=""
cleanup_in_progress=false
campaign_start_ts=""
campaign_end_ts=""
campaign_start_file_ts=""
campaign_end_file_ts=""
case_report_lines=()

kill_descendants() {
  local parent_pid="$1"
  local signal="${2:-TERM}"
  local child_pid

  for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null || true); do
    kill_descendants "$child_pid" "$signal"
    kill "-$signal" "$child_pid" 2>/dev/null || true
  done
}

cleanup() {
  local status=$?

  if [ "$cleanup_in_progress" = true ]; then
    exit "$status"
  fi
  cleanup_in_progress=true

  trap - INT TERM EXIT

  if [ "$DRY_RUN" = false ]; then
    kill_descendants "$$" TERM
    sleep 1
    kill_descendants "$$" KILL
  fi

  exit "$status"
}

trap cleanup INT TERM EXIT

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

if [ "$RUN_TIMEOUT" -le 0 ]; then
  RUN_TIMEOUT=$((DURATION + 30))
fi
validate_positive_int "$RUN_TIMEOUT" "run timeout"

if [ "${#PROTOCOLS[@]}" -eq 0 ]; then
  echo "Error: at least one protocol is required." >&2
  exit 1
fi

for protocol in "${PROTOCOLS[@]}"; do
  if [ "$protocol" != "udp" ] && [ "$protocol" != "tcp" ]; then
    echo "Error: unsupported protocol '$protocol'; use udp or tcp." >&2
    exit 1
  fi
done

if contains_item udp "${PROTOCOLS[@]}" && [ "${#BANDWIDTHS[@]}" -eq 0 ]; then
  echo "Error: at least one bandwidth is required when UDP is enabled." >&2
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
campaign_start_ts="$(date '+%F %T')"
campaign_start_file_ts="$(date +%Y%m%d_%H%M%S)"
log "Campaign start: $campaign_start_ts"
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
  local path_entry protocol packet_size rep
  for path_entry in "${selected_paths[@]}"; do
    for protocol in "${PROTOCOLS[@]}"; do
      for packet_size in "${PACKET_SIZES[@]}"; do
        if [ "$protocol" = "udp" ]; then
          total=$((total + (${#BANDWIDTHS[@]} * REPETITIONS)))
        else
          for ((rep = 1; rep <= REPETITIONS; rep++)); do
            total=$((total + 1))
          done
        fi
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
  local case_started_ts bandwidth_note
  local -a cmd=(
    "$NETWORK_MONITOR_CMD"
    "$target_ip"
    --source-ip "$source_ip"
    --port "$PORT"
    --duration "$DURATION"
    --packet-size "$packet_size"
  )

  case_started_ts="$(date '+%F %T')"
  if [ "$protocol" = "udp" ]; then
    cmd+=(--udp --bandwidth "$bandwidth")
    bandwidth_note="$bandwidth"
  else
    cmd+=(--tcp)
    bandwidth_note="n/a"
  fi

  case_report_lines+=("Case $case_no started at $case_started_ts | vlan=$vlan channel=$channel protocol=$protocol packet_size=$packet_size bandwidth=$bandwidth_note repetition=$repetition/$REPETITIONS src=$source_ip dst=$target_ip")

  log "Case $case_no/$total_cases vlan=$vlan channel=$channel protocol=$protocol packet_size=$packet_size bandwidth=${bandwidth_note} repetition=$repetition/$REPETITIONS src=$source_ip dst=$target_ip"
  log "Case $case_no start time: $case_started_ts"
  log "Command: $(format_command "${cmd[@]}")"

  if [ "$DRY_RUN" = true ]; then
    log "Dry-run only, command not executed."
    return 0
  fi

  log "Run timeout: ${RUN_TIMEOUT}s"

  if timeout --preserve-status "${RUN_TIMEOUT}s" "${cmd[@]}" 2>&1 | tee -a "$log_file"; then
    log "Case $case_no completed successfully."
    return 0
  fi

  local status="${PIPESTATUS[0]:-1}"
  log "Case $case_no failed with exit code $status."
  return 0
}

case_no=0
for entry in "${selected_paths[@]}"; do
  IFS='|' read -r vlan channel source_ip target_ip <<< "$entry"
  log "Starting VLAN $vlan / channel $channel ($source_ip -> $target_ip)"

  for protocol in "${PROTOCOLS[@]}"; do
    for packet_size in "${PACKET_SIZES[@]}"; do
      if [ "$protocol" = "udp" ]; then
        case_bandwidths=("${BANDWIDTHS[@]}")
      else
        case_bandwidths=("")
      fi
      for bandwidth in "${case_bandwidths[@]}"; do
        for ((repetition = 1; repetition <= REPETITIONS; repetition++)); do
          case_no=$((case_no + 1))
          run_one_case "$vlan" "$channel" "$source_ip" "$target_ip" "$protocol" "$packet_size" "$bandwidth" "$repetition" "$case_no"
          if [ "$DRY_RUN" = false ] && [ "$case_no" -lt "$total_cases" ]; then
            log "Pausing $PAUSE seconds before the next case..."
            sleep "$PAUSE"
          fi
        done
      done
    done
  done
done

campaign_end_ts="$(date '+%F %T')"
campaign_end_file_ts="$(date +%Y%m%d_%H%M%S)"
log "Campaign end: $campaign_end_ts"

if [ "$DRY_RUN" = false ] && [ "$AUTO_EXPORT" = true ]; then
  mkdir -p "$EXPORT_DIR"
  export_file="$EXPORT_DIR/nuc2_to_nuc1_${campaign_start_file_ts}_to_${campaign_end_file_ts}.xlsx"
  report_file="${export_file%.xlsx}.txt"
  log "Exporting campaign window to $export_file"
  if "$NETWORK_MONITOR_CMD" --export-excel "$export_file" --start "$campaign_start_ts" --end "$campaign_end_ts" 2>&1 | tee -a "$log_file"; then
    log "Export completed successfully."
  else
    export_status="${PIPESTATUS[0]:-1}"
    log "Export failed with exit code $export_status."
  fi

  start_epoch="$(date -d "$campaign_start_ts" +%s)"
  end_epoch="$(date -d "$campaign_end_ts" +%s)"
  total_seconds=$((end_epoch - start_epoch))
  if [ "$total_seconds" -lt 0 ]; then
    total_seconds=0
  fi
  total_hours=$((total_seconds / 3600))
  total_minutes=$(((total_seconds % 3600) / 60))
  total_secs=$((total_seconds % 60))

  {
    echo "Campaign report"
    echo "Generated at: $(date '+%F %T')"
    echo "Campaign start: $campaign_start_ts"
    echo "Campaign end: $campaign_end_ts"
    printf 'Total duration: %02dh %02dm %02ds (%ss)\n' "$total_hours" "$total_minutes" "$total_secs" "$total_seconds"
    echo
    echo "Case start times:"
    if [ "${#case_report_lines[@]}" -gt 0 ]; then
      printf '%s\n' "${case_report_lines[@]}"
    else
      echo "No cases recorded."
    fi
  } > "$report_file"
  log "Wrote campaign report to $report_file"
fi

log "Campaign completed. Successful or failed runs were logged in $log_file."
