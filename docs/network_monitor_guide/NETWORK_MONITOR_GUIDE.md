# Quick guide to network_monitor2

This guide explains how to start `network_monitor2` on two NUCs, run TCP and UDP tests on a specific VLAN, and view the results. It is an operational, simplified version of the project README.

## 1. What the tool does

`network_monitor2` combines three types of measurement:

- ping, for latency and reachability;
- iperf3, for TCP/UDP throughput, jitter, and packet loss;
- interruption monitoring during the test.

Each NUC stores its own results in its local MariaDB database. The tool does not write directly to the database on the other NUC.

## 2. Prerequisites

The tool must be installed on both NUCs. Check it with:

```bash
command -v network_monitor2
network_monitor2 --help
command -v iperf3
```

If it is not installed yet:

```bash
cd /home/comsa/network_monitor_v2
sudo bash ./setup_v2.sh
```

The database configuration used by the runtime is located at:

```text
/opt/network_monitor2/setup.conf
```

## 3. Fundamental rule: server and client

Every test requires two terminals:

1. start `network_monitor2 --server` on the NUC that will receive the traffic;
2. start the client on the other NUC, specifying the server address.

The server must be started before the client. The port and binding addresses must match.

Because the NUCs have multiple VLANs, always use:

- `--bind-ip` on the server;
- `--source-ip` on the client.

This prevents Linux from selecting an interface other than the one being measured.

## 4. Checks before testing

Check addresses and interfaces:

```bash
ip -br addr
ip route
```

Check reachability using the correct source address:

```bash
ping -I <LOCAL_TEST_IP> -c 5 <REMOTE_TEST_IP>
```

TN0 example from NUC2:

```bash
ping -I 10.10.28.11 -c 5 10.10.28.10
```

If ping reports 100% packet loss, do not start the throughput test. Check routing, VLAN, ARP, and link status first.

## 5. First TCP test: NUC2 to NUC1

### Terminal 1 — NUC1 server

Connect to NUC1 through the management network:

```bash
ssh 10.10.27.10
```

Start the server bound to the NUC1 TN0 address:

```bash
network_monitor2 --server \
  --bind-ip 10.10.28.10 \
  --interface enp114s0.28 \
  --port 5050
```

Leave this terminal open.

### Terminal 2 — NUC2 client

Run a 30-second TCP test from NUC2:

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --interface enp114s0.28 \
  --port 5050 \
  --duration 30 \
  --tcp
```

During the test, the terminal displays the iperf3 intervals and final summary. Ping, throughput, and interruption data are also stored in the local database.

To stop the server after completing the tests, press `Ctrl+C` in the NUC1 terminal.

## 6. UDP test

Start the server on NUC1 as in the previous test, then run this command from NUC2:

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --interface enp114s0.28 \
  --port 5050 \
  --duration 30 \
  --udp \
  --bandwidth 400M
```

Change `--bandwidth` to test other offered rates, such as `100M`, `500M`, or `600M`.

For UDP tests, interpret these metrics together:

- received bitrate;
- jitter;
- percentage of lost packets.

A high bitrate combined with high packet loss does not indicate a stable link.

## 7. Test in the opposite direction

To measure NUC1 to NUC2, reverse the roles.

### NUC2 server

```bash
network_monitor2 --server \
  --bind-ip 10.10.28.11 \
  --interface enp114s0.28 \
  --port 5050
```

### NUC1 client

```bash
network_monitor2 10.10.28.11 \
  --source-ip 10.10.28.10 \
  --interface enp114s0.28 \
  --port 5050 \
  --duration 30 \
  --tcp
```

## 8. Using TN1

For TN1, replace the TN0 addresses and interfaces with the VLAN29 values:

```text
NUC2: 10.10.29.11 — enp114s0.29
NUC1: 10.10.29.10 — enp114s0.29
```

NUC1 server example:

```bash
network_monitor2 --server \
  --bind-ip 10.10.29.10 \
  --interface enp114s0.29 \
  --port 5050
```

NUC2 client example:

```bash
network_monitor2 10.10.29.10 \
  --source-ip 10.10.29.11 \
  --interface enp114s0.29 \
  --port 5050 \
  --duration 30 \
  --tcp
```

## 9. Path through the CEIT gateways

When traffic must cross CEIT, the test addresses are:

```text
NUC2: 10.10.42.11 — enp114s0.42
NUC1: 10.10.22.10 — enp114s0.22
```

After applying the expected CEIT routes, verify the path:

```bash
ip route get 10.10.22.10 from 10.10.42.11
```

The result on NUC2 must show gateway `10.10.42.41`. On NUC1, the return path must use `10.10.22.40`.

Server on NUC1:

```bash
network_monitor2 --server \
  --bind-ip 10.10.22.10 \
  --interface enp114s0.22 \
  --port 5050
```

Client on NUC2:

```bash
network_monitor2 10.10.22.10 \
  --source-ip 10.10.42.11 \
  --interface enp114s0.42 \
  --port 5050 \
  --duration 30 \
  --tcp
```

The radio selected internally by the CEIT gateways cannot be controlled or identified from the NUCs.

## 10. Reading terminal results

For TCP, the iperf3 summary shows:

- transfer: amount of data transferred;
- bitrate: measured throughput;
- retr: retransmitted TCP segments.

For UDP, it shows:

- received bitrate;
- jitter;
- lost packets and loss percentage.

The tool prints `Monitoring run completed` when the client, ping, and interruption monitoring processes have all finished successfully.

## 11. Exporting results to Excel

To export all local data:

```bash
network_monitor2 --export-excel results.xlsx
```

To limit the export to a time range:

```bash
network_monitor2 --export-excel results.xlsx \
  --start "2026-07-23 09:00:00" \
  --end "2026-07-23 12:00:00"
```

The Excel workbook normally contains:

- `iperf_results`;
- `ping_results`;
- `interruptions`;
- `commands`.

Run the export on the NUC whose local data you want to retrieve.

## 12. Viewing results in Grafana

If Grafana is already configured, open this address in a browser:

```text
http://<GRAFANA_SERVER_IP>:3000
```

Select one of these dashboards:

- Network Monitoring Dashboard, for local data;
- Network Monitoring Dashboard (Bidirectional), to compare local and remote data.

The main panels display throughput, jitter, packet loss, latency, interruptions, and command metadata.

If you use the Docker stack included in the repository:

```bash
cd /home/comsa/network_monitor_v2
cp .env.grafana.example .env.grafana
docker compose -f docker-compose.grafana.yml up -d
```

Credentials and database connections are defined in `.env.grafana`.

## 13. Common problems

### Connection refused

Check that the server is running, that client and server use the same port, and that `--bind-ip` matches an address configured on the server.

### No route to host

Check:

```bash
ip route get <DESTINATION> from <SOURCE>
ip neigh
ping -I <SOURCE> -c 5 <DESTINATION>
```

A neighbor in the `FAILED` state generally indicates an ARP, VLAN, or Layer-2 problem.

### No data in Grafana

Check the dashboard time range, the MariaDB configuration in `/opt/network_monitor2/setup.conf`, and whether the test displayed `Monitoring run completed`.

### Port already in use

Use a different port on both the server and client:

```bash
network_monitor2 --server --bind-ip <SERVER_IP> --port 5051
network_monitor2 <SERVER_IP> --source-ip <CLIENT_IP> --port 5051 --tcp
```

## 14. Automated KPI campaign

To automatically run the CEIT, bypass TN0, and bypass TN1 matrix:

```bash
cd /home/comsa/network_monitor_v2
./run_kpi_tests.sh
```

To review the operations without changing the network:

```bash
./run_kpi_tests.sh --dry-run
```

The campaign creates a new directory under `results/` containing Markdown/PDF reports, CSV results, complete test output, and routing logs.

## 15. Quick reference

Show the help:

```bash
network_monitor2 --help
```

TCP:

```bash
network_monitor2 <SERVER_IP> --source-ip <CLIENT_IP> --duration 30 --tcp
```

UDP:

```bash
network_monitor2 <SERVER_IP> --source-ip <CLIENT_IP> \
  --duration 30 --udp --bandwidth 100M
```

Server:

```bash
network_monitor2 --server --bind-ip <LOCAL_IP> --port 5050
```

Export:

```bash
network_monitor2 --export-excel results.xlsx
```
