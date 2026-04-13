# Two-NUC Quickstart (NUC1 -> NUC2)

Quick manual test guide with:
- NUC1: `10.10.27.10`
- NUC2: `10.10.27.11`

## Architecture Rule (Important)

Each node writes to its **own writer DB endpoint**.

- `network_monitor2` on NUC1 writes to NUC1 writer DB (logical local source).
- `network_monitor2` on NUC2 writes to NUC2 writer DB (logical remote source).

The writer DB can be local to the node or hosted elsewhere, as long as it is always reachable by that node.

No offline buffer/queue is assumed in this setup.

## 1) Prerequisites

On both NUCs:

```bash
sudo apt update
sudo apt install -y git iperf3
```

## 2) Clone the repository (both NUCs)

```bash
git clone git@github.com:LucaPetrucci/network_monitor.git
cd network_monitor
git checkout dev
```

## 3) Install the tool (both NUCs)

```bash
sudo bash ./setup_v2.sh
```

## 4) Create per-node writer DBs

Create two DBs (same MariaDB host or different hosts):
- writer DB for NUC1 (example: `network_monitor_nuc1`)
- writer DB for NUC2 (example: `network_monitor_nuc2`)

Example (single MariaDB host):

```bash
sudo mysql -e "
CREATE DATABASE IF NOT EXISTS network_monitor_nuc1;
CREATE DATABASE IF NOT EXISTS network_monitor_nuc2;
CREATE USER IF NOT EXISTS 'myuser'@'%' IDENTIFIED BY 'mypassword';
GRANT ALL PRIVILEGES ON network_monitor_nuc1.* TO 'myuser'@'%';
GRANT ALL PRIVILEGES ON network_monitor_nuc2.* TO 'myuser'@'%';
FLUSH PRIVILEGES;"
```

Initialize schema on both DBs:

```bash
for DB in network_monitor_nuc1 network_monitor_nuc2; do
  mysql -u myuser -pmypassword "$DB" -e "
  CREATE TABLE IF NOT EXISTS iperf_results (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp DATETIME(3),
    bitrate FLOAT,
    jitter FLOAT,
    lost_percentage FLOAT,
    executed_command TEXT,
    protocol VARCHAR(16),
    packet_size INT
  );
  CREATE TABLE IF NOT EXISTS ping_results (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp DATETIME(3),
    latency FLOAT
  );
  CREATE TABLE IF NOT EXISTS interruptions (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp DATETIME(3),
    interruption_time FLOAT
  );"
done
```

## 5) Configure `/opt/network_monitor2/setup.conf`

Each node must point to its own writer DB.

### 5.1 NUC1 (`10.10.27.10` -> writer DB `network_monitor_nuc1`)

```bash
sudo tee /opt/network_monitor2/setup.conf >/dev/null <<'EOF_CONF'
DB_HOST=<NUC1_WRITER_DB_HOST>
DB_PORT=3306
DB_NAME=network_monitor_nuc1
DB_USER=myuser
DB_PASS=mypassword
REMOTE_DB_IP=10.10.27.11
EOF_CONF
```

### 5.2 NUC2 (`10.10.27.11` -> writer DB `network_monitor_nuc2`)

```bash
sudo tee /opt/network_monitor2/setup.conf >/dev/null <<'EOF_CONF'
DB_HOST=<NUC2_WRITER_DB_HOST>
DB_PORT=3306
DB_NAME=network_monitor_nuc2
DB_USER=myuser
DB_PASS=mypassword
REMOTE_DB_IP=10.10.27.10
EOF_CONF
```

## 6) Configure Grafana datasources

### If you are observing from NUC1 perspective
- `LocalNetworkMonitor` -> NUC1 writer DB (`network_monitor_nuc1`)
- `RemoteNetworkMonitor` -> NUC2 writer DB (`network_monitor_nuc2`)

### If you are observing from NUC2 perspective
- `LocalNetworkMonitor` -> NUC2 writer DB (`network_monitor_nuc2`)
- `RemoteNetworkMonitor` -> NUC1 writer DB (`network_monitor_nuc1`)

Only datasource mapping changes. Test commands stay the same.

## 7) Main test (NUC1 -> NUC2 only)

### 7.1 On NUC2: start iperf3 server

```bash
iperf3 -s -p 5050
```

### 7.2 On NUC1: start monitor

```bash
network_monitor2 -i <NUC1_IFACE> -t 10.10.27.11 -S 10.10.27.10 -I <NUC1_IFACE> -p 5050 -m udp -l 1000
```

When prompted, press `Enter` to confirm target server availability.

Run for ~120s, then stop with `Ctrl+C`.

## 8) Validate writes

On NUC1 writer DB:

```bash
mysql -u myuser -pmypassword network_monitor_nuc1 -e "
SELECT COUNT(*) AS iperf_rows FROM iperf_results;
SELECT COUNT(*) AS ping_rows FROM ping_results;
SELECT COUNT(*) AS intr_rows FROM interruptions;
SELECT timestamp, protocol, packet_size, executed_command
FROM iperf_results ORDER BY id DESC LIMIT 5;"
```

On NUC2 writer DB (can remain empty if NUC2 monitor is not running):

```bash
mysql -u myuser -pmypassword network_monitor_nuc2 -e "
SELECT COUNT(*) AS iperf_rows FROM iperf_results;
SELECT COUNT(*) AS ping_rows FROM ping_results;
SELECT COUNT(*) AS intr_rows FROM interruptions;"
```

## 9) Optional: real bidirectional test

To populate NUC2 writer DB with real remote measurements:

1. On NUC1, in another shell:

```bash
iperf3 -s -p 5050
```

2. On NUC2:

```bash
network_monitor2 -i <NUC2_IFACE> -t 10.10.27.10 -S 10.10.27.11 -I <NUC2_IFACE> -p 5050 -m udp -l 1000
```

Now both writer DBs contain real node-perspective data.

## 10) Single-direction test with remote DB population (`--server-only`)

Use this when you want to avoid two simultaneous client streams (no bandwidth split), but still populate both DBs
for Grafana `Local` vs `Remote` comparison.

### 10.1 Passive node (server-only)

Example on NUC1 (`10.10.27.10`):

```bash
network_monitor2 --server-only -i <NUC1_IFACE> -S 10.10.27.10 -I <NUC1_IFACE> -p 5050 -m udp -l 1000
```

### 10.2 Active node (full monitor)

Example on NUC2 (`10.10.27.11`):

```bash
network_monitor2 -i <NUC2_IFACE> -t 10.10.27.10 -S 10.10.27.11 -I <NUC2_IFACE> -p 5050 -m udp -l 1000
```

In this setup:
- active node writes client-side samples to its local DB
- passive node writes server-side samples to its own local DB
- Grafana on either side can compare `Local` and `Remote` from the same time window without dual client traffic

## Notes

- `network_monitor2` starts a local iperf3 server automatically; you still need an active server on the target host.
- For visible interruption events, use longer runs and controlled outages.
- Demo lab scripts are in `tests/scripts/`.
- Re-running `setup_v2.sh` is safe and also applies DB schema migration for legacy v2 databases (adds missing `iperf_results` metadata columns used by dashboards).
