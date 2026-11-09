#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/network-monitor-options.XXXXXX)"
install_dir="$test_dir/install"
mock_bin="$test_dir/bin"
server_pid=""

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

mkdir -p "$install_dir" "$mock_bin"
cp "$repo_root"/network_monitor/*.sh "$install_dir"/
chmod +x "$install_dir"/*.sh
ln -s "$repo_root/tests/helpers/mock_mysql.sh" "$mock_bin/mysql"
ln -s "$repo_root/tests/helpers/logging_iperf3.sh" "$mock_bin/iperf3"

printf '%s\n' \
  'DB_HOST=127.0.0.1' \
  'DB_PORT=3306' \
  'DB_NAME=test_db' \
  'DB_USER=test_user' \
  'DB_PASS=test_password' \
  'IPERF_TABLE=iperf_results' \
  'PING_TABLE=ping_results' \
  'INTERRUPTIONS_TABLE=interruptions' >"$install_dir/setup.conf"

export PATH="$mock_bin:$PATH"
export MOCK_MYSQL_LOG="$test_dir/mysql.log"
export IPERF_ARGUMENT_LOG="$test_dir/iperf_args.log"
: >"$MOCK_MYSQL_LOG"
: >"$IPERF_ARGUMENT_LOG"

port=$((20000 + ($$ % 20000)))
"$install_dir/server_launcher.sh" --server --bind-ip 127.0.0.1 --port "$port" \
  >"$test_dir/server.log" 2>&1 &
server_pid=$!

for _ in $(seq 1 30); do
  if grep -q 'Server listening' "$test_dir/server.log"; then
    break
  fi
  sleep 0.1
done
grep -q 'Server listening' "$test_dir/server.log"

"$install_dir/server_launcher.sh" 127.0.0.1 \
  --source-ip 127.0.0.1 \
  --duration 2 \
  --tcp \
  --reverse \
  --flows 4 \
  --packet-size 1400 \
  --window-size 64K \
  --port "$port" >"$test_dir/client.log" 2>&1

grep -q 'Monitoring run completed' "$test_dir/client.log"
grep -q '\[SUM\]' "$test_dir/client.log"
grep -q -- '-R' "$IPERF_ARGUMENT_LOG"
grep -q -- '-P 4' "$IPERF_ARGUMENT_LOG"
grep -q -- '-M 1400' "$IPERF_ARGUMENT_LOG"
grep -q -- '-w 64K' "$IPERF_ARGUMENT_LOG"
grep -q 'direction=reverse flows=4' "$MOCK_MYSQL_LOG"
grep -q 'traffic_source=127.0.0.1 traffic_target=127.0.0.1' "$MOCK_MYSQL_LOG"
grep -q 'packet_size=1400' "$MOCK_MYSQL_LOG"
grep -q 'window_size=64K' "$MOCK_MYSQL_LOG"
grep -q 'packet_size, window_size)' "$MOCK_MYSQL_LOG"

"$install_dir/server_launcher.sh" 127.0.0.1 \
  --source-ip 127.0.0.1 \
  --duration 2 \
  --udp \
  --bandwidth 20M \
  --flows 4 \
  --packet-size 1200 \
  --port "$port" >"$test_dir/client_udp.log" 2>&1

grep -q 'Monitoring run completed' "$test_dir/client_udp.log"
grep -q '\[SUM\]' "$test_dir/client_udp.log"
grep -q -- '-u' "$IPERF_ARGUMENT_LOG"
grep -q -- '--get-server-output' "$IPERF_ARGUMENT_LOG"

grep -q -- '-b 5M' "$IPERF_ARGUMENT_LOG"
grep -q -- '-P 4' "$IPERF_ARGUMENT_LOG"
grep -q -- '-l 1200' "$IPERF_ARGUMENT_LOG"
grep -q 'direction=forward flows=4' "$MOCK_MYSQL_LOG"
grep -q 'bandwidth=20M packet_size=1200' "$MOCK_MYSQL_LOG"

: > "$IPERF_ARGUMENT_LOG"
"$install_dir/server_launcher.sh" 127.0.0.1 \
  --source-ip 127.0.0.1 \
  --udp \
  --reverse \
  --duration 1 \
  --packet-size 1200 \
  --port "$port" >"$test_dir/client_udp_reverse.log" 2>&1
grep -q -- '-R' "$IPERF_ARGUMENT_LOG"
grep -q 'direction=reverse flows=1' "$MOCK_MYSQL_LOG"

: >"$IPERF_ARGUMENT_LOG"
"$install_dir/server_launcher.sh" 127.0.0.1 \
  --source-ip 127.0.0.1 \
  --duration 1 \
  --tcp \
  --port "$port" >"$test_dir/client_default.log" 2>&1

grep -q 'Monitoring run completed' "$test_dir/client_default.log"
if grep -Eq -- '(^| )-R( |$)|(^| )-P( |$)|(^| )-w( |$)' "$IPERF_ARGUMENT_LOG"; then
  echo 'Default TCP client unexpectedly enabled reverse, parallel flows, or window size.' >&2
  exit 1
fi
grep -q -- '-M 1460' "$IPERF_ARGUMENT_LOG"
grep -q 'direction=forward flows=1' "$MOCK_MYSQL_LOG"
grep -q 'packet_size=1460' "$MOCK_MYSQL_LOG"

if "$install_dir/server_launcher.sh" 127.0.0.1 --flows 0 >"$test_dir/invalid.log" 2>&1; then
  echo 'Expected --flows 0 to fail.' >&2
  exit 1
fi
grep -q 'between 1 and 32' "$test_dir/invalid.log"

if "$install_dir/server_launcher.sh" 127.0.0.1 --packet-size 0 >"$test_dir/invalid.log" 2>&1; then
  echo 'Expected --packet-size 0 to fail.' >&2
  exit 1
fi
grep -q 'positive integer' "$test_dir/invalid.log"

if "$install_dir/server_launcher.sh" 127.0.0.1 --port 65536 >"$test_dir/invalid.log" 2>&1; then
  echo 'Expected --port 65536 to fail.' >&2
  exit 1
fi
grep -q 'between 1 and 65535' "$test_dir/invalid.log"

if "$install_dir/server_launcher.sh" 127.0.0.1 --udp --window-size 64K >"$test_dir/invalid.log" 2>&1; then
  echo 'Expected UDP with --window-size to fail.' >&2
  exit 1
fi
grep -q 'only be used with --tcp' "$test_dir/invalid.log"

printf 'network_monitor2 option tests passed.\n'
