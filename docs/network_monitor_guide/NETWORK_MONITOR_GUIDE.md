# Operational guide to network_monitor2

This guide provides the minimum procedure for selecting a network path and running a test between NUC2 and NUC1. See `README.md` for installation, database configuration, and advanced options.

To run one test with custom duration, protocol, bandwidth, packet size, flow count, or direction, see [`docs/MANUAL_TEST_GUIDE_EN.md`](../MANUAL_TEST_GUIDE_EN.md).

## 1. Before you begin

> **Safety:** never modify or interrupt the management connection on VLAN27.

- NUC2 management: `10.10.27.11`, interface `enp114s0`.
- NUC1 management: `10.10.27.10`, interface `enp114s0`.
- Default gateway: `10.10.27.1` on `enp114s0`.
- Connect to NUC1 through `ssh 10.10.27.10`.

Do not change VLAN27, the management addresses, or the default route.

Check the tool on both NUCs:

```bash
command -v network_monitor2
network_monitor2 --help
command -v iperf3
```

## 2. Select the path

- **CEIT:** NUC2 `10.10.42.11` → NUC1 `10.10.22.10`.
- **INDRA:** NUC2 `10.10.42.11` → NUC1 `10.10.22.10`.
- **Bypass TN0:** NUC2 `10.10.28.11` → NUC1 `10.10.28.10`.
- **Bypass TN1:** NUC2 `10.10.29.11` → NUC1 `10.10.29.10`.

CEIT and INDRA use the same endpoint addresses but different routes and gateways. The bypass paths are directly connected.

### CEIT

From NUC2, select CEIT on both NUCs:

```bash
sudo /home/tuser/scripts/test_ceit
ssh -t 10.10.27.10 'sudo /home/tuser/scripts/test_ceit'
```

```bash
# NUC2: must show via 10.10.42.41
ip route get 10.10.22.10 from 10.10.42.11

# NUC1: must show via 10.10.22.40
ssh 10.10.27.10 \
  'ip route get 10.10.42.11 from 10.10.22.10'
```

### INDRA

From NUC2, select INDRA on both NUCs:

```bash
sudo /home/tuser/scripts/test_indra
ssh -t 10.10.27.10 'sudo /home/tuser/scripts/test_indra'
```

```bash
# NUC2: must show via 10.10.42.31
ip route get 10.10.22.10 from 10.10.42.11

# NUC1: must show via 10.10.22.30
ssh 10.10.27.10 \
  'ip route get 10.10.42.11 from 10.10.22.10'
```

### Bypass TN0 or TN1

There is no `test_bypass` script. Before using a bypass path, remove only the CEIT/INDRA test routes. These commands must not change VLAN27 or the default route:

```bash
# NUC2
sudo ip route del 10.10.22.0/24 via 10.10.42.41 2>/dev/null || true
sudo ip route del 10.10.22.0/24 via 10.10.42.31 2>/dev/null || true

# NUC1, through management
ssh -t 10.10.27.10 \
  'sudo ip route del 10.10.42.0/24 via 10.10.22.40 2>/dev/null || true; \
   sudo ip route del 10.10.42.0/24 via 10.10.22.30 2>/dev/null || true'
```

Check the selected path:

```bash
# TN0
ip route get 10.10.28.10 from 10.10.28.11

# TN1
ip route get 10.10.29.10 from 10.10.29.11
```

The result must show a directly connected route with no gateway. To return to CEIT or INDRA, rerun the corresponding script on both NUCs.

## 3. Check reachability

From NUC2, run the ping for the selected path:

```bash
# CEIT or INDRA
ping -I 10.10.42.11 -c 5 10.10.22.10

# Bypass TN0
ping -I 10.10.28.11 -c 5 10.10.28.10

# Bypass TN1
ping -I 10.10.29.11 -c 5 10.10.29.10
```

If ping reports `100% packet loss`, do not run the throughput test. Check routes, addresses, VLANs, and ARP first.

## 4. Run a TCP test

Two terminals are required. Start the server on NUC1 first, then the client on NUC2. This example uses TN0.

### Terminal 1 — server on NUC1

```bash
ssh 10.10.27.10
network_monitor2 --server \
  --bind-ip 10.10.28.10 \
  --port 5050
```

Leave the server running.

### Terminal 2 — client on NUC2

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5050 \
  --duration 30 \
  --tcp
```

`Monitoring run completed` means that throughput, ping, and interruption monitoring have finished. The client stores results in NUC2's local database; the server stores its own iperf3 samples locally.

When finished, stop the server with `Ctrl+C`.

## 5. Adapt the command to the path

Only the addresses change:

- **CEIT or INDRA:** server `10.10.22.10`, client/source `10.10.42.11`.
- **TN0:** server `10.10.28.10`, client/source `10.10.28.11`.
- **TN1:** server `10.10.29.10`, client/source `10.10.29.11`.

Always use `--bind-ip` on the server and `--source-ip` on the client. `--interface` is optional and acts as an additional hint or metadata.

## 6. UDP test

Leave the same server running, use `--udp`, and specify the offered traffic rate:

```bash
network_monitor2 10.10.28.10 \
  --source-ip 10.10.28.11 \
  --port 5050 \
  --duration 30 \
  --udp \
  --bandwidth 400M
```

For UDP, interpret received bitrate, jitter, and packet loss together. High bitrate with high loss does not indicate a stable link.

## 7. Test from NUC1 to NUC2

Reverse the server and client. TN0 example:

On NUC2:

```bash
network_monitor2 --server --bind-ip 10.10.28.11 --port 5050
```

On NUC1:

```bash
network_monitor2 10.10.28.11 \
  --source-ip 10.10.28.10 \
  --port 5050 --duration 30 --tcp
```

## 8. View the results

### Terminal

For TCP, check throughput and retransmissions (`Retr`). For UDP, check received bitrate, jitter, and packet loss.

### Excel

Each NUC exports its own local database:

```bash
network_monitor2 --export-excel results.xlsx
```

To restrict the time interval:

```bash
network_monitor2 --export-excel results.xlsx \
  --start "2026-09-03 09:00:00" \
  --end "2026-09-03 12:00:00"
```

### Grafana

Open `http://<GRAFANA_IP>:3000` and select the local or bidirectional dashboard. Check the time range if no data appears.

## 9. Automated KPI campaign

From NUC2, preview it first:

```bash
cd /home/comsa/network_monitor_v2
./run_kpi_tests.sh --dry-run
```

Then start the campaign:

```bash
./run_kpi_tests.sh
```

The current campaign tests CEIT, bypass TN0, and bypass TN1, writes reports and logs under `results/`, and restores the initial route state after success, failure, or `Ctrl+C`. **INDRA is not yet included in the automated campaign.**

This campaign is separate from `tests/scripts/run_nuc2_base_measurements.sh`, which runs the Cedex TN0/TN1 matrix and exports its results under `export/`.

## 10. Common problems

### `Connection refused`

Check that the server is running and that the server and client use the same port.

### `No route to host` or no ping response

```bash
ip route get <DESTINATION> from <SOURCE>
ip neigh
ping -I <SOURCE> -c 5 <DESTINATION>
```

A `FAILED` neighbor normally indicates an ARP, VLAN, or Layer 2 problem.

### Port already in use

Select another port, such as `5051`, and use it on both the server and client.

### No data in Grafana

Check the time range, `/opt/network_monitor2/setup.conf`, and whether the test displayed `Monitoring run completed`.

## Quick reference

```bash
# Server
network_monitor2 --server --bind-ip <LOCAL_IP> --port 5050

# TCP client
network_monitor2 <SERVER_IP> --source-ip <CLIENT_IP> \
  --port 5050 --duration 30 --tcp

# UDP client
network_monitor2 <SERVER_IP> --source-ip <CLIENT_IP> \
  --port 5050 --duration 30 --udp --bandwidth 100M

# Local export
network_monitor2 --export-excel results.xlsx
```
