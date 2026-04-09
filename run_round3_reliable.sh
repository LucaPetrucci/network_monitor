#!/usr/bin/env bash
set -euo pipefail
cd /home/luca/network_monitor

start_target() {
  sudo ip netns exec nsRemote pkill -f "iperf3 -s -p 5050" 2>/dev/null || true
  sudo ip netns exec nsRemote bash -lc "nohup iperf3 -s -p 5050 >/tmp/iperf3-nsRemote-5050.log 2>&1 &"
  sleep 1
}

run_case() {
  local mode="$1"
  local psize="$2"
  local label="$3"

  start_target
  echo "[ROUND3][$label] START mode=$mode packet_size=$psize @ $(date -u '+%T')"
  local run_start
  run_start=$(date '+%F %T')

  sudo bash -lc "nohup bash -c 'printf \"\\n\" | network_monitor -i vethA -t 10.10.0.2 -S 10.20.0.1 -I vethB -p 5050 -m $mode -l $psize' >/tmp/nm_round3_${label}.log 2>&1 & echo \$! >/tmp/nm_round3_${label}.pid"

  sleep 20
  echo "[ROUND3][$label] OUTAGE down/up 12s @ $(date -u '+%T')"
  sudo ip netns exec nsRemote ip link set dev vethA-ns down
  sleep 12
  sudo ip netns exec nsRemote ip link set dev vethA-ns up
  sleep 28

  if [[ -f /tmp/nm_round3_${label}.pid ]]; then
    sudo kill "$(cat /tmp/nm_round3_${label}.pid)" 2>/dev/null || true
  fi
  sudo pkill -f "network_monitor -i vethA -t 10.10.0.2 -S 10.20.0.1 -I vethB -p 5050 -m $mode -l $psize" 2>/dev/null || true
  sleep 2

  local run_end
  run_end=$(date '+%F %T')

  mysql -u myuser -p'mypassword' -e "
    INSERT INTO network_monitor_remote_sim.iperf_results
      (timestamp, bitrate, jitter, lost_percentage, executed_command, protocol, packet_size)
    SELECT
      DATE_ADD(timestamp, INTERVAL 2 SECOND),
      ROUND(bitrate * (0.92 + (RAND()*0.06)), 3),
      ROUND(jitter * (1.05 + (RAND()*0.15)), 3),
      LEAST(100, ROUND(lost_percentage + (RAND()*4), 3)),
      executed_command,
      protocol,
      packet_size
    FROM network_monitor.iperf_results
    WHERE timestamp BETWEEN '$run_start' AND '$run_end';

    INSERT INTO network_monitor_remote_sim.ping_results (timestamp, latency)
    SELECT DATE_ADD(timestamp, INTERVAL 2 SECOND), ROUND(latency * (1.02 + (RAND()*0.12)), 3)
    FROM network_monitor.ping_results
    WHERE timestamp BETWEEN '$run_start' AND '$run_end';

    INSERT INTO network_monitor_remote_sim.interruptions (timestamp, interruption_time)
    SELECT DATE_ADD(timestamp, INTERVAL 2 SECOND), ROUND(interruption_time * (1.03 + (RAND()*0.10)), 3)
    FROM network_monitor.interruptions
    WHERE timestamp BETWEEN '$run_start' AND '$run_end';
  "

  echo "[ROUND3][$label] END + mirrored @ $(date -u '+%T')"
}

echo "[ROUND3] START UTC: $(date -u '+%F %T')"

mysql -u myuser -p'mypassword' network_monitor_remote_sim -e "TRUNCATE TABLE iperf_results; TRUNCATE TABLE ping_results; TRUNCATE TABLE interruptions;"

# keep remote datasource pointed to simulated DB
curl -sS -u admin:admin -H 'Content-Type: application/json' -X PUT \
  http://localhost:3000/api/datasources/uid/bfet2boy5q6f4e \
  -d '{
    "uid":"bfet2boy5q6f4e",
    "name":"RemoteNetworkMonitor",
    "type":"mysql",
    "access":"proxy",
    "url":"localhost:3306",
    "user":"myuser",
    "database":"",
    "basicAuth":false,
    "isDefault":false,
    "jsonData":{
      "database":"network_monitor_remote_sim",
      "maxOpenConns":100,
      "maxIdleConns":100,
      "connMaxLifetime":14400
    },
    "secureJsonData":{
      "password":"mypassword"
    }
  }' >/tmp/remote_ds_update_round3.json

./ns_manual_test.sh cleanup || true
./ns_manual_test.sh setup

run_case udp 500 udp_500
run_case udp 1000 udp_1000
run_case udp 1472 udp_1472
run_case tcp 500 tcp_500
run_case tcp 1000 tcp_1000
run_case tcp 1472 tcp_1472

echo "[ROUND3] END UTC: $(date -u '+%F %T')"

echo "[ROUND3] local grouped summary (last 90m)"
mysql -u myuser -p'mypassword' network_monitor -e "
  SELECT protocol, packet_size, LEFT(executed_command,90) AS cmd, COUNT(*) AS samples,
         ROUND(AVG(bitrate),2) AS avg_mbps, ROUND(MAX(lost_percentage),2) AS max_loss,
         MIN(timestamp) AS start_ts, MAX(timestamp) AS end_ts
  FROM iperf_results
  WHERE timestamp >= DATE_SUB(NOW(), INTERVAL 90 MINUTE)
  GROUP BY protocol, packet_size, executed_command
  ORDER BY end_ts DESC;
"

echo "[ROUND3] remote_sim grouped summary (last 90m)"
mysql -u myuser -p'mypassword' network_monitor_remote_sim -e "
  SELECT protocol, packet_size, LEFT(executed_command,90) AS cmd, COUNT(*) AS samples,
         ROUND(AVG(bitrate),2) AS avg_mbps, ROUND(MAX(lost_percentage),2) AS max_loss,
         MIN(timestamp) AS start_ts, MAX(timestamp) AS end_ts
  FROM iperf_results
  WHERE timestamp >= DATE_SUB(NOW(), INTERVAL 90 MINUTE)
  GROUP BY protocol, packet_size, executed_command
  ORDER BY end_ts DESC;
"

echo "[ROUND3] interruptions local latest"
mysql -u myuser -p'mypassword' network_monitor -e "SELECT id,timestamp,interruption_time FROM interruptions ORDER BY id DESC LIMIT 12;"

echo "[ROUND3] interruptions remote_sim latest"
mysql -u myuser -p'mypassword' network_monitor_remote_sim -e "SELECT id,timestamp,interruption_time FROM interruptions ORDER BY id DESC LIMIT 12;"

./ns_manual_test.sh cleanup

echo "[ROUND3] DONE"
