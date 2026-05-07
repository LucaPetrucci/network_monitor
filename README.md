# Network Monitor v2

`network_monitor2` is a two-host network monitoring tool for Debian/Ubuntu systems.
It collects `ping`, `iperf3`, and interruption data, stores everything in the local MariaDB instance configured on each host, and exposes the results through Grafana dashboards.

The runtime has two modes:

- client mode, which is the default
- server mode, enabled with `--server`

Each host writes only to its own local database. Grafana can read the local database directly, and the bidirectional dashboard can compare local and remote data through separate datasources.

## Features

- Real-time throughput collection with unbuffered `iperf3` output
- Ping latency monitoring with millisecond timestamps
- Interruption detection with thresholds that avoid false positives
- Bidirectional testing for two-host comparisons
- Optional server binding for multi-interface or multi-VLAN setups
- Graceful shutdown and cleanup on `Ctrl+C`
- Excel export of locally collected data
- Configurable physical table names through `setup.conf`
- Compatibility views for legacy dashboard queries when table names differ
- Timezone-aware Grafana queries and dashboard panels

## Prerequisites

- Debian or Ubuntu
- Root or sudo access for installation
- MariaDB reachable from the host
- `iperf3` available on the target host when running client mode
- Grafana if you want to use the included dashboards

## Installation

```bash
git clone <repo-url>
cd network_monitor_v2
sudo bash ./setup_v2.sh
```

The setup script installs:

- the `network_monitor2` command in `/usr/local/bin/network_monitor2`
- runtime files in `/opt/network_monitor2`
- the local MariaDB schema
- `/opt/network_monitor2/.venv`
- Python dependencies from `requirements.txt` for Excel export

The current Python dependency file includes:

- `openpyxl`

### Configuration file

The installer writes `/opt/network_monitor2/setup.conf` with these values:

- `DB_HOST`
- `DB_PORT`
- `DB_NAME`
- `DB_USER`
- `DB_PASS`
- `IPERF_TABLE`
- `PING_TABLE`
- `INTERRUPTIONS_TABLE`

If custom table names are configured, the installer creates compatibility views named `iperf_results`, `ping_results`, and `interruptions` when possible so existing dashboards keep working.

## What It Collects

- `ping` latency into `ping_results`
- `iperf3` client samples into `iperf_results`
- `iperf3` server-side samples, when running `--server`, into `iperf_results`
- interruption events into `interruptions`
- command metadata in `iperf_results.executed_command`

## Runtime

### Server mode

Start an `iperf3` server on the local host and store server-side interval results in the local DB:

```bash
network_monitor2 --server
network_monitor2 --server --bind-ip <LOCAL_TEST_IP> --port 5050
```

Use `--bind-ip` when the host has multiple IPs and you want the server to listen only on a specific test address.

### Client mode

Client mode is the default. It verifies reachability with `ping`, stores latency in the local DB, starts interruption monitoring, then runs `iperf3` to the remote host and stores those results in the local DB.

```bash
network_monitor2 <TARGET_IP>
network_monitor2 <TARGET_IP> --source-ip <LOCAL_TEST_IP> --duration 60
network_monitor2 <TARGET_IP> --source-ip <LOCAL_TEST_IP> --udp --bandwidth 100M
network_monitor2 <TARGET_IP> --source-ip <LOCAL_TEST_IP> --tcp
```

Use `--source-ip` when the client host has more than one test IP and you want to force the run over a specific subnet.

### Optional interface hint

`--interface` is available as an optional hint for ping binding or metadata. In the normal case, `--source-ip` and `--bind-ip` are enough.

## CLI Reference

```bash
network_monitor2 --server [--bind-ip <local_ip>] [--port <port>] [--interface <iface>]
network_monitor2 <target_ip> [--source-ip <local_ip>] [--port <port>] [--duration <seconds>] [--udp|--tcp] [--bandwidth <rate>] [--interface <iface>]
network_monitor2 --export-excel <output.xlsx>
```

Options:

- `--server`: run in server mode
- `--bind-ip <local_ip>`: bind the server to a specific local IP
- `--source-ip <local_ip>`: bind client ping and `iperf3` traffic to a specific local IP
- `--interface <iface>`: optional interface hint for ping binding or metadata
- `--port <port>`: `iperf3` port, default `5050`
- `--duration <seconds>`: client duration in seconds, default `30`
- `--udp`: use UDP for the client, default
- `--tcp`: use TCP for the client
- `--bandwidth <rate>`: UDP bandwidth, default `100M`
- `--packet-size <size>`: client packet/buffer size
- `--export-excel <path>`: export local DB data to an Excel workbook
- `-h, --help`: show help

Defaults:

- port: `5050`
- protocol: `udp`
- duration: `30`
- UDP bandwidth: `100M`

## Excel Export

Export the locally collected data to a single Excel workbook:

```bash
network_monitor2 --export-excel results.xlsx
```

The workbook contains these sheets:

- `iperf_results`
- `ping_results`
- `interruptions`
- `commands`

## Database

The local DB model is preserved:

- no remote writes
- no host-to-host sync
- each host writes only to its own DB
- Grafana local dashboard reads the local DB
- Grafana mixed dashboard can read local plus remote DB via datasource configuration

The schema remains:

- `iperf_results`
- `ping_results`
- `interruptions`

If your installation uses different physical table names, configure them in `/opt/network_monitor2/setup.conf`:

```bash
IPERF_TABLE=nm_iperf_samples
PING_TABLE=nm_ping_samples
INTERRUPTIONS_TABLE=nm_interrupt_events
```

## Grafana

The repo keeps two dashboards:

- local dashboard
- local + remote dashboard

Useful panels include:

- bitrate
- jitter
- packet loss
- ping latency
- interruptions
- command metadata

The `executed_command` field carries enough metadata to distinguish source IP, target IP, protocol, port, duration, and optional interface in Grafana tables.

### Panel Guide

#### Network Monitoring Dashboard

- Data Rate: throughput time-series from `iperf_results.bitrate`
- Jitter: jitter time-series from `iperf_results.jitter`
- Lost Packets: packet-loss time-series from `iperf_results.lost_percentage`
- Latency: ping latency time-series from `ping_results.latency`
- Interruption Time: interruption events over time from `interruptions.interruption_time`
- Iperf3 Test Metadata: raw `iperf3` samples with command metadata
- Test Runs: grouped runs per command
- Recent Interruptions: latest interruption records

#### Network Monitoring Dashboard (Bidirectional)

- Time-series panels show both local and remote series in the same chart
- Table panels are split into explicit local and remote views
- Metadata and run-summary tables are duplicated per datasource for clarity

### Timezone Handling

Grafana dashboards use timezone-aware queries so time filtering behaves correctly regardless of system timezone settings.

### Optional Docker setup

If you want to run Grafana in Docker, you can use the provided compose stack with automatic datasource and dashboard provisioning:

```bash
cp .env.grafana.example .env.grafana
docker compose -f docker-compose.grafana.yml up -d
```

The stack loads dashboards from `docker/grafana/dashboards/` and provisions:

- `LocalNetworkMonitor` MySQL datasource
- `RemoteNetworkMonitor` MySQL datasource

If your DB runs on the host, keep `GRAFANA_DB_*_HOST=host.docker.internal` in `.env.grafana`.

If you already have Grafana installed on the host or on another server, you can skip this section and use your existing setup instead.

## Two-Host Workflow

For a real bidirectional setup, run `network_monitor2` on both hosts.

- Host A writes only to its own local DB
- Host B writes only to its own local DB
- Grafana maps `LocalNetworkMonitor` to the local writer DB
- Grafana maps `RemoteNetworkMonitor` to the remote writer DB

You can use either:

- one MariaDB server with two databases
- two separate MariaDB servers

The detailed two-NUC procedure is documented in [QUICKSTART_TWO_NUC.md](QUICKSTART_TWO_NUC.md).

### Single-direction example

```bash
network_monitor2 --server --bind-ip <HOST_A_TEST_IP> --port 5050
network_monitor2 <HOST_A_TEST_IP> --source-ip <HOST_B_TEST_IP> --duration 60
```

### Opposite direction

Swap the roles and repeat the same pattern with the other host.

## Validation

Recommended checks after installation or changes:

```bash
bash -n /opt/network_monitor2/*.sh
network_monitor2 --help
network_monitor2 --export-excel test.xlsx
```

For a two-host test:

1. On Host A:

```bash
network_monitor2 --server --bind-ip <HOST_A_TEST_IP>
```

2. On Host B:

```bash
network_monitor2 <HOST_A_TEST_IP> --source-ip <HOST_B_TEST_IP>
```

3. To test the opposite direction, swap the roles.

## Troubleshooting

Common issues:

- No data in Grafana: verify the DB connection, confirm the host is writing rows, and widen the Grafana time range
- `iperf3` connection refused: check the server mode, firewall rules, and target IP
- False interruption alerts: the monitor requires multiple consecutive ping failures and recovery confirmations
- Permission denied: ensure the installed scripts are executable and the command is run with the right privileges

Useful checks:

```bash
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SHOW TABLES;"
mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT * FROM iperf_results ORDER BY timestamp DESC LIMIT 5;"
ps aux | grep -E "(iperf3|ping|interruption)"
ping -c 5 <target_ip>
iperf3 -c <target_ip> -p 5050 -t 10
```

## Project Layout

```text
setup_v2.sh
README.md
QUICKSTART_TWO_NUC.md
network_monitor/
  server_launcher.sh
  iperf_client.sh
  ping_client.sh
  interruption_monitor.sh
  export_excel.py
  uninstall.sh
  setup.conf
docker-compose.grafana.yml
docker/
tests/
```

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
