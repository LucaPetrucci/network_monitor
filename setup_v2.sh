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
VENV_DIR="$INSTALL_DIR/.venv"
IPERF_TABLE_DEFAULT="iperf_results"
PING_TABLE_DEFAULT="ping_results"
INTERRUPTIONS_TABLE_DEFAULT="interruptions"

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

read -r -p "DB user: " DB_USER
read -r -s -p "DB password: " DB_PASS
echo

read -r -p "iperf table [$IPERF_TABLE_DEFAULT]: " IPERF_TABLE
IPERF_TABLE="${IPERF_TABLE:-$IPERF_TABLE_DEFAULT}"

read -r -p "ping table [$PING_TABLE_DEFAULT]: " PING_TABLE
PING_TABLE="${PING_TABLE:-$PING_TABLE_DEFAULT}"

read -r -p "interruptions table [$INTERRUPTIONS_TABLE_DEFAULT]: " INTERRUPTIONS_TABLE
INTERRUPTIONS_TABLE="${INTERRUPTIONS_TABLE:-$INTERRUPTIONS_TABLE_DEFAULT}"

cat > "$SETUP_CONF" <<CFG
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
IPERF_TABLE=$IPERF_TABLE
PING_TABLE=$PING_TABLE
INTERRUPTIONS_TABLE=$INTERRUPTIONS_TABLE
CFG

echo "✅ Wrote config: $SETUP_CONF"

cp "$REPO_ROOT"/network_monitor/*.sh "$INSTALL_DIR"/
cp "$REPO_ROOT"/network_monitor/*.py "$INSTALL_DIR"/
cp "$REPO_ROOT"/requirements.txt "$INSTALL_DIR"/
chmod +x "$INSTALL_DIR"/*.sh
chmod +x "$INSTALL_DIR"/*.py
ln -sf "$INSTALL_DIR/server_launcher.sh" "/usr/local/bin/$COMMAND_NAME"

echo "✅ Installed scripts in $INSTALL_DIR"
echo "✅ Created command /usr/local/bin/$COMMAND_NAME"

# Best-effort DB bootstrap
if command -v mysql >/dev/null 2>&1; then
  echo "🗄️  Ensuring DB access and schema..."
  echo "   Target DB: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"

  # Preflight host:port reachability.
  if ! timeout 3 bash -lc "echo > /dev/tcp/$DB_HOST/$DB_PORT" 2>/dev/null; then
    echo "❌ Cannot reach MariaDB at $DB_HOST:$DB_PORT"
    echo "   Check host/port/firewall and rerun setup."
    exit 1
  fi

  # Try admin bootstrap first (socket/root auth on DB host).
  if mysql -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
    mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
    mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';"
    mysql -e "FLUSH PRIVILEGES;"
    echo "✅ Verified/created DB, user and grants (idempotent)."
  else
    echo "⚠️  Admin bootstrap skipped (no local mysql admin access)."
    echo "   Expecting DB/user/grants to be already provisioned."
  fi

  mysql_cmd=(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME")

  # Verify application login before schema operations.
  if ! "${mysql_cmd[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
    echo "❌ App DB login failed for $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
    echo "   Check DB_USER/DB_PASS in $SETUP_CONF and user grants."
    exit 1
  fi

  "${mysql_cmd[@]}" -e "
  CREATE TABLE IF NOT EXISTS \`$IPERF_TABLE\` (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp DATETIME(3),
    bitrate FLOAT,
    jitter FLOAT,
    lost_percentage FLOAT,
    executed_command TEXT,
    protocol VARCHAR(16),
    packet_size INT
  );
  CREATE TABLE IF NOT EXISTS \`$PING_TABLE\` (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp DATETIME(3),
    latency FLOAT
  );
  CREATE TABLE IF NOT EXISTS \`$INTERRUPTIONS_TABLE\` (
    id INT AUTO_INCREMENT PRIMARY KEY,
    timestamp DATETIME(3),
    interruption_time FLOAT
  );" || {
    echo "⚠️  Could not create tables automatically."
    echo "   Ensure DB '$DB_NAME' exists and user '$DB_USER' can CREATE/INSERT."
    echo "   Connection used: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
    exit 1
  }

  # Schema migration for legacy v2 databases (pre-metadata columns).
  ensure_column_exists() {
    local table_name="$1"
    local column_name="$2"
    local column_def="$3"

    local exists
    exists=$("${mysql_cmd[@]}" -Nse \
      "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='$table_name' AND COLUMN_NAME='$column_name';" \
      2>/dev/null || echo "0")

    if [ "$exists" = "0" ]; then
      echo "🔄 Adding missing column: ${table_name}.${column_name}"
      "${mysql_cmd[@]}" -e \
        "ALTER TABLE \`$table_name\` ADD COLUMN \`$column_name\` $column_def;" \
        || { echo "❌ Failed to add ${table_name}.${column_name}"; exit 1; }
    fi
  }

  ensure_column_exists "$IPERF_TABLE" "executed_command" "TEXT"
  ensure_column_exists "$IPERF_TABLE" "protocol" "VARCHAR(16)"
  ensure_column_exists "$IPERF_TABLE" "packet_size" "INT"

  ensure_compat_view() {
    local legacy_name="$1"
    local source_table="$2"
    local existing_base_type

    if [ "$legacy_name" = "$source_table" ]; then
      return
    fi

    existing_base_type=$("${mysql_cmd[@]}" -Nse \
      "SELECT TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='$legacy_name';" \
      2>/dev/null || true)

    if [ -n "$existing_base_type" ] && [ "$existing_base_type" != "VIEW" ]; then
      echo "⚠️  Compatibility view '$legacy_name' not created because a base table with that name already exists."
      return
    fi

    "${mysql_cmd[@]}" -e "DROP VIEW IF EXISTS \`$legacy_name\`;"
    "${mysql_cmd[@]}" -e "CREATE VIEW \`$legacy_name\` AS SELECT * FROM \`$source_table\`;" \
      || echo "⚠️  Failed to create compatibility view '$legacy_name' -> '$source_table'"
  }

  ensure_compat_view "iperf_results" "$IPERF_TABLE"
  ensure_compat_view "ping_results" "$PING_TABLE"
  ensure_compat_view "interruptions" "$INTERRUPTIONS_TABLE"

  echo "✅ DB schema is up to date for dashboard queries."
fi

echo "📦 Creating install-local Python virtual environment..."
apt-get update
apt-get install -y python3-venv
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

echo
echo "========================================="
echo "✅ v2 setup complete"
echo "Server:   $COMMAND_NAME --server --bind-ip <local_test_ip>"
echo "Client:   $COMMAND_NAME <target_ip> --source-ip <local_test_ip>"
echo "Export:   $COMMAND_NAME --export-excel results.xlsx"
echo "Python:   $VENV_DIR/bin/python3"
echo "========================================="
