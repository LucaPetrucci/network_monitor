# Two-NUC Quickstart (NUC1 -> NUC2)

Quick manual test guide with:
- NUC1: `10.10.27.10`
- NUC2: `10.10.27.11`

Recommended setup:
- MariaDB + Grafana on NUC1
- main test flow in one direction: **NUC1 -> NUC2**

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
sudo bash ./setup.sh
```

## 4) Database setup on NUC1 (10.10.27.10)

### 4.1 Create local/remote DBs and user

```bash
sudo mysql -e "
CREATE DATABASE IF NOT EXISTS network_monitor_local;
CREATE DATABASE IF NOT EXISTS network_monitor_remote;
CREATE USER IF NOT EXISTS 'myuser'@'%' IDENTIFIED BY 'mypassword';
GRANT ALL PRIVILEGES ON network_monitor_local.* TO 'myuser'@'%';
GRANT ALL PRIVILEGES ON network_monitor_remote.* TO 'myuser'@'%';
FLUSH PRIVILEGES;"
```

### 4.2 Create tables in both DBs

```bash
mysql -u myuser -pmypassword network_monitor_local -e "
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

mysql -u myuser -pmypassword network_monitor_remote -e "
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
```

## 5) Configure `setup.conf`

Each host writes to the DB configured in its own `setup.conf`.

### 5.1 NUC1 (`local` writer)

```bash
sudo tee /opt/network_monitor/setup.conf >/dev/null <<'EOF_CONF'
DB_HOST=10.10.27.10
DB_PORT=3306
DB_NAME=network_monitor_local
DB_USER=myuser
DB_PASS=mypassword
REMOTE_DB_IP=10.10.27.11
EOF_CONF
```

### 5.2 NUC2 (`remote` writer)

```bash
sudo tee /opt/network_monitor/setup.conf >/dev/null <<'EOF_CONF'
DB_HOST=10.10.27.10
DB_PORT=3306
DB_NAME=network_monitor_remote
DB_USER=myuser
DB_PASS=mypassword
REMOTE_DB_IP=10.10.27.10
EOF_CONF
```

## 6) Configure Grafana (on NUC1)

Open: `http://10.10.27.10:3000` (`admin/admin`).

Datasource mapping:
- `LocalNetworkMonitor` -> host `10.10.27.10:3306`, DB `network_monitor_local`, user `myuser`
- `RemoteNetworkMonitor` -> host `10.10.27.10:3306`, DB `network_monitor_remote`, user `myuser`

## 7) Main test (NUC1 -> NUC2 only)

### 7.1 On NUC2: start iperf3 server

```bash
iperf3 -s -p 5050
```

### 7.2 On NUC1: start monitor

```bash
network_monitor -i <NUC1_IFACE> -t 10.10.27.11 -S 10.10.27.10 -I <NUC1_IFACE> -p 5050 -m udp -l 1000
```

When prompted, press `Enter` to confirm the target server is up.

Let it run for ~120s, then stop with `Ctrl+C`.

## 8) Validate data

### 8.1 Local DB (should increase)

```bash
mysql -u myuser -pmypassword network_monitor_local -e "
SELECT COUNT(*) AS iperf_rows FROM iperf_results;
SELECT COUNT(*) AS ping_rows FROM ping_results;
SELECT COUNT(*) AS intr_rows FROM interruptions;
SELECT timestamp, protocol, packet_size, executed_command
FROM iperf_results ORDER BY id DESC LIMIT 5;"
```

### 8.2 Remote DB (can stay empty if NUC2 monitor is not running)

```bash
mysql -u myuser -pmypassword network_monitor_remote -e "
SELECT COUNT(*) AS iperf_rows FROM iperf_results;
SELECT COUNT(*) AS ping_rows FROM ping_results;
SELECT COUNT(*) AS intr_rows FROM interruptions;"
```

## 9) Optional: real bidirectional test

To populate `remote` with real measurements:

1. On NUC1, open another shell and run:

```bash
iperf3 -s -p 5050
```

2. On NUC2, run:

```bash
network_monitor -i <NUC2_IFACE> -t 10.10.27.10 -S 10.10.27.11 -I <NUC2_IFACE> -p 5050 -m udp -l 1000
```

Now both local and remote panels will show real data in the bidirectional dashboard.

## Notes

- `network_monitor` automatically starts a **local iperf3 server**; you still need an active server on the target host.
- For visible interruption events, run longer tests and inject controlled outages.
- Demo lab scripts are in `tests/scripts/`.
