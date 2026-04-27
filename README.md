# Network Monitor v2

`network_monitor2` is a simple two-host network monitoring tool for Debian/Ubuntu systems.

It has only two runtime modes:

- client mode, which is the default
- server mode, enabled with `--server`

Each host writes only to its own local MariaDB database configured in `setup.conf`. Grafana can read the local database directly, and the second dashboard can also compare local data with a remote host database through an existing Grafana datasource.

The runtime now supports configurable physical table names through `setup.conf`:

- `IPERF_TABLE`
- `PING_TABLE`
- `INTERRUPTIONS_TABLE`

## What It Collects

- `ping` latency into `ping_results`
- `iperf3` client samples into `iperf_results`
- `iperf3` server-side samples, when running `--server`, into `iperf_results`
- interruption events into `interruptions`
- command metadata in `iperf_results.executed_command`

## Installation

```bash
git clone https://github.com/LucaPetrucci/network_monitor.git
cd network_monitor
sudo bash ./setup_v2.sh
```

The setup script:

- installs `network_monitor2` into `/usr/local/bin/network_monitor2`
- copies runtime files to `/opt/network_monitor2`
- creates or updates the MariaDB schema
- supports custom physical table names
- creates `/opt/network_monitor2/.venv`
- installs Python dependencies from `requirements.txt` into that virtual environment for Excel export

Python dependency file:

```bash
requirements.txt
```

It currently includes:

- `openpyxl`

## Runtime

### Server mode

Start an `iperf3` server on the local host and store server-side interval results in the local DB:

```bash
network_monitor2 --server
network_monitor2 --server --bind-ip <LOCAL_TEST_IP> --port 5050
```

Use `--bind-ip` when the host has multiple VLAN IPs and you want the server to listen only on a specific test address.

### Client mode

Client mode is the default. It verifies reachability with `ping`, stores latency in the local DB, starts interruption monitoring, then runs `iperf3` to the remote host and stores those results in the local DB.

```bash
network_monitor2 <TARGET_IP>
network_monitor2 <TARGET_IP> --source-ip <LOCAL_TEST_IP> --duration 60
network_monitor2 <TARGET_IP> --source-ip <LOCAL_TEST_IP> --udp --bandwidth 100M
network_monitor2 <TARGET_IP> --source-ip <LOCAL_TEST_IP> --tcp
```

Use `--source-ip` when the client host has more than one test VLAN IP and you want to force the run over a specific subnet.

### Optional interface hint

`--interface` is still available, but only as an optional hint for ping binding or metadata. In the normal case, `--source-ip` and `--bind-ip` are enough.

## CLI Summary

```bash
network_monitor2 --server [--bind-ip <local_ip>] [--port <port>] [--interface <iface>]
network_monitor2 <target_ip> [--source-ip <local_ip>] [--port <port>] [--duration <seconds>] [--udp|--tcp] [--bandwidth <rate>] [--interface <iface>]
network_monitor2 --export-excel output.xlsx
```

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

The current local DB model is preserved:

- no remote writes
- no host-to-host sync
- each host writes only to its own DB
- Grafana local dashboard reads the local DB
- Grafana mixed dashboard can read local plus remote DB via datasource configuration

The schema remains:

- `iperf_results`
- `ping_results`
- `interruptions`

By default those are the physical tables too. If your installation uses different table names, set these in `/opt/network_monitor2/setup.conf`:

```bash
IPERF_TABLE=nm_iperf_samples
PING_TABLE=nm_ping_samples
INTERRUPTIONS_TABLE=nm_interrupt_events
```

`setup_v2.sh` now creates those physical tables and also tries to create compatibility views named `iperf_results`, `ping_results`, and `interruptions` when the physical names differ, so the existing Grafana dashboards can keep working.

## Grafana

The repo keeps two dashboards:

- local dashboard
- local + remote dashboard

Existing useful panels are preserved:

- bitrate
- jitter
- packet loss
- ping latency
- interruptions
- command metadata

The `executed_command` field now carries enough run metadata to distinguish source IP, target IP, protocol, port, duration, and optional interface in Grafana tables.

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
