# Network Monitor

A comprehensive network monitoring tool that uses iperf3, ping, and custom scripts to measure network performance and detect interruptions with real-time data collection and Grafana visualization.

## Features

- **Real-time network throughput measurement** using iperf3 with unbuffered data collection
- **Network latency monitoring** using ping with millisecond precision
- **Robust interruption detection** with configurable thresholds to eliminate false positives
- **Bidirectional monitoring** support for comprehensive network analysis
- **Grafana dashboards** with timezone-aware queries for accurate data visualization
- **MariaDB database** storage with optimized time-series data handling
- **Server binding options** for multi-interface network configurations
- **Graceful shutdown** with proper signal handling (Ctrl+C support)

## Prerequisites

- Linux-based operating system (tested on Debian/Ubuntu)
- Root or sudo access for installation
- Network interfaces configured and accessible
- Target machine running iperf3 server (for bidirectional testing)

## Quick Start

1. **Clone and install:**
```bash
git clone https://github.com/grcarmenaty/network_monitor.git
cd network_monitor
sudo bash ./setup.sh
```

2. **Start monitoring:**
```bash
network_monitor -i enp60s0 -t 10.0.0.11 -S 10.1.0.12 -p 5050
```

3. **View results:**
   - Grafana: `http://localhost:3000` (admin/admin)
   - Real-time data updates every second

## Installation

The setup script automatically installs and configures:

- **Dependencies**: iperf3, MariaDB server, Grafana, jq, bc
- **Database**: Creates the configured database with optimized tables
- **Grafana**: Installs with data sources and timezone-aware dashboards
- **Scripts**: Copies monitoring scripts to `/opt/network_monitor/`
- **Symlink**: Creates `network_monitor` command in `/usr/local/bin/`

### Installation Features

✅ **Robust MariaDB installation** with automatic error recovery  
✅ **Grafana repository setup** with proper GPG key handling  
✅ **Database user creation** with remote access configuration  
✅ **Dashboard import** with timezone fixes applied  
✅ **Real-time data insertion** without buffering delays  
✅ **Interruption detection** with false positive elimination  

## Usage

### Basic Commands

```bash
# Standard monitoring
network_monitor -i <interface> -t <target_ip>

# With server binding (multi-interface systems)
network_monitor -i <client_interface> -t <target_ip> -S <server_ip> -I <server_interface>

# Custom port and bandwidth
network_monitor -i eth0 -t 192.168.1.100 -p 5201 -b 100M

# Display help
network_monitor -h
```

### Command Options

| Option | Description | Example |
|--------|-------------|---------|
| `-i <interface>` | Client network interface | `-i enp60s0` |
| `-t <target_ip>` | Target IP address | `-t 10.0.0.11` |
| `-S <server_ip>` | Server binding IP | `-S 10.1.0.12` |
| `-I <server_interface>` | Server binding interface | `-I eth1` |
| `-p <port>` | iperf3 port (default: 5050) | `-p 5201` |
| `-b <bandwidth>` | Bandwidth limit (UDP only, ignored in TCP) | `-b 100M` |
| `-m <mode>` | Protocol mode for iperf3 (`udp` or `tcp`, default: `udp`) | `-m tcp` |
| `-l <packet_size>` | Packet size to pass to iperf3 with `-l` | `-l 1400` |
| `-h, --help` | Display help message | |

### Signal Handling

- **Ctrl+C**: Gracefully stops all monitoring processes
- **Automatic cleanup**: Terminates iperf3 server, client, ping, and interruption monitor
- **Process tracking**: Shows PID information for all background processes

## Technical Details

### Real-Time Data Collection

The system uses `stdbuf -oL -eL` to eliminate pipe buffering, ensuring:
- Database insertions happen immediately (every ~1 second)
- Accurate timestamps reflecting actual measurement times
- Real-time Grafana dashboard updates
- No data clustering at process termination

### Robust Interruption Detection

Eliminates false positives with intelligent thresholds:
- **5 consecutive ping failures** required to declare disconnection
- **3 consecutive ping successes** required to declare recovery
- **2+ second minimum duration** to record interruptions
- **1-second ping interval** for reasonable monitoring frequency

Interruption timing semantics:
- `interruption_time` **starts at the first failed ping** in the failure sequence
- `interruption_time` **ends at the first successful ping** after connectivity returns
- Thresholds are still enforced for event validation (5 fails to enter disconnected state, 3 successes to confirm recovery)

### Database Schema

**iperf_results table:**
- `timestamp`: Measurement time with millisecond precision
- `bitrate`: Throughput in Mbits/sec
- `jitter`: Network jitter in milliseconds
- `lost_percentage`: Packet loss percentage
- `executed_command`: Exact `iperf3` command that produced the sample
- `protocol`: Transport mode (`udp` or `tcp`) used for the run
- `packet_size`: Packet size (from `-l`), or `NULL` when unused

**ping_results table:**
- `timestamp`: Ping time with millisecond precision
- `latency`: Round-trip time in milliseconds

**interruptions table:**
- `timestamp`: Interruption event timestamp (recorded when recovery is confirmed)
- `interruption_time`: Duration in seconds (from first failed ping to first successful ping, ≥2.0 for real interruptions)

### Timezone Handling

Grafana dashboards use timezone-aware queries:
```sql
SELECT UNIX_TIMESTAMP(timestamp) * 1000 AS time, bitrate AS value 
FROM iperf_results 
WHERE timestamp >= DATE_SUB(NOW(), INTERVAL 24 HOUR) 
ORDER BY time ASC;
```

This ensures proper time filtering regardless of system timezone settings.

## Grafana Dashboards

Access Grafana at `http://localhost:3000` with credentials `admin/admin`.

**Available dashboards:**
- **Network Monitoring Dashboard**: Single-source local monitoring (data rate, jitter, loss, latency, interruptions, metadata, grouped test runs)
- **Network Monitoring Dashboard (Bidirectional)**: Currently configured in **local fallback** mode so it shows the same data as the local dashboard until a real remote DB is available
- **Network Monitoring Dashboard (Bidirectional - Timezone Fixed)_OLD**: Legacy dashboard kept for compatibility/reference
- **Data sources**: `LocalNetworkMonitor` and `RemoteNetworkMonitor`
- **Time ranges**: Supports various time ranges (6h, 24h, 7d, etc.)
- **Auto-refresh**: Real-time updates every 5-30 seconds

**Remote datasource placeholder (current setup):**
- `RemoteNetworkMonitor` is preconfigured with a placeholder host (`192.168.1.100:3306`)
- Database: `network_monitor`
- If the remote host is unavailable, this is expected; dashboards still work in local fallback mode
- When the remote DB is ready, update only the datasource host/credentials in Grafana

### Run Grafana in Docker

Use the provided compose stack to run Grafana with automatic datasource/dashboard provisioning:

```bash
cp .env.grafana.example .env.grafana
docker compose -f docker-compose.grafana.yml up -d
```

The stack loads dashboards from `network_monitor/grafana_dashboards/` and provisions:
- `LocalNetworkMonitor` MySQL datasource
- `RemoteNetworkMonitor` MySQL datasource

If your DB runs on the host, keep `GRAFANA_DB_*_HOST=host.docker.internal` in `.env.grafana`.

## Troubleshooting

### Common Issues

**1. No data in Grafana:**
- Check database connectivity: `mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT COUNT(*) FROM iperf_results;"`
- Verify iperf3 connection between machines
- Ensure proper time range selection in Grafana (try "Last 24 hours")

**2. iperf3 connection refused:**
- Verify target machine is running iperf3 server: `iperf3 -s -p 5050`
- Check firewall settings on both machines
- Confirm IP addresses and network connectivity

**3. False interruption alerts:**
- The system now requires 5 consecutive ping failures (≥5 seconds) before recording
- Recovery is confirmed after 3 consecutive successful pings
- Duration is measured from the first failed ping to the first successful ping
- Only interruptions lasting 2+ seconds are recorded
- Single dropped packets are ignored as normal network behavior

**4. Permission denied errors:**
- Ensure scripts are executable: `sudo chmod +x /opt/network_monitor/*.sh`
- Run with proper sudo privileges for system operations

### Diagnostic Commands

```bash
# Load DB credentials from .env (optional)
set -a; source .env; set +a

# Check database status
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SHOW TABLES;"

# View recent measurements
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT * FROM iperf_results ORDER BY timestamp DESC LIMIT 5;"

# Check running processes
ps aux | grep -E "(iperf3|ping|interruption)"

# Test network connectivity
ping -c 5 <target_ip>
iperf3 -c <target_ip> -p 5050 -t 10
```

### UDP/TCP verification and command logging

- Run a UDP profile with `network_monitor -i <iface> -t <target_ip> -m udp -l 1400 -b 100M` and confirm `iperf_results` rows show `protocol = 'udp'`, `packet_size = 1400`, and `executed_command` contains `-u` and `-l 1400`.
- Run a TCP profile with `network_monitor -i <iface> -t <target_ip> -m tcp` to ensure stored rows have `protocol = 'tcp'` (and `packet_size` either `NULL` or the provided value) and `executed_command` lacks UDP flags.
- Verify MySQL logging with:

```
mysql -u $DB_USER -p$DB_PASS $DB_NAME -e "SELECT timestamp, protocol, packet_size, executed_command FROM iperf_results ORDER BY timestamp DESC LIMIT 5;"
```

Inspect the `executed_command` column to confirm the exact `iperf3` invocation recorded for each run.

The dashboards now include a metadata table panel (`Iperf3 Test Metadata`) showing protocol, packet size, and executed command for each recent sample.

## Architecture

```
┌─────────────────┐    iperf3     ┌─────────────────┐
│   Local Machine │◄─────────────►│  Remote Machine │
│                 │               │                 │
│ ┌─────────────┐ │               │ ┌─────────────┐ │
│ │ Client      │ │               │ │ Server      │ │
│ │ - iperf3 -c │ │               │ │ - iperf3 -s │ │
│ │ - ping      │ │               │ │             │ │
│ │ - interrupt │ │               │ │             │ │
│ └─────────────┘ │               │ └─────────────┘ │
│        │        │               │                 │
│        ▼        │               │                 │
│ ┌─────────────┐ │               │                 │
│ │  MariaDB    │ │               │                 │
│ │  Database   │ │               │                 │
│ └─────────────┘ │               │                 │
│        │        │               │                 │
│        ▼        │               │                 │
│ ┌─────────────┐ │               │                 │
│ │   Grafana   │ │               │                 │
│ │ Dashboard   │ │               │                 │
│ └─────────────┘ │               │                 │
└─────────────────┘               └─────────────────┘
```

## Files Structure

```
network_monitor/
├── setup.sh                    # Main installation script
├── README.md                   # This documentation
├── LICENSE                     # MIT License
└── network_monitor/            # Source scripts directory
    ├── setup.conf              # Database configuration
    ├── server_launcher.sh      # Main monitoring orchestrator
    ├── iperf_client.sh         # iperf3 data collection
    ├── ping_client.sh          # Ping latency monitoring
    ├── interruption_monitor.sh # Network interruption detection
    ├── uninstall.sh           # Removal script
    └── grafana_dashboards/     # Dashboard JSON files
        ├── network_monitor_remote.json
        └── network_monitor_dashboard.json
```

## Recent Improvements

### v2.0 - Real-Time & Robust Monitoring
- ✅ **Real-time database insertion** - eliminated pipe buffering delays
- ✅ **Robust interruption detection** - eliminated 87% false positive rate
- ✅ **Timezone-aware Grafana queries** - fixed "no data" issues
- ✅ **Server binding options** - support for multi-interface configurations
- ✅ **Graceful shutdown handling** - proper Ctrl+C signal management
- ✅ **Comprehensive error recovery** - MariaDB installation resilience

### Performance Metrics
- **Data insertion**: Real-time (every ~1 second) vs. previous batch processing
- **False positives**: Reduced from 120/137 (87.6%) to ~0% for interruptions
- **Timestamp accuracy**: Measurement-based vs. processing-time based
- **Dashboard responsiveness**: Real-time updates vs. delayed visibility

## Contributing

This project provides a complete network monitoring solution with enterprise-grade reliability and real-time capabilities. The codebase is well-documented and modular for easy customization.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
