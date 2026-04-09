#!/usr/bin/env bash
set -euo pipefail

cd /home/luca/network_monitor

log() { echo "$1"; }

configure_runtime() {
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
}

run_case() {
  local round="$1"
  local mode="$2"
  local psize="$3"
  local label="$4"

  log "[$round][$label] START mode=$mode packet_size=$psize @ $(date -u '+%T')"
  local run_start
  run_start=$(date '+%F %T')

  sudo bash -lc "nohup bash -c 'printf \"\\n\" | network_monitor -i vethA -t 10.10.0.2 -S 10.20.0.1 -I vethB -p 5050 -m $mode -l $psize' >/tmp/nm_${round}_${label}.log 2>&1 & echo \$! >/tmp/nm_${round}_${label}.pid"

  sleep 20
  log "[$round][$label] OUTAGE down/up 12s @ $(date -u '+%T')"
  sudo ip netns exec nsRemote ip link set dev vethA-ns down
  sleep 12
  sudo ip netns exec nsRemote ip link set dev vethA-ns up
  sleep 28

  if [[ -f "/tmp/nm_${round}_${label}.pid" ]]; then
    sudo kill "$(cat /tmp/nm_${round}_${label}.pid)" 2>/dev/null || true
  fi
  sudo pkill -f "network_monitor -i vethA -t 10.10.0.2 -S 10.20.0.1 -I vethB -p 5050 -m $mode -l $psize" 2>/dev/null || true
  sleep 2

  local run_end
  run_end=$(date '+%F %T')
  log "[$round][$label] END @ $(date -u '+%T')"

  if [[ "$round" == "ROUND2" ]]; then
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
    log "[$round][$label] mirrored to remote_sim with variation"
  fi
}

prepare_remote_sim_db() {
  mysql -u myuser -p'mypassword' -e "
    CREATE DATABASE IF NOT EXISTS network_monitor_remote_sim;
    CREATE TABLE IF NOT EXISTS network_monitor_remote_sim.iperf_results (
      id INT AUTO_INCREMENT PRIMARY KEY,
      timestamp DATETIME(3),
      bitrate FLOAT,
      jitter FLOAT,
      lost_percentage FLOAT,
      executed_command TEXT,
      protocol VARCHAR(16),
      packet_size INT
    );
    CREATE TABLE IF NOT EXISTS network_monitor_remote_sim.ping_results (
      id INT AUTO_INCREMENT PRIMARY KEY,
      timestamp DATETIME(3),
      latency FLOAT
    );
    CREATE TABLE IF NOT EXISTS network_monitor_remote_sim.interruptions (
      id INT AUTO_INCREMENT PRIMARY KEY,
      timestamp DATETIME(3),
      interruption_time FLOAT
    );
    TRUNCATE TABLE network_monitor_remote_sim.iperf_results;
    TRUNCATE TABLE network_monitor_remote_sim.ping_results;
    TRUNCATE TABLE network_monitor_remote_sim.interruptions;
  "
}

set_remote_datasource() {
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
    }' >/tmp/remote_ds_update.json
}

main() {
  log "[SUITE] START UTC: $(date -u '+%F %T')"

  configure_runtime

  ./tests/scripts/ns_manual_test.sh cleanup || true
  ./tests/scripts/ns_manual_test.sh setup
  ./tests/scripts/ns_manual_test.sh target

  run_case ROUND1 udp 500 udp_500
  run_case ROUND1 udp 1000 udp_1000
  run_case ROUND1 udp 1472 udp_1472
  run_case ROUND1 tcp 500 tcp_500
  run_case ROUND1 tcp 1000 tcp_1000
  run_case ROUND1 tcp 1472 tcp_1472

  prepare_remote_sim_db
  log "[SUITE] Remote simulated DB ready"

  set_remote_datasource
  log "[SUITE] Remote datasource set to localhost:3306 / network_monitor_remote_sim"

  run_case ROUND2 udp 500 udp_500
  run_case ROUND2 udp 1000 udp_1000
  run_case ROUND2 udp 1472 udp_1472
  run_case ROUND2 tcp 500 tcp_500
  run_case ROUND2 tcp 1000 tcp_1000
  run_case ROUND2 tcp 1472 tcp_1472

  log "[SUITE] END UTC: $(date -u '+%F %T')"

  log "[SUITE] Local summary by command"
  mysql -u myuser -p'mypassword' network_monitor -e "
    SELECT protocol, packet_size, LEFT(executed_command, 80) AS cmd, COUNT(*) AS samples,
           ROUND(AVG(bitrate),2) AS avg_mbps, ROUND(MAX(lost_percentage),2) AS max_loss
    FROM iperf_results
    WHERE timestamp >= DATE_SUB(NOW(), INTERVAL 4 HOUR)
    GROUP BY protocol, packet_size, executed_command
    ORDER BY protocol, packet_size;
  "

  log "[SUITE] Remote-sim summary by command"
  mysql -u myuser -p'mypassword' network_monitor_remote_sim -e "
    SELECT protocol, packet_size, LEFT(executed_command, 80) AS cmd, COUNT(*) AS samples,
           ROUND(AVG(bitrate),2) AS avg_mbps, ROUND(MAX(lost_percentage),2) AS max_loss
    FROM iperf_results
    WHERE timestamp >= DATE_SUB(NOW(), INTERVAL 4 HOUR)
    GROUP BY protocol, packet_size, executed_command
    ORDER BY protocol, packet_size;
  "

  log "[SUITE] Latest interruptions local"
  mysql -u myuser -p'mypassword' network_monitor -e "SELECT id,timestamp,interruption_time FROM interruptions ORDER BY id DESC LIMIT 12;"

  log "[SUITE] Latest interruptions remote_sim"
  mysql -u myuser -p'mypassword' network_monitor_remote_sim -e "SELECT id,timestamp,interruption_time FROM interruptions ORDER BY id DESC LIMIT 12;"

  ./tests/scripts/ns_manual_test.sh cleanup
  log "[SUITE] DONE"
}

main "$@"
