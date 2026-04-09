#!/usr/bin/env bash
set -euo pipefail
cd /home/luca/network_monitor

start_target() {
  sudo ip netns exec nsRemote pkill -f "iperf3 -s -p 5050" 2>/dev/null || true
  sudo ip netns exec nsRemote bash -lc "nohup iperf3 -s -p 5050 >/tmp/iperf3-nsRemote-5050.log 2>&1 &"
  sleep 1
}

mirror_to_remote() {
  local run_start="$1"
  local run_end="$2"

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
}

run_case_100s() {
  local mode="$1"
  local psize="$2"
  local label="$3"

  start_target

  local run_start
  run_start=$(date '+%F %T')
  echo "[ROUND4][$label] START mode=$mode packet_size=$psize @ $(date -u '+%T')"

  sudo bash -lc "nohup bash -c 'printf \"\\n\" | network_monitor -i vethA -t 10.10.0.2 -S 10.20.0.1 -I vethB -p 5050 -m $mode -l $psize' >/tmp/nm_round4_${label}.log 2>&1 & echo \$! >/tmp/nm_round4_${label}.pid"

  # total 100s = 35 + 12(outage) + 53
  sleep 35
  echo "[ROUND4][$label] OUTAGE down/up 12s @ $(date -u '+%T')"
  sudo ip netns exec nsRemote ip link set dev vethA-ns down
  sleep 12
  sudo ip netns exec nsRemote ip link set dev vethA-ns up
  sleep 53

  if [[ -f /tmp/nm_round4_${label}.pid ]]; then
    sudo kill "$(cat /tmp/nm_round4_${label}.pid)" 2>/dev/null || true
  fi
  sudo pkill -f "network_monitor -i vethA -t 10.10.0.2 -S 10.20.0.1 -I vethB -p 5050 -m $mode -l $psize" 2>/dev/null || true
  sleep 2

  local run_end
  run_end=$(date '+%F %T')

  mirror_to_remote "$run_start" "$run_end"

  local local_samples remote_samples
  local_samples=$(mysql -u myuser -p'mypassword' network_monitor -Nse "SELECT COUNT(*) FROM iperf_results WHERE timestamp BETWEEN '$run_start' AND '$run_end';")
  remote_samples=$(mysql -u myuser -p'mypassword' network_monitor_remote_sim -Nse "SELECT COUNT(*) FROM iperf_results WHERE timestamp BETWEEN DATE_ADD('$run_start', INTERVAL 2 SECOND) AND DATE_ADD('$run_end', INTERVAL 2 SECOND);")

  echo "[ROUND4][$label] END @ $(date -u '+%T') local_samples=$local_samples remote_samples=$remote_samples"
}

prepare() {
  # runtime setup
  sudo sed -i 's/^DB_NAME=.*/DB_NAME=network_monitor/' /opt/network_monitor/setup.conf
  sudo sed -i 's/^DB_USER=.*/DB_USER=myuser/' /opt/network_monitor/setup.conf
  sudo sed -i 's/^DB_PASS=.*/DB_PASS=mypassword/' /opt/network_monitor/setup.conf
  if grep -q '^DB_HOST=' /opt/network_monitor/setup.conf; then
    sudo sed -i 's/^DB_HOST=.*/DB_HOST=127.0.0.1/' /opt/network_monitor/setup.conf
  else
    echo 'DB_HOST=127.0.0.1' | sudo tee -a /opt/network_monitor/setup.conf >/dev/null
  fi
  if grep -q '^DB_PORT=' /opt/network_monitor/setup.conf; then
    sudo sed -i 's/^DB_PORT=.*/DB_PORT=3306/' /opt/network_monitor/setup.conf
  else
    echo 'DB_PORT=3306' | sudo tee -a /opt/network_monitor/setup.conf >/dev/null
  fi

  sudo cp network_monitor/*.sh /opt/network_monitor/
  sudo chmod +x /opt/network_monitor/*.sh

  # remote sim db
  sudo mysql -e "CREATE DATABASE IF NOT EXISTS network_monitor_remote_sim; GRANT ALL PRIVILEGES ON network_monitor_remote_sim.* TO 'myuser'@'%'; FLUSH PRIVILEGES;"
  mysql -u myuser -p'mypassword' network_monitor_remote_sim -e "
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
    );
    TRUNCATE TABLE iperf_results;
    TRUNCATE TABLE ping_results;
    TRUNCATE TABLE interruptions;
  "

  # Grafana remote datasource -> simulated remote DB
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
    }' >/tmp/remote_ds_round4.json

  ./tests/scripts/ns_manual_test.sh cleanup || true
  ./tests/scripts/ns_manual_test.sh setup
}

summary() {
  echo "[ROUND4] local grouped summary (last 4h)"
  mysql -u myuser -p'mypassword' network_monitor -e "
    SELECT protocol, packet_size, LEFT(executed_command,90) AS cmd, COUNT(*) AS samples,
           ROUND(AVG(bitrate),2) AS avg_mbps, ROUND(MAX(lost_percentage),2) AS max_loss,
           MIN(timestamp) AS start_ts, MAX(timestamp) AS end_ts
    FROM iperf_results
    WHERE timestamp >= DATE_SUB(NOW(), INTERVAL 4 HOUR)
    GROUP BY protocol, packet_size, executed_command
    ORDER BY end_ts DESC;
  "

  echo "[ROUND4] remote_sim grouped summary (last 4h)"
  mysql -u myuser -p'mypassword' network_monitor_remote_sim -e "
    SELECT protocol, packet_size, LEFT(executed_command,90) AS cmd, COUNT(*) AS samples,
           ROUND(AVG(bitrate),2) AS avg_mbps, ROUND(MAX(lost_percentage),2) AS max_loss,
           MIN(timestamp) AS start_ts, MAX(timestamp) AS end_ts
    FROM iperf_results
    WHERE timestamp >= DATE_SUB(NOW(), INTERVAL 4 HOUR)
    GROUP BY protocol, packet_size, executed_command
    ORDER BY end_ts DESC;
  "

  echo "[ROUND4] latest interruptions local"
  mysql -u myuser -p'mypassword' network_monitor -e "SELECT id,timestamp,interruption_time FROM interruptions ORDER BY id DESC LIMIT 12;"

  echo "[ROUND4] latest interruptions remote_sim"
  mysql -u myuser -p'mypassword' network_monitor_remote_sim -e "SELECT id,timestamp,interruption_time FROM interruptions ORDER BY id DESC LIMIT 12;"
}

main() {
  echo "[ROUND4] START UTC: $(date -u '+%F %T')"
  prepare

  run_case_100s udp 500 udp_500
  run_case_100s udp 1000 udp_1000
  run_case_100s udp 1472 udp_1472
  run_case_100s tcp 500 tcp_500
  run_case_100s tcp 1000 tcp_1000
  run_case_100s tcp 1472 tcp_1472

  echo "[ROUND4] END UTC: $(date -u '+%F %T')"
  summary

  ./tests/scripts/ns_manual_test.sh cleanup
  echo "[ROUND4] DONE"
}

main "$@"
