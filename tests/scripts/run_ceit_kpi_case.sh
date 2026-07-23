#!/usr/bin/env bash
set -u -o pipefail

if [ "$#" -lt 7 ] || [ "$#" -gt 8 ]; then
  echo "usage: $0 OUTDIR PATH RADIO SRC DST LOCAL_IFACE PORT [REMOTE_IFACE]" >&2
  exit 2
fi

outdir="$1"
path_name="$2"
radio="$3"
src="$4"
dst="$5"
iface="$6"
port="$7"
remote_iface="${8:-$iface}"
ssh_host="${SSH_HOST:-10.10.27.10}"
case_dir="$outdir/${path_name}_${radio}"
mkdir -p "$case_dir"
commands="$case_dir/commands.log"
errors="$case_dir/errors.log"
active_pid=""

cleanup() {
  if [ -n "$active_pid" ]; then
    kill "$active_pid" 2>/dev/null || true
    wait "$active_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

log_cmd() { printf '%s\n' "$*" >> "$commands"; }

run_iperf() {
  local name="$1"
  shift
  local server_log="$case_dir/${name}_server.txt"
  local json_log="$case_dir/${name}.json"
  log_cmd "ssh $ssh_host timeout 50s iperf3 -s -1 -B $dst -p $port"
  ssh "$ssh_host" "timeout 50s iperf3 -s -1 -B '$dst' -p '$port'" >"$server_log" 2>&1 &
  local ssh_pid=$!
  active_pid="$ssh_pid"
  sleep 1
  log_cmd "timeout 45s iperf3 -c $dst -B $src -p $port -J $*"
  if ! timeout 45s iperf3 -c "$dst" -B "$src" -p "$port" -J "$@" >"$json_log" 2>>"$errors"; then
    printf 'FAILED: %s\n' "$name" >>"$errors"
  fi
  kill "$ssh_pid" 2>/dev/null || true
  wait "$ssh_pid" 2>/dev/null || true
  active_pid=""
  sleep 1
}

date --iso-8601=seconds >"$case_dir/start_time.txt"
log_cmd "ip route get $dst from $src"
ip route get "$dst" from "$src" >"$case_dir/route_get.txt" 2>&1
ip route >"$case_dir/routing.txt" 2>&1
ip -br addr >"$case_dir/interfaces.txt" 2>&1

log_cmd "ping -I $src -c 100 -i 0.2 -W 2 $dst"
ping -I "$src" -c 100 -i 0.2 -W 2 "$dst" >"$case_dir/ping.txt" 2>&1 || printf 'FAILED: ping\n' >>"$errors"

for rep in 1 2 3; do
  run_iperf "tcp_forward_${rep}" -t 30
done
for rep in 1 2 3; do
  run_iperf "tcp_reverse_${rep}" -t 30 -R
done

run_iperf "tcp_forward_p4" -t 30 -P 4
run_iperf "tcp_reverse_p4" -t 30 -P 4 -R

for rate in 400M 500M 600M; do
  run_iperf "udp_forward_${rate}" -u -b "$rate" -t 30
done

# Short tool-native sample, kept separate from the KPI repetitions.
nm_port=$((port + 1000))
log_cmd "timeout 15s network_monitor2 $dst --source-ip $src --interface $iface --port $nm_port --duration 5 --tcp"
ssh "$ssh_host" "timeout 20s network_monitor2 --server --bind-ip '$dst' --interface '$remote_iface' --port '$nm_port'" >"$case_dir/network_monitor2_server.txt" 2>&1 &
nm_server_pid=$!
active_pid="$nm_server_pid"
sleep 2
timeout 15s network_monitor2 "$dst" --source-ip "$src" --interface "$iface" --port "$nm_port" --duration 5 --tcp >"$case_dir/network_monitor2_client.txt" 2>&1 || printf 'FAILED: network_monitor2\n' >>"$errors"
kill "$nm_server_pid" 2>/dev/null || true
wait "$nm_server_pid" 2>/dev/null || true
active_pid=""

date --iso-8601=seconds >"$case_dir/end_time.txt"
