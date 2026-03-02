#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/home/luca/network_monitor"
NM_SRC_DIR="$REPO_DIR/network_monitor"
NM_OPT_DIR="/opt/network_monitor"

# DB settings (override via environment if needed)
DB_USER="${DB_USER:-myuser}"
DB_PASS="${DB_PASS:-mypassword}"
DB_NAME="${DB_NAME:-network_monitor}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

MONITOR_CMD=""

usage() {
  cat <<'USAGE'
Uso:
  ./ns_manual_test.sh <blocco>

Blocchi disponibili:
  setup      Precheck + cleanup + creazione namespace/veth + IP/link
  target     Avvia iperf3 server target in nsRemote (10.10.0.2:5050)
  monitor    Avvia network_monitor in root con binding multi-interfaccia
  extra      Test extra nsRemote -> 10.20.0.1:5050 (con fallback server temporaneo)
  verify     Verifiche rete/processi + query MySQL + nota Grafana
  cleanup    Termina processi e rimuove namespace/veth

Esempio sequenza manuale:
  ./ns_manual_test.sh setup
  ./ns_manual_test.sh target
  ./ns_manual_test.sh monitor
  ./ns_manual_test.sh extra
  ./ns_manual_test.sh verify
  ./ns_manual_test.sh cleanup

Override DB (container):
  DB_HOST=127.0.0.1 DB_PORT=3306 DB_USER=myuser DB_PASS=mypassword DB_NAME=comsa ./ns_manual_test.sh verify
USAGE
}

require_tools() {
  if ! command -v ip >/dev/null 2>&1; then
    echo "[ERRORE] comando 'ip' non trovato (iproute2 richiesto)."
    exit 1
  fi
  if ! command -v iperf3 >/dev/null 2>&1; then
    echo "[ERRORE] iperf3 non installato."
    exit 1
  fi
}

build_mysql_cmd() {
  local -n ref="$1"
  ref=(mysql -u "$DB_USER" -p"$DB_PASS" -h "$DB_HOST" -P "$DB_PORT" "$DB_NAME")
}

ensure_network_monitor() {
  if command -v network_monitor >/dev/null 2>&1; then
    MONITOR_CMD="network_monitor"
    return
  fi

  echo "[INFO] network_monitor non trovato: bootstrap minimale (senza setup.sh)"
  if [[ ! -d "$NM_SRC_DIR" ]]; then
    echo "[ERRORE] Cartella sorgenti non trovata: $NM_SRC_DIR"
    exit 1
  fi

  sudo mkdir -p "$NM_OPT_DIR"
  sudo cp "$NM_SRC_DIR"/*.sh "$NM_OPT_DIR"/
  sudo chmod +x "$NM_OPT_DIR"/*.sh

  sudo tee "$NM_OPT_DIR/setup.conf" >/dev/null <<EOF_CONF
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT

ADD_REMOTE=n
REMOTE_DB_IP=
REMOTE_DB_PORT=
REMOTE_DB_NAME=
REMOTE_DB_USER=
REMOTE_DB_PASS=
EOF_CONF

  MONITOR_CMD="$NM_OPT_DIR/server_launcher.sh"
}

block_setup() {
  echo "# =============================="
  echo "# BLOCCO 1-3: PRECHECK + CLEAN + NS/VETH/IP"
  echo "# =============================="

  cd "$REPO_DIR"
  require_tools

  echo "[INFO] Pulizia namespace/veth preesistenti"
  sudo ip netns del nsRemote 2>/dev/null || true
  sudo ip link del vethA 2>/dev/null || true
  sudo ip link del vethB 2>/dev/null || true
  sudo ip link del vethA-ns 2>/dev/null || true
  sudo ip link del vethB-ns 2>/dev/null || true

  sudo rm -f /tmp/iperf3-nsRemote-5050.pid /tmp/network_monitor.pid /tmp/iperf3-root-bind-vethB.pid

  echo "[INFO] Creo nsRemote + veth pair"
  sudo ip netns add nsRemote
  sudo ip link add vethA type veth peer name vethA-ns
  sudo ip link add vethB type veth peer name vethB-ns
  sudo ip link set vethA-ns netns nsRemote
  sudo ip link set vethB-ns netns nsRemote

  echo "[INFO] Configuro IP e porto UP le interfacce"
  sudo ip addr add 10.10.0.1/24 dev vethA
  sudo ip addr add 10.20.0.1/24 dev vethB
  sudo ip link set vethA up
  sudo ip link set vethB up

  sudo ip netns exec nsRemote ip addr add 10.10.0.2/24 dev vethA-ns
  sudo ip netns exec nsRemote ip addr add 10.20.0.2/24 dev vethB-ns
  sudo ip netns exec nsRemote ip link set lo up
  sudo ip netns exec nsRemote ip link set vethA-ns up
  sudo ip netns exec nsRemote ip link set vethB-ns up

  echo "[OK] Setup completato"
}

block_target() {
  echo "# =============================="
  echo "# BLOCCO 4: TARGET IN nsRemote"
  echo "# =============================="

  require_tools

  sudo ip netns exec nsRemote bash -lc \
    "nohup iperf3 -s -p 5050 >/tmp/iperf3-nsRemote-5050.log 2>&1 & echo \$! >/tmp/iperf3-nsRemote-5050.pid"

  echo "[OK] iperf3 target avviato in nsRemote su porta 5050"
}

block_monitor() {
  echo "# =============================="
  echo "# BLOCCO 5: AVVIO network_monitor"
  echo "# =============================="

  ensure_network_monitor

  sudo bash -lc \
    "nohup bash -c 'printf "\\n" | $MONITOR_CMD -i vethA -t 10.10.0.2 -S 10.20.0.1 -I vethB -p 5050' >/tmp/network_monitor-veth.log 2>&1 & echo \$! >/tmp/network_monitor.pid"

  sleep 3
  echo "[OK] network_monitor avviato con comando: $MONITOR_CMD (log: /tmp/network_monitor-veth.log)"
}

block_extra() {
  echo "# =============================="
  echo "# BLOCCO 6: TEST EXTRA"
  echo "# =============================="

  require_tools

  if ! sudo ip netns exec nsRemote iperf3 -c 10.20.0.1 -p 5050 -t 20; then
    echo "[WARN] Nessun listener su 10.20.0.1:5050, avvio server temporaneo bindato"
    sudo bash -lc \
      "nohup iperf3 -s -B 10.20.0.1 -p 5050 >/tmp/iperf3-root-bind-vethB.log 2>&1 & echo \$! >/tmp/iperf3-root-bind-vethB.pid"
    sleep 2
    sudo ip netns exec nsRemote iperf3 -c 10.20.0.1 -p 5050 -t 20
  fi

  echo "[OK] Test extra completato"
}

block_verify() {
  echo "# =============================="
  echo "# BLOCCO 7: VERIFICHE"
  echo "# =============================="

  echo "===== ip a ====="
  ip a

  echo "===== ip route ====="
  ip route

  echo "===== ip netns exec nsRemote ip a ====="
  sudo ip netns exec nsRemote ip a

  echo "===== ping root -> 10.10.0.2 ====="
  ping -c 3 -I vethA 10.10.0.2

  echo "===== ping nsRemote -> 10.20.0.1 ====="
  sudo ip netns exec nsRemote ping -c 3 -I vethB-ns 10.20.0.1

  echo "===== ss -lntp | grep 5050 ====="
  ss -lntp | grep 5050 || true

  echo "===== mysql counts ====="
  local mysql_cmd=()
  build_mysql_cmd mysql_cmd
  "${mysql_cmd[@]}" -e "SELECT COUNT(*) AS iperf_results_count FROM iperf_results;"
  "${mysql_cmd[@]}" -e "SELECT COUNT(*) AS ping_results_count FROM ping_results;"
  "${mysql_cmd[@]}" -e "SELECT COUNT(*) AS interruptions_count FROM interruptions;"

  echo "===== Grafana ====="
  echo "Apri: http://localhost:3000  (admin/admin)"
}

block_cleanup() {
  echo "# =============================="
  echo "# BLOCCO 8: CLEANUP"
  echo "# =============================="

  if [[ -f /tmp/network_monitor.pid ]]; then
    sudo kill "$(cat /tmp/network_monitor.pid)" 2>/dev/null || true
  fi
  if [[ -f /tmp/iperf3-root-bind-vethB.pid ]]; then
    sudo kill "$(cat /tmp/iperf3-root-bind-vethB.pid)" 2>/dev/null || true
  fi
  if [[ -f /tmp/iperf3-nsRemote-5050.pid ]]; then
    sudo kill "$(cat /tmp/iperf3-nsRemote-5050.pid)" 2>/dev/null || true
  fi

  sudo pkill -f "iperf3 -s -B 10.20.0.1 -p 5050" 2>/dev/null || true
  sudo pkill -f "iperf3 -s -p 5050" 2>/dev/null || true
  sudo pkill -f "network_monitor -i vethA -t 10.10.0.2 -S 10.20.0.1 -I vethB -p 5050" 2>/dev/null || true
  sudo pkill -f "$NM_OPT_DIR/server_launcher.sh -i vethA -t 10.10.0.2 -S 10.20.0.1 -I vethB -p 5050" 2>/dev/null || true

  sudo ip netns del nsRemote 2>/dev/null || true
  sudo ip link del vethA 2>/dev/null || true
  sudo ip link del vethB 2>/dev/null || true

  echo "[OK] Cleanup completato"
}

main() {
  local block="${1:-}"
  case "$block" in
    setup) block_setup ;;
    target) block_target ;;
    monitor) block_monitor ;;
    extra) block_extra ;;
    verify) block_verify ;;
    cleanup) block_cleanup ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
