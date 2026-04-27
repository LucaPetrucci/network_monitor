#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PYTHON_BIN="python3"

if [ -x "$SCRIPT_DIR/.venv/bin/python3" ]; then
  PYTHON_BIN="$SCRIPT_DIR/.venv/bin/python3"
fi

if [ ! -f "$SCRIPT_DIR/setup.conf" ]; then
  echo "Error: setup.conf not found in $SCRIPT_DIR"
  exit 1
fi
source "$SCRIPT_DIR/setup.conf"

port=5050
duration=30
protocol="udp"
bandwidth="100M"
target_ip=""
source_ip=""
bind_ip=""
interface=""
export_excel=""
server_mode=false

show_help() {
  cat <<'EOF'
Usage:
  network_monitor2 --server [--bind-ip <local_ip>] [--port <port>] [--interface <iface>]
  network_monitor2 <target_ip> [--source-ip <local_ip>] [--port <port>] [--duration <seconds>] [--udp|--tcp] [--bandwidth <rate>] [--interface <iface>]
  network_monitor2 --export-excel <output.xlsx>

Description:
  Simple two-host network monitoring tool.
  - Server mode starts iperf3 server and stores server-side samples in the local DB.
  - Client mode runs ping and iperf3 toward the target and stores results in the local DB.

Options:
  --server                Run in server mode.
  --bind-ip <local_ip>    Bind iperf3 server to a specific local IP.
  --source-ip <local_ip>  Bind client ping/iperf3 traffic to a specific local IP.
  --interface <iface>     Optional interface hint for ping binding or metadata.
  --port <port>           iperf3 port (default: 5050).
  --duration <seconds>    iperf3 client duration in seconds (default: 30).
  --udp                   Use UDP for iperf3 client (default).
  --tcp                   Use TCP for iperf3 client.
  --bandwidth <rate>      UDP bandwidth for iperf3 client (default: 100M).
  --export-excel <path>   Export local DB data to an Excel workbook.
  -h, --help              Show this help.

Examples:
  network_monitor2 --server --bind-ip 10.10.28.10 --port 5050
  network_monitor2 10.10.28.11 --source-ip 10.10.28.10 --duration 60
  network_monitor2 --export-excel results.xlsx
EOF
}

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
    --server)
      server_mode=true
      shift
      ;;
    --bind-ip)
      require_value "$1" "${2:-}"
      bind_ip="$2"
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
    --udp)
      protocol="udp"
      shift
      ;;
    --tcp)
      protocol="tcp"
      shift
      ;;
    --bandwidth)
      require_value "$1" "${2:-}"
      bandwidth="$2"
      shift 2
      ;;
    --export-excel)
      require_value "$1" "${2:-}"
      export_excel="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    --*)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
    *)
      if [ -z "$target_ip" ]; then
        target_ip="$1"
        shift
      else
        echo "Unexpected argument: $1"
        show_help
        exit 1
      fi
      ;;
  esac
done

if [ -n "$export_excel" ]; then
  if [ "$server_mode" = true ] || [ -n "$target_ip" ] || [ -n "$source_ip" ] || [ -n "$bind_ip" ] || [ -n "$interface" ]; then
    echo "Error: --export-excel must be used by itself."
    exit 1
  fi
  exec "$PYTHON_BIN" "$SCRIPT_DIR/export_excel.py" "$export_excel"
fi

if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -le 0 ]; then
  echo "Error: --port must be a positive integer."
  exit 1
fi

if ! [[ "$duration" =~ ^[0-9]+$ ]] || [ "$duration" -le 0 ]; then
  echo "Error: --duration must be a positive integer."
  exit 1
fi

if [ "$protocol" = "tcp" ] && [ -n "$bandwidth" ]; then
  bandwidth=""
fi

make_metadata_string() {
  local role="$1"
  local remote="$2"
  local local_value=""

  if [ -n "$source_ip" ]; then
    local_value="$source_ip"
  elif [ -n "$bind_ip" ]; then
    local_value="$bind_ip"
  else
    local_value="auto"
  fi

  local metadata="role=$role local_ip=$local_value remote_ip=${remote:-none} port=$port protocol=$protocol"
  if [ -n "$interface" ]; then
    metadata="$metadata interface=$interface"
  fi
  if [ "$role" = "client" ]; then
    metadata="$metadata duration=${duration}s"
    if [ "$protocol" = "udp" ] && [ -n "$bandwidth" ]; then
      metadata="$metadata bandwidth=$bandwidth"
    fi
  fi

  printf '%s' "$metadata"
}

cleanup() {
  local status=$?

  if [ -n "${iperf_pid:-}" ]; then
    kill "$iperf_pid" 2>/dev/null || true
  fi
  if [ -n "${ping_pid:-}" ]; then
    kill "$ping_pid" 2>/dev/null || true
  fi
  if [ -n "${interrupt_pid:-}" ]; then
    kill "$interrupt_pid" 2>/dev/null || true
  fi
  wait "${iperf_pid:-}" 2>/dev/null || true
  wait "${ping_pid:-}" 2>/dev/null || true
  wait "${interrupt_pid:-}" 2>/dev/null || true

  exit "$status"
}

if [ "$server_mode" = true ]; then
  if [ -n "$target_ip" ] || [ -n "$source_ip" ]; then
    echo "Error: client-only arguments cannot be used with --server."
    exit 1
  fi

  server_args=(--port "$port")
  if [ -n "$bind_ip" ]; then
    server_args+=(--bind-ip "$bind_ip")
  fi
  if [ -n "$interface" ]; then
    server_args+=(--interface "$interface")
  fi
  server_args+=(--metadata "$(make_metadata_string server "")")

  exec "$SCRIPT_DIR/iperf_client.sh" --server "${server_args[@]}"
fi

if [ -z "$target_ip" ]; then
  echo "Error: target IP is required in client mode."
  show_help
  exit 1
fi

echo "Checking connectivity to $target_ip..."
ping_check_args=(--target-ip "$target_ip" --count 1 --timeout 2)
if [ -n "$source_ip" ]; then
  ping_check_args+=(--source-ip "$source_ip")
elif [ -n "$interface" ]; then
  ping_check_args+=(--interface "$interface")
fi

"$SCRIPT_DIR/ping_client.sh" --check-only "${ping_check_args[@]}"
echo "Connectivity check succeeded."

trap cleanup INT TERM EXIT

ping_args=(--target-ip "$target_ip")
interrupt_args=(--target-ip "$target_ip")
iperf_args=(--client --target-ip "$target_ip" --port "$port" --duration "$duration" --protocol "$protocol" --metadata "$(make_metadata_string client "$target_ip")")

if [ -n "$source_ip" ]; then
  ping_args+=(--source-ip "$source_ip")
  interrupt_args+=(--source-ip "$source_ip")
  iperf_args+=(--source-ip "$source_ip")
elif [ -n "$interface" ]; then
  ping_args+=(--interface "$interface")
  interrupt_args+=(--interface "$interface")
fi

if [ "$protocol" = "udp" ] && [ -n "$bandwidth" ]; then
  iperf_args+=(--bandwidth "$bandwidth")
fi

if [ -n "$interface" ]; then
  iperf_args+=(--interface "$interface")
fi

echo "Starting ping monitor..."
"$SCRIPT_DIR/ping_client.sh" "${ping_args[@]}" &
ping_pid=$!

echo "Starting interruption monitor..."
"$SCRIPT_DIR/interruption_monitor.sh" "${interrupt_args[@]}" &
interrupt_pid=$!

echo "Starting iperf3 client..."
"$SCRIPT_DIR/iperf_client.sh" "${iperf_args[@]}" &
iperf_pid=$!

wait "$iperf_pid"
iperf_pid=""

kill "$ping_pid" 2>/dev/null || true
kill "$interrupt_pid" 2>/dev/null || true
wait "$ping_pid" 2>/dev/null || true
wait "$interrupt_pid" 2>/dev/null || true
ping_pid=""
interrupt_pid=""

trap - INT TERM EXIT
echo "Monitoring run completed."
