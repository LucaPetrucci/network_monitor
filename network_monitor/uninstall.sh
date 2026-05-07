#!/bin/bash

# Check if the script is being run as superuser
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as superuser. Please use sudo."
    exit 1
fi

# Initialize flag
uninstall_all=false

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--all) uninstall_all=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Resolve installation directory from real script path.
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
LAUNCHER_PATH="$SCRIPT_DIR/server_launcher.sh"

# Source the setup.conf file
if [ -f "$SCRIPT_DIR/setup.conf" ]; then
    source "$SCRIPT_DIR/setup.conf"
else
    echo "setup.conf not found. Some operations may fail."
fi

# Remove matching symbolic links (network_monitor, network_monitor2, etc.)
for link in /usr/local/bin/network_monitor /usr/local/bin/network_monitor2; do
    if [ -L "$link" ]; then
        target="$(readlink -f "$link" 2>/dev/null || true)"
        if [ "$target" = "$LAUNCHER_PATH" ]; then
            rm "$link"
            echo "Removed symbolic link: $link"
        fi
    fi
done

# Remove the installation directory
if [ -d "$SCRIPT_DIR" ]; then
    rm -rf "$SCRIPT_DIR"
    echo "Removed directory: $SCRIPT_DIR"
fi

# Remove the database and user
if command -v mysql &> /dev/null; then
    if [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
        mysql -e "DROP DATABASE IF EXISTS $DB_NAME;"
        mysql -e "DROP USER IF EXISTS '$DB_USER'@'%';"
        mysql -e "FLUSH PRIVILEGES;"
        echo "Removed database $DB_NAME and user $DB_USER"
    else
        echo "Database name or user not found in setup.conf. Skipping database removal."
    fi
fi

if [ "$uninstall_all" = true ]; then
    # Remove iperf3
    if command -v iperf3 &> /dev/null; then
        apt-get remove -y iperf3
        echo "Removed iperf3"
    fi

    # Remove Grafana
    if command -v grafana-server &> /dev/null; then
        systemctl stop grafana-server
        systemctl disable grafana-server
        apt-get remove -y grafana
        rm -rf /etc/grafana /var/lib/grafana
        echo "Removed Grafana"
    fi

    # Remove jq
    if command -v jq &> /dev/null; then
        apt-get remove -y jq
        echo "Removed jq"
    fi

    # Remove MariaDB server
    if command -v mysql &> /dev/null; then
        apt-get remove -y mariadb-server
        apt-get autoremove -y
        rm -rf /var/lib/mysql /etc/mysql
        echo "Removed MariaDB server"
    fi

    echo "All associated programs have been uninstalled."
else
    echo "Associated programs (iperf3, Grafana, jq, MariaDB) were not uninstalled."
    echo "Use the -a or --all flag to uninstall these programs as well."
fi

echo "Uninstallation complete. The network monitoring system has been removed."
