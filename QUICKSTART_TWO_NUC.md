# Quickstart Two NUC (NUC1 -> NUC2)

Guida rapida per test manuali con:
- NUC1: `10.10.27.10`
- NUC2: `10.10.27.11`

Scenario consigliato:
- MariaDB + Grafana su NUC1
- test principale in un solo verso: **NUC1 -> NUC2**

## 1) Prerequisiti

Su entrambi i NUC:

```bash
sudo apt update
sudo apt install -y git iperf3
```

## 2) Clone repo (entrambi i NUC)

```bash
git clone git@github.com:LucaPetrucci/network_monitor.git
cd network_monitor
git checkout dev
```

## 3) Installazione tool (entrambi i NUC)

```bash
sudo bash ./setup.sh
```

## 4) Database su NUC1 (10.10.27.10)

### 4.1 Crea DB local/remote + utente

```bash
sudo mysql -e "
CREATE DATABASE IF NOT EXISTS network_monitor_local;
CREATE DATABASE IF NOT EXISTS network_monitor_remote;
CREATE USER IF NOT EXISTS 'myuser'@'%' IDENTIFIED BY 'mypassword';
GRANT ALL PRIVILEGES ON network_monitor_local.* TO 'myuser'@'%';
GRANT ALL PRIVILEGES ON network_monitor_remote.* TO 'myuser'@'%';
FLUSH PRIVILEGES;"
```

### 4.2 Crea tabelle in entrambi i DB

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

## 5) Configura `setup.conf`

Ogni host scrive nel DB del proprio `setup.conf`.

### 5.1 NUC1 (writer local)

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

### 5.2 NUC2 (writer remote)

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

## 6) Configura Grafana (su NUC1)

Apri: `http://10.10.27.10:3000` (`admin/admin`).

Datasource:
- `LocalNetworkMonitor` -> host `10.10.27.10:3306`, DB `network_monitor_local`, user `myuser`
- `RemoteNetworkMonitor` -> host `10.10.27.10:3306`, DB `network_monitor_remote`, user `myuser`

## 7) Test principale (solo NUC1 -> NUC2)

### 7.1 NUC2: avvia server iperf3

```bash
iperf3 -s -p 5050
```

### 7.2 NUC1: avvia monitor

```bash
network_monitor -i <IFACE_NUC1> -t 10.10.27.11 -S 10.10.27.10 -I <IFACE_NUC1> -p 5050 -m udp -l 1000
```

Quando richiesto, premi `Invio` per confermare che il server sul target è attivo.

Lascia girare 120s, poi `Ctrl+C`.

## 8) Verifica dati

### 8.1 Local (deve crescere)

```bash
mysql -u myuser -pmypassword network_monitor_local -e "
SELECT COUNT(*) AS iperf_rows FROM iperf_results;
SELECT COUNT(*) AS ping_rows FROM ping_results;
SELECT COUNT(*) AS intr_rows FROM interruptions;
SELECT timestamp, protocol, packet_size, executed_command
FROM iperf_results ORDER BY id DESC LIMIT 5;"
```

### 8.2 Remote (se non hai avviato monitor su NUC2 può restare vuoto)

```bash
mysql -u myuser -pmypassword network_monitor_remote -e "
SELECT COUNT(*) AS iperf_rows FROM iperf_results;
SELECT COUNT(*) AS ping_rows FROM ping_results;
SELECT COUNT(*) AS intr_rows FROM interruptions;"
```

## 9) Opzionale: abilita test bidirezionale reale

Per popolare anche `remote`:

1. Su NUC1 apri una nuova shell e avvia:

```bash
iperf3 -s -p 5050
```

2. Su NUC2 avvia:

```bash
network_monitor -i <IFACE_NUC2> -t 10.10.27.10 -S 10.10.27.11 -I <IFACE_NUC2> -p 5050 -m udp -l 1000
```

Ora vedrai dati sia local che remote nella dashboard bidirezionale.

## Note

- `network_monitor` avvia automaticamente **un iperf3 server locale**; serve comunque un server attivo anche sul target.
- Per interruzioni visibili, usa run più lunghi e outage controllati.
- Script demo in repo: `tests/scripts/`.
