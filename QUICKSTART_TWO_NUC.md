# Two-NUC Quickstart

Example layout:

- Host A VLAN 28 test IP: `<HOST_A_VLAN28_IP>`
- Host B VLAN 28 test IP: `<HOST_B_VLAN28_IP>`
- Host A VLAN 29 test IP: `<HOST_A_VLAN29_IP>`
- Host B VLAN 29 test IP: `<HOST_B_VLAN29_IP>`

The rule is simple:

- each NUC runs `network_monitor2`
- each NUC writes only to its own local DB
- no remote DB writes are used by the tool

## 1. Install on both NUCs

```bash
git clone git@github.com:LucaPetrucci/network_monitor.git
cd network_monitor
sudo bash ./setup_v2.sh
```

The setup creates `/opt/network_monitor2/.venv` and installs Python dependencies from `requirements.txt`, including `openpyxl` for `.xlsx` export.

## 2. Configure the local DB on each NUC

Edit `/opt/network_monitor2/setup.conf` so each node points to its own local MariaDB database.

Example:

```bash
sudo tee /opt/network_monitor2/setup.conf >/dev/null <<'EOF_CONF'
DB_HOST=<LOCAL_DB_HOST>
DB_PORT=<LOCAL_DB_PORT>
DB_NAME=<LOCAL_DB_NAME>
DB_USER=<LOCAL_DB_USER>
DB_PASS=<LOCAL_DB_PASSWORD>
IPERF_TABLE=iperf_results
PING_TABLE=ping_results
INTERRUPTIONS_TABLE=interruptions
EOF_CONF
```

On the other host, use its own local DB values.

If your deployment uses different physical table names, set them here. The runtime will write to those configured tables.

## 3. Start server mode on Host A

Example for VLAN 28 on Host A:

```bash
network_monitor2 --server --bind-ip <HOST_A_VLAN28_IP> --port 5050
```

This starts `iperf3` server on Host A and stores server-side interval results into the local DB of Host A.

## 4. Start client mode on Host B

Example for VLAN 28 on Host B:

```bash
network_monitor2 <HOST_A_VLAN28_IP> --source-ip <HOST_B_VLAN28_IP> --duration 60
```

This does all of the following on Host B:

- checks connectivity with `ping`
- stores ping latency into NUC2 local DB
- runs interruption monitoring
- runs `iperf3` client
- stores `iperf3` client results into NUC2 local DB

## 5. Test the opposite direction

To reverse the direction, swap the roles.

On Host B:

```bash
network_monitor2 --server --bind-ip <HOST_B_VLAN28_IP> --port 5050
```

On Host A:

```bash
network_monitor2 <HOST_B_VLAN28_IP> --source-ip <HOST_A_VLAN28_IP> --duration 60
```

## 6. Test VLAN 29

Use the VLAN 29 IPs in the same way.

On Host A:

```bash
network_monitor2 --server --bind-ip <HOST_A_VLAN29_IP>
```

On Host B:

```bash
network_monitor2 <HOST_A_VLAN29_IP> --source-ip <HOST_B_VLAN29_IP>
```

Using the test IP itself is enough to distinguish VLAN 28 from VLAN 29 in stored metadata and Grafana tables.

## 7. Export data to Excel

Run on the host whose local DB you want to export:

```bash
network_monitor2 --export-excel results.xlsx
```

The workbook includes:

- `iperf_results`
- `ping_results`
- `interruptions`
- `commands`

## 8. Grafana usage

Keep the existing two-dashboard model:

- local dashboard reads only the local DB
- local + remote dashboard reads local DB plus the remote host DB through Grafana datasource configuration

The monitoring tool itself never writes to the remote DB.

## 9. Basic validation

Syntax and help:

```bash
bash -n /opt/network_monitor2/*.sh
network_monitor2 --help
```

Example DB checks:

```bash
mysql -u <LOCAL_DB_USER> -p<LOCAL_DB_PASSWORD> <LOCAL_DB_NAME> -e "
SELECT COUNT(*) AS iperf_rows FROM iperf_results;
SELECT COUNT(*) AS ping_rows FROM ping_results;
SELECT COUNT(*) AS intr_rows FROM interruptions;
SELECT timestamp, protocol, executed_command
FROM iperf_results
ORDER BY id DESC
LIMIT 5;"
```
