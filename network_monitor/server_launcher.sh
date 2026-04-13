#!/bin/bash

# Resolve installation directory from real script path (works with symlinks).
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# Function to check if script is run as superuser
check_superuser() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This operation requires superuser privileges. Please run as root or use sudo."
        exit 1
    fi
}

# Source setup.conf from the same installation directory.
if [ ! -f "$SCRIPT_DIR/setup.conf" ]; then
    echo "Error: setup.conf not found in $SCRIPT_DIR"
    exit 1
fi
source "$SCRIPT_DIR/setup.conf"

# Initialize variables
interface=""
port=5050
target_ip=${REMOTE_DB_IP:-""}  # Default to REMOTE_DB_IP
bandwidth=""
mode="udp"
packet_size=""
server_ip=""  # IP address to bind the iperf3 server to
server_interface=""  # Network interface to bind the iperf3 server to
server_only=false
create_default=false
uninstall=false
uninstall_all=false
simulate_disconnections=false

# Function to display help
show_help() {
    echo "Usage: network_monitor [OPTIONS]"
    echo "Network monitoring tool with iperf3, ping, and connection interruption detection."
    echo
    echo "Options:"
    echo "  -i <interface>       Specify the network interface to use for client connections"
    echo "  -t <target_ip>       Specify the target IP address"
    echo "  -p <port>            Specify the port for iperf3 (default: 5050)"
    echo "  -b <bandwidth>       Specify the bandwidth for iperf3 (UDP only)"
    echo "  -m <mode>            Protocol mode for iperf3 (udp|tcp, default: udp)"
    echo "  -l <packet_size>     Packet size for iperf3 (applied via -l)"
    echo "  -S <server_ip>       Bind iperf3 server to specific IP address"
    echo "  -I <server_interface> Bind iperf3 server to specific network interface"
    echo "  --server-only        Run only iperf3 server and write server-side samples to local DB"
    echo "  -d                   Create a default.conf file with current settings (requires superuser)"
    echo "  -u                   Uninstall the network monitor (requires superuser)"
    echo "  -a                   Used with -u, uninstall all associated programs (requires superuser)"
    echo "  -s                   Simulate periodic disconnections (requires superuser)"
    echo "  -h, --help           Display this help message"
    echo
    echo "Examples:"
    echo "  network_monitor -i eth0 -t 192.168.1.100 -p 5201 -b 100M"
    echo "  network_monitor -i eth0 -t 10.0.0.11 -S 10.0.0.12 -p 5050"
    echo "  network_monitor -i eth0 -t 10.0.0.11 -I enp60s0 -p 5050"
}

# Function to create default.conf
create_default_conf() {
    check_superuser
    cat > "$SCRIPT_DIR/default.conf" << EOF
INTERFACE=$interface
TARGET_IP=$target_ip
PORT=$port
BANDWIDTH=$bandwidth
MODE=$mode
PACKET_SIZE=$packet_size
SERVER_IP=$server_ip
SERVER_INTERFACE=$server_interface
EOF
    echo "Created default.conf with current settings."
}

# Function to uninstall
uninstall() {
    check_superuser
    echo "Uninstalling network monitor..."
    
    # Stop any running processes
    pkill -f "iperf_client.sh"
    pkill -f "ping_client.sh"
    pkill -f "interruption_monitor.sh"
    pkill -f "iperf3 -s"

    # Call the uninstall.sh script
    if [ "$uninstall_all" = true ]; then
        "$SCRIPT_DIR/uninstall.sh" -a
    else
        "$SCRIPT_DIR/uninstall.sh"
    fi

    echo "Network monitor uninstalled."
    exit 0
}

# Function to simulate disconnections
simulate_disconnections() {
    check_superuser
    while true; do
        sleep 60  # Wait for 1 minute
        duration=$((RANDOM % 6 + 5))  # Random number between 5 and 10
        echo "Simulating disconnection for $duration seconds"
        sudo "$SCRIPT_DIR/disconnection_test.sh" -t "$target_ip" &
        disconnect_pid=$!
        sleep $duration
        sudo kill -INT $disconnect_pid
        wait $disconnect_pid 2>/dev/null
    done
}

# Source default.conf if it exists
if [ -f "$SCRIPT_DIR/default.conf" ]; then
    source "$SCRIPT_DIR/default.conf"
    interface=${INTERFACE:-$interface}
    target_ip=${TARGET_IP:-$target_ip}
    port=${PORT:-$port}
    bandwidth=${BANDWIDTH:-$bandwidth}
    mode=${MODE:-$mode}
    packet_size=${PACKET_SIZE:-$packet_size}
    server_ip=${SERVER_IP:-$server_ip}
    server_interface=${SERVER_INTERFACE:-$server_interface}
fi

# Parse command-line options
while [[ $# -gt 0 ]]; do
    case $1 in
        -i) interface="$2"; shift 2 ;;
        -t) target_ip="$2"; shift 2 ;;
        -p) port="$2"; shift 2 ;;
        -b) bandwidth="$2"; shift 2 ;;
        -m) mode="$2"; shift 2 ;;
        -l) packet_size="$2"; shift 2 ;;
        -S) server_ip="$2"; shift 2 ;;
        -I) server_interface="$2"; shift 2 ;;
        --server-only) server_only=true; shift ;;
        -d) create_default=true; check_superuser; shift ;;
        -u) uninstall=true; check_superuser; shift ;;
        -a) uninstall_all=true; shift ;;
        -s) simulate_disconnections=true; check_superuser; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Unknown option: $1" >&2; show_help; exit 1 ;;
    esac
done

# Check if -a is used without -u
if [ "$uninstall_all" = true ] && [ "$uninstall" = false ]; then
    echo "Error: -a flag can only be used with -u flag."
    exit 1
fi

mode="$(echo "$mode" | tr '[:upper:]' '[:lower:]')"
if [[ "$mode" != "udp" && "$mode" != "tcp" ]]; then
    echo "Error: Mode must be 'udp' or 'tcp' (received '$mode')."
    exit 1
fi

if [ -n "$packet_size" ] && ! [[ "$packet_size" =~ ^[0-9]+$ ]]; then
    echo "Error: Packet size must be a positive integer."
    exit 1
fi

if [ "$mode" = "tcp" ] && [ -n "$bandwidth" ]; then
    echo "⚠️  Bandwidth (-b) limits only apply with UDP mode; ignoring for TCP."
    bandwidth=""
fi

# Uninstall if -u flag is passed
if [ "$uninstall" = true ]; then
    uninstall
fi

# Create default.conf if -d flag is passed
if [ "$create_default" = true ]; then
    create_default_conf
fi

# Check if interface is provided
if [ -z "$interface" ]; then
  echo "Error: Interface not specified. Use -i flag to specify the interface or set it in default.conf."
  exit 1
fi

# Check if target_ip is provided
if [ "$server_only" = false ] && [ -z "$target_ip" ]; then
  echo "Error: Target IP not specified. Use -t flag to specify the target IP or set it in default.conf."
  exit 1
fi

# Validate server IP if specified
if [ -n "$server_ip" ]; then
    # Check if the IP address is valid and available on this system
    if ! ip addr show | grep -q "$server_ip"; then
        echo "⚠️  Warning: Server IP $server_ip not found on this system."
        echo "Available IP addresses:"
        ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1'
        echo "Continuing anyway - iperf3 will report if binding fails."
    else
        echo "✅ Server IP $server_ip found on this system."
    fi
fi

# Validate server interface if specified
if [ -n "$server_interface" ]; then
    if ! ip link show "$server_interface" &>/dev/null; then
        echo "❌ Error: Server interface $server_interface not found on this system."
        echo "Available interfaces:"
        ip link show | grep -E "^[0-9]+:" | cut -d: -f2 | tr -d ' '
        exit 1
    else
        echo "✅ Server interface $server_interface found on this system."
    fi
fi

# Get the local IP address
local_ip=$(ip -4 addr show dev "$interface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Check if local_ip was successfully retrieved
if [ -z "$local_ip" ]; then
  echo "Error: Could not retrieve IP address for interface $interface"
  exit 1
fi

echo "📡 Client interface: $interface"
echo "📡 Client IP address: $local_ip"
if [ -n "$target_ip" ]; then
    echo "🎯 Target IP address: $target_ip"
fi
echo "⚙️  Mode: $mode"
if [ -n "$packet_size" ]; then
    echo "📐 Packet size: $packet_size"
fi
if [ -n "$server_ip" ]; then
    echo "🔗 Server will bind to IP: $server_ip"
fi
if [ -n "$server_interface" ]; then
    echo "🔗 Server will bind to interface: $server_interface"
fi
echo "🚀 Starting iperf3 server on port $port..."

# Check if port is already in use
if netstat -tuln 2>/dev/null | grep -q ":$port "; then
    echo "⚠️  Warning: Port $port is already in use. Consider using a different port with -p option."
    echo "Current processes using port $port:"
    netstat -tuln | grep ":$port "
    echo
fi

# Build iperf3 server command with binding options
server_cmd=(iperf3 -s -p "$port")

# Add server IP binding if specified
if [ -n "$server_ip" ]; then
    server_cmd+=(-B "$server_ip")
    echo "🔗 Binding server to IP address: $server_ip"
fi

# Add server interface binding if specified
if [ -n "$server_interface" ]; then
    server_cmd+=(--bind-dev "$server_interface")
    echo "🔗 Binding server to interface: $server_interface"
fi

# Shared DB helpers for server-side inserts.
nm2_escape_sql() {
    local value="$1"
    printf '%s' "${value//"'"/"''"}"
}

nm2_normalize_bitrate() {
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

nm2_make_mysql_cmd() {
    local _arr_name="$1"
    local -a _cmd=(mysql -u "$DB_USER" -p"$DB_PASS")
    if [ -n "${DB_HOST:-}" ]; then
        _cmd+=(-h "$DB_HOST")
    fi
    if [ -n "${DB_PORT:-}" ]; then
        _cmd+=(-P "$DB_PORT")
    fi
    _cmd+=("$DB_NAME")
    eval "$_arr_name=(\"\${_cmd[@]}\")"
}

nm2_extended_columns_supported="no"
nm2_detect_schema_capabilities() {
    local -a mysql_cmd=()
    nm2_make_mysql_cmd mysql_cmd

    local has_executed_command has_protocol has_packet_size
    has_executed_command=$("${mysql_cmd[@]}" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='iperf_results' AND COLUMN_NAME='executed_command';" 2>/dev/null || echo 0)
    has_protocol=$("${mysql_cmd[@]}" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='iperf_results' AND COLUMN_NAME='protocol';" 2>/dev/null || echo 0)
    has_packet_size=$("${mysql_cmd[@]}" -Nse "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='iperf_results' AND COLUMN_NAME='packet_size';" 2>/dev/null || echo 0)

    if [ "$has_executed_command" = "1" ] && [ "$has_protocol" = "1" ] && [ "$has_packet_size" = "1" ]; then
        nm2_extended_columns_supported="yes"
    fi
}

nm2_insert_server_sample() {
    local timestamp="$1"
    local bitrate="$2"
    local jitter="${3:-0}"
    local loss="${4:-0}"
    local executed_command="$5"
    local mode_value="$6"
    local packet_size_sql="$7"
    local -a mysql_cmd=()
    local escaped_command

    nm2_make_mysql_cmd mysql_cmd
    escaped_command=$(nm2_escape_sql "$executed_command")

    if [ "$nm2_extended_columns_supported" = "yes" ]; then
        "${mysql_cmd[@]}" -e \
          "INSERT INTO iperf_results (timestamp, bitrate, jitter, lost_percentage, executed_command, protocol, packet_size) VALUES ('$timestamp', $bitrate, $jitter, $loss, '$escaped_command', '$mode_value', $packet_size_sql);" \
          2>/dev/null || echo "⚠️  Failed to insert server sample at $timestamp"
    else
        "${mysql_cmd[@]}" -e \
          "INSERT INTO iperf_results (timestamp, bitrate, jitter, lost_percentage) VALUES ('$timestamp', $bitrate, $jitter, $loss);" \
          2>/dev/null || echo "⚠️  Failed to insert server sample at $timestamp"
    fi
}

run_server_only_mode() {
    local packet_size_sql="NULL"
    local server_cmd_str
    local throughput_regex='\[[[:space:]]*[0-9]+\][[:space:]]+([0-9.]+)-([0-9.]+)[[:space:]]+sec[[:space:]]+[0-9.]+[[:space:]]+[KMG]?Bytes[[:space:]]+([0-9.]+)[[:space:]]+([KMG]?)bits/sec'
    local current_stream_base_time=""

    if [ -n "$packet_size" ]; then
        packet_size_sql="$packet_size"
    fi

    server_cmd_str="$(printf '%q ' "${server_cmd[@]}")"
    server_cmd_str="${server_cmd_str% }"

    nm2_detect_schema_capabilities

    echo "📥 Server-only mode enabled: collecting server-side iperf samples into local DB."
    echo "Starting iperf3 server with command: $server_cmd_str"
    echo "💡 Press Ctrl+C to stop server-only mode"
    echo

    stdbuf -oL -eL "${server_cmd[@]}" 2>&1 | while IFS= read -r line; do
        echo "$line"

        if [[ $line =~ $throughput_regex ]]; then
            local elapsed_start="${BASH_REMATCH[1]}"
            local elapsed_end="${BASH_REMATCH[2]}"
            local bitrate_raw="${BASH_REMATCH[3]}"
            local unit="${BASH_REMATCH[4]}"
            local bitrate
            local measurement_time
            local timestamp

            # New stream starts from 0.00s in iperf output.
            if [ "$elapsed_start" = "0.00" ] || [ -z "$current_stream_base_time" ]; then
                current_stream_base_time=$(date +%s.%N)
            fi

            bitrate=$(nm2_normalize_bitrate "$bitrate_raw" "$unit")
            measurement_time=$(awk -v base="$current_stream_base_time" -v offset="$elapsed_end" 'BEGIN {printf "%.3f", base + offset}')
            timestamp=$(date -d "@$measurement_time" +"%Y-%m-%d %H:%M:%S.%3N")

            nm2_insert_server_sample "$timestamp" "$bitrate" 0 0 "$server_cmd_str" "$mode" "$packet_size_sql"
        fi
    done
}

if [ "$server_only" = true ]; then
    run_server_only_mode
    exit 0
fi

# Start iperf3 server in the background with better error handling
echo "Starting iperf3 server with command: $(printf '%q ' "${server_cmd[@]}")"
"${server_cmd[@]}" &
server_pid=$!

# Wait a moment for server to start
sleep 2

# Check if server started successfully
if ! kill -0 $server_pid 2>/dev/null; then
    echo "❌ Failed to start iperf3 server on port $port"
    echo "Try using a different port: network_monitor -i $interface -t $target_ip -p 5201"
    exit 1
fi

echo "✅ iperf3 server started successfully on port $port"
echo "📡 Waiting for connection from $target_ip..."
echo "Press enter when you are sure there is an iperf3 server running on target IP listening on port $port"
read -r

# Function to cleanup all processes on exit
cleanup() {
    echo
    echo "🛑 Stopping network monitor..."
    
    # Kill all background processes
    if [ -n "$iperf_client_pid" ]; then
        kill $iperf_client_pid 2>/dev/null
        echo "   Stopped iperf3 client"
    fi
    
    if [ -n "$ping_client_pid" ]; then
        kill $ping_client_pid 2>/dev/null
        echo "   Stopped ping client"
    fi
    
    if [ -n "$interruption_monitor_pid" ]; then
        kill $interruption_monitor_pid 2>/dev/null
        echo "   Stopped interruption monitor"
    fi
    
    if [ -n "$server_pid" ]; then
        kill $server_pid 2>/dev/null
        echo "   Stopped iperf3 server"
    fi
    
    if [ "$simulate_disconnections" = true ] && [ -n "$simulate_pid" ]; then
        kill $simulate_pid 2>/dev/null
        echo "   Stopped disconnection simulation"
    fi
    
    # Kill any remaining iperf3 processes
    pkill -f "iperf3.*-p $port" 2>/dev/null
    
    # Kill any remaining monitoring processes
    pkill -f "iperf_client.sh" 2>/dev/null
    pkill -f "ping_client.sh" 2>/dev/null
    pkill -f "interruption_monitor.sh" 2>/dev/null
    
    echo "✅ Network monitor stopped cleanly"
    exit 0
}

# Set up signal handlers for graceful shutdown
trap cleanup SIGINT SIGTERM EXIT

# Launch other scripts in the background and store their PIDs
echo "🚀 Starting monitoring processes..."

client_args=("-i" "$interface" "-t" "$target_ip" "-p" "$port" "-m" "$mode")
if [ -n "$packet_size" ]; then
    client_args+=("-l" "$packet_size")
fi
if [ -n "$bandwidth" ]; then
    client_args+=("-b" "$bandwidth")
fi

"$SCRIPT_DIR/iperf_client.sh" "${client_args[@]}" &
iperf_client_pid=$!

"$SCRIPT_DIR/ping_client.sh" -i "$interface" -t "$target_ip" &
ping_client_pid=$!

"$SCRIPT_DIR/interruption_monitor.sh" -i "$interface" -t "$target_ip" &
interruption_monitor_pid=$!

echo "📊 Monitoring processes started:"
echo "   iperf3 client: PID $iperf_client_pid"
echo "   ping client: PID $ping_client_pid"
echo "   interruption monitor: PID $interruption_monitor_pid"

# Start simulating disconnections if -s flag is passed
if [ "$simulate_disconnections" = true ]; then
    simulate_disconnections &
    simulate_pid=$!
    echo "   disconnection simulation: PID $simulate_pid"
fi

echo
echo "📡 Network monitoring is running..."
echo "💡 Press Ctrl+C to stop all monitoring processes"
echo

# Wait for the server process or any signal
wait $server_pid
