#!/bin/bash

# Source setup.conf from this installation directory.
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
if [ ! -f "$SCRIPT_DIR/setup.conf" ]; then
  echo "Error: setup.conf not found in $SCRIPT_DIR"
  exit 1
fi
source "$SCRIPT_DIR/setup.conf"

# Initialize variables
target_ip=""

# Parse command-line options
while getopts "t:" opt; do
  case $opt in
    t) target_ip="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
  esac
done

# Check if target IP is provided
if [ -z "$target_ip" ]; then
  echo "Error: Target IP must be specified."
  echo "Usage: $0 -t <target_ip>"
  exit 1
fi

# Function to block traffic
block_traffic() {
  iptables -A INPUT -s "$target_ip" -j DROP
  iptables -A OUTPUT -d "$target_ip" -j DROP
  iptables -A FORWARD -s "$target_ip" -j DROP
  iptables -A FORWARD -d "$target_ip" -j DROP
  echo "Traffic blocked for $target_ip"
}

# Function to unblock traffic and exit
unblock_traffic_and_exit() {
  iptables -D INPUT -s "$target_ip" -j DROP
  iptables -D OUTPUT -d "$target_ip" -j DROP
  iptables -D FORWARD -s "$target_ip" -j DROP
  iptables -D FORWARD -d "$target_ip" -j DROP
  echo "Traffic unblocked for $target_ip"
  echo "Exiting disconnection_test.sh"
  exit 0
}

# Trap SIGINT (Ctrl+C) to unblock traffic and exit when script is cancelled
trap unblock_traffic_and_exit INT

# Block traffic
block_traffic

echo "Disconnection test in progress. Press Ctrl+C to stop, unblock traffic, and exit."

# Wait indefinitely
while true; do
  sleep 1
done
