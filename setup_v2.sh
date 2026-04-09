#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as superuser. Please use sudo."
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/network_monitor2"
COMMAND_NAME="network_monitor2"
SETUP_CONF="$INSTALL_DIR/setup.conf"

echo "========================================="
echo "🚀 Network Monitor v2 Setup (coexisting)"
echo "========================================="
echo "Install dir : $INSTALL_DIR"
echo "Command     : $COMMAND_NAME"
echo "This setup does NOT modify existing network_monitor installation."
echo

mkdir -p "$INSTALL_DIR"

read -r -p "DB host [127.0.0.1]: " DB_HOST
DB_HOST="${DB_HOST:-127.0.0.1}"

read -r -p "DB port [3306]: " DB_PORT
DB_PORT="${DB_PORT:-3306}"

read -r -p "DB name [network_monitor_v2]: " DB_NAME
DB_NAME="${DB_NAME:-network_monitor_v2}"
if [[ "$DB_NAME" != *_v2 ]]; then
  DB_NAME="${DB_NAME}_v2"
fi

read -r -p "DB user: " DB_USER
read -r -s -p "DB password: " DB_PASS
echo

read -r -p "Target/remote IP default (optional): " REMOTE_DB_IP
REMOTE_DB_IP="${REMOTE_DB_IP:-}"

cat > "$SETUP_CONF" <<CFG
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
REMOTE_DB_IP=$REMOTE_DB_IP
CFG

echo "✅ Wrote config: $SETUP_CONF"

cp "$REPO_ROOT"/network_monitor/*.sh "$INSTALL_DIR"/
chmod +x "$INSTALL_DIR"/*.sh
ln -sf "$INSTALL_DIR/server_launcher.sh" "/usr/local/bin/$COMMAND_NAME"

echo "✅ Installed scripts in $INSTALL_DIR"
echo "✅ Created command /usr/local/bin/$COMMAND_NAME"

# Best-effort DB bootstrap
if command -v mysql >/dev/null 2>&1; then
  echo "🗄️  Ensuring DB and tables exist..."

  # Try admin socket first (works when run on DB host with root socket auth).
  mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;" 2>/dev/null || true

  mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
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
  );" || {
    echo "⚠️  Could not create tables automatically."
    echo "   Ensure DB '$DB_NAME' exists and user '$DB_USER' can CREATE/INSERT."
  }
fi

echo
echo "========================================="
echo "✅ v2 setup complete"
echo "Run with: $COMMAND_NAME -i <iface> -t <target_ip>"
echo "Example:  $COMMAND_NAME -i enp60s0 -t 10.10.27.11 -p 5050"
echo "========================================="
