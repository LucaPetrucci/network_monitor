#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_HOST="${SSH_HOST:-10.10.27.10}"
RESULTS_ROOT="${RESULTS_ROOT:-$REPO_ROOT/results}"
LOCAL_CEIT_SCRIPT="${LOCAL_CEIT_SCRIPT:-/home/tuser/scripts/test_ceit}"
REMOTE_CEIT_SCRIPT="${REMOTE_CEIT_SCRIPT:-/home/tuser/scripts/test_ceit}"
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $0 [--dry-run]

Runs the complete, repeatable KPI campaign:
  1. CEIT gateway: 10.10.42.11 -> 10.10.22.10
  2. Bypass TN0:   10.10.28.11 -> 10.10.28.10
  3. Bypass TN1:   10.10.29.11 -> 10.10.29.10

The initial routing is restored on exit. VLAN27 is never modified.
The common NUC2/NUC1 sudo password is requested once and kept only in memory.

Optional environment variables:
  SSH_HOST             NUC1 management host (default: 10.10.27.10)
  RESULTS_ROOT         Output parent directory (default: <repo>/results)
  LOCAL_CEIT_SCRIPT    CEIT route script on NUC2
  REMOTE_CEIT_SCRIPT   CEIT route script on NUC1
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

if [ "$DRY_RUN" = true ]; then
  cat <<EOF
Dry run: no commands will be executed and no network state will change.

CEIT:
  NUC2: sudo $LOCAL_CEIT_SCRIPT
  NUC1: ssh $SSH_HOST sudo -S $REMOTE_CEIT_SCRIPT
  Test: 10.10.42.11 -> 10.10.22.10 (radio not identifiable)

Bypass:
  NUC2: delete only 10.10.22.0/24 via 10.10.42.41
  NUC1: delete only 10.10.42.0/24 via 10.10.22.40
  Test TN0: 10.10.28.11 -> 10.10.28.10
  Test TN1: 10.10.29.11 -> 10.10.29.10

Final action: restore the exact initial test routes on both NUCs.
EOF
  exit 0
fi

for command_name in ip ping iperf3 ssh sudo timeout python3 network_monitor2; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: required command '$command_name' was not found." >&2
    exit 1
  fi
done

if [ ! -t 0 ]; then
  echo "Error: run this command from an interactive terminal." >&2
  exit 1
fi

if ! python3 -c "import PIL" >/dev/null 2>&1; then
  echo "Error: Python Pillow is required to generate REPORT_EN.pdf." >&2
  exit 1
fi

if [ ! -x "$SCRIPT_DIR/run_ceit_kpi_case.sh" ]; then
  echo "Error: $SCRIPT_DIR/run_ceit_kpi_case.sh is not executable." >&2
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/generate_kpi_report_en.py" ]; then
  echo "Error: report generator not found." >&2
  exit 1
fi

echo "Checking SSH management access to NUC1 ($SSH_HOST)..."
if ! ssh -o ConnectTimeout=10 "$SSH_HOST" "true"; then
  echo "Error: SSH management access to NUC1 failed." >&2
  exit 1
fi

sudo_password=""
printf 'Sudo password for NUC2 and NUC1: ' >/dev/tty
IFS= read -r -s sudo_password </dev/tty
printf '\n' >/dev/tty

local_sudo() {
  printf '%s\n' "$sudo_password" | sudo -S -p '' -- "$@"
}

remote_sudo() {
  local remote_command
  printf -v remote_command '%q ' "$@"
  printf '%s\n' "$sudo_password" \
    | ssh "$SSH_HOST" "sudo -S -p '' -- ${remote_command% }"
}

echo "Validating the single sudo password on NUC2..."
if ! printf '%s\n' "$sudo_password" | sudo -S -p '' -v; then
  sudo_password=""
  unset sudo_password
  echo "Error: sudo authentication failed on NUC2." >&2
  exit 1
fi
echo "Validating the same sudo password on NUC1..."
if ! printf '%s\n' "$sudo_password" | ssh "$SSH_HOST" "sudo -S -p '' -v"; then
  sudo_password=""
  unset sudo_password
  echo "Error: sudo authentication failed on NUC1." >&2
  exit 1
fi

timestamp="$(date +%Y%m%d_%H%M%S)"
result_dir="$RESULTS_ROOT/kpi_ceit_$timestamp"
mkdir -p "$result_dir"
support_dir="$result_dir/campaign_logs"
mkdir -p "$support_dir"
commands_log="$support_dir/commands.log"
errors_log="$support_dir/errors.log"
: >"$commands_log"
: >"$errors_log"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

record_command() {
  printf '%s\n' "$*" >>"$commands_log"
}

initial_local_route="$(ip route show 10.10.22.0/24)"
initial_remote_route="$(ssh "$SSH_HOST" "ip route show 10.10.42.0/24")"
initial_default_route="$(ip route show default)"
restore_required=true

ip -br addr >"$support_dir/interfaces_initial.txt"
ip route >"$support_dir/routing_initial.txt"
ip rule show >"$support_dir/rules_initial.txt"
ssh "$SSH_HOST" "ip -br addr; ip route; ip rule show" >"$support_dir/nuc1_initial.txt"
local_sudo sed -n '1,260p' "$LOCAL_CEIT_SCRIPT" >"$support_dir/test_ceit_nuc2.txt"
log "Saving the NUC1 CEIT script..."
remote_sudo sed -n '1,260p' "$REMOTE_CEIT_SCRIPT" 2>&1 \
  | tee "$support_dir/test_ceit_nuc1.txt"

restore_routes() {
  if [ "$restore_required" != true ]; then
    return
  fi
  log "Restoring the initial test routes..."

  local_sudo ip route del 10.10.22.0/24 via 10.10.42.41 2>/dev/null || true
  local_sudo ip route del 10.10.22.0/24 via 10.10.42.31 2>/dev/null || true
  remote_sudo ip route del 10.10.42.0/24 via 10.10.22.40 2>/dev/null || true
  remote_sudo ip route del 10.10.42.0/24 via 10.10.22.30 2>/dev/null || true

  if [ -n "$initial_local_route" ]; then
    read -r -a local_route_words <<<"$initial_local_route"
    local_sudo ip route replace "${local_route_words[@]}"
  fi
  if [ -n "$initial_remote_route" ]; then
    read -r -a remote_route_words <<<"$initial_remote_route"
    remote_sudo ip route replace "${remote_route_words[@]}"
  fi

  ip route >"$support_dir/routing_final.txt"
  ip -br addr >"$support_dir/interfaces_final.txt"
  ssh "$SSH_HOST" "ip route; ip -br addr" >"$support_dir/nuc1_final.txt"
  restore_required=false
}

on_exit() {
  status=$?
  if [ "$restore_required" = true ]; then
    restore_routes || true
  fi
  if [ "$status" -ne 0 ]; then
    printf 'Campaign exited with status %s\n' "$status" >>"$errors_log"
  fi
  sudo_password=""
  unset sudo_password
}
trap on_exit EXIT
trap 'exit 130' INT TERM

check_management() {
  local current_default
  current_default="$(ip route show default)"
  if [ "$current_default" != "$initial_default_route" ]; then
    echo "Error: management default route changed unexpectedly." >&2
    return 1
  fi
  ip route get "$SSH_HOST" | grep -q "dev enp114s0" || {
    echo "Error: NUC1 management route is not using enp114s0." >&2
    return 1
  }
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" "true" || {
    echo "Error: SSH management connectivity was lost." >&2
    return 1
  }
}

record_unreachable() {
  local path_name="$1"
  local radio="$2"
  local src="$3"
  local dst="$4"
  local iface="$5"
  local reason_text="$6"
  local case_dir="$result_dir/${path_name}_${radio}"

  mkdir -p "$case_dir"
  date --iso-8601=seconds >"$case_dir/start_time.txt"
  ip route get "$dst" from "$src" >"$case_dir/route_get.txt" 2>&1 || true
  ip route >"$case_dir/routing.txt"
  ip -br addr >"$case_dir/interfaces.txt"
  printf '%s\n' "$reason_text" >"$case_dir/case_status.txt"
  printf '%s\n' \
    "ping -I $src -c 100 -i 0.2 -W 2 $dst" \
    "timeout 10s iperf3 -c $dst -B $src -J -t 30" \
    >"$case_dir/commands.log"
  ping -I "$src" -c 100 -i 0.2 -W 2 "$dst" >"$case_dir/ping.txt" 2>&1 || true
  timeout 10s iperf3 -c "$dst" -B "$src" -J -t 30 \
    >"$case_dir/tcp_forward_1.json" 2>"$case_dir/errors.log" || true
  ssh "$SSH_HOST" "ping -I '$dst' -c 5 -W 2 '$src'" \
    >"$case_dir/ping_reverse_diagnostic.txt" 2>&1 || true
  date --iso-8601=seconds >"$case_dir/end_time.txt"
}

run_path() {
  local path_name="$1"
  local radio="$2"
  local src="$3"
  local dst="$4"
  local local_iface="$5"
  local remote_iface="$6"
  local port="$7"
  local reason_text="$8"

  log "Pre-check: $path_name $radio ($src -> $dst)"
  if ! ping -I "$src" -c 5 -W 2 "$dst" >/dev/null 2>&1; then
    log "Path unavailable; recording diagnostics and skipping throughput tests."
    record_unreachable "$path_name" "$radio" "$src" "$dst" "$local_iface" "$reason_text"
    return
  fi

  log "Path reachable; running the complete KPI matrix (approximately 6 minutes)."
  SSH_HOST="$SSH_HOST" "$SCRIPT_DIR/run_ceit_kpi_case.sh" \
    "$result_dir" "$path_name" "$radio" "$src" "$dst" \
    "$local_iface" "$port" "$remote_iface"
  printf '%s\n' "TESTED" >"$result_dir/${path_name}_${radio}/case_status.txt"
}

log "Results directory: $result_dir"
log "Applying CEIT routes on both NUCs..."
record_command "sudo $LOCAL_CEIT_SCRIPT"
record_command "ssh $SSH_HOST sudo -S $REMOTE_CEIT_SCRIPT"
local_sudo "$LOCAL_CEIT_SCRIPT" >"$support_dir/ceit_script_nuc2.log" 2>&1
log "Applying the NUC1 CEIT route..."
remote_sudo "$REMOTE_CEIT_SCRIPT" 2>&1 \
  | tee "$support_dir/ceit_script_nuc1.log"
check_management
ip route >"$support_dir/routing_ceit_nuc2.txt"
ssh "$SSH_HOST" "ip route" >"$support_dir/routing_ceit_nuc1.txt"
run_path \
  "CEIT" "GATEWAY" "10.10.42.11" "10.10.22.10" \
  "enp114s0.42" "enp114s0.22" "5310" \
  "NOT EXECUTABLE: CEIT END-TO-END CONNECTIVITY FAILED"

log "Enabling direct bypass by deleting only the CEIT routes..."
record_command "sudo ip route del 10.10.22.0/24 via 10.10.42.41"
record_command "ssh $SSH_HOST sudo -S ip route del 10.10.42.0/24 via 10.10.22.40"
local_sudo ip route del 10.10.22.0/24 via 10.10.42.41 2>/dev/null || true
log "Removing the NUC1 CEIT route..."
remote_sudo ip route del 10.10.42.0/24 via 10.10.22.40 2>&1 \
  | tee "$support_dir/bypass_script_nuc1.log" || true
check_management
ip route >"$support_dir/routing_bypass_nuc2.txt"
ssh "$SSH_HOST" "ip route" >"$support_dir/routing_bypass_nuc1.txt"

run_path \
  "BYPASS" "TN0" "10.10.28.11" "10.10.28.10" \
  "enp114s0.28" "enp114s0.28" "5311" \
  "NOT EXECUTABLE: TN0 CONNECTIVITY OR ARP FAILED"
run_path \
  "BYPASS" "TN1" "10.10.29.11" "10.10.29.10" \
  "enp114s0.29" "enp114s0.29" "5312" \
  "NOT EXECUTABLE: TN1 CONNECTIVITY OR ARP FAILED"

restore_routes
if ! diff -u "$support_dir/routing_initial.txt" "$support_dir/routing_final.txt" \
  >"$support_dir/routing_restore.diff"; then
  echo "Warning: final routing differs from initial routing; see routing_restore.diff." \
    | tee -a "$errors_log"
fi
check_management

python3 "$SCRIPT_DIR/generate_kpi_report_en.py" "$result_dir"
python3 "$SCRIPT_DIR/markdown_report_to_pdf.py" \
  "$result_dir/REPORT_EN.md" "$result_dir/REPORT_EN.pdf"
log "Campaign complete."
log "English report: $result_dir/REPORT_EN.md"
log "PDF report:     $result_dir/REPORT_EN.pdf"
log "CSV results:    $result_dir/results.csv"
