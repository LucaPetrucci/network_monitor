#!/usr/bin/env bash
# Run on each NUC: sudo bash scripts/grant_runtime_access.sh tuser
set -euo pipefail

runtime_user="${1:-tuser}"
config=/opt/network_monitor2/setup.conf

if [ "$(id -u)" -ne 0 ]; then
  echo 'Run this script with sudo.' >&2
  exit 1
fi
id "$runtime_user" >/dev/null
command -v setfacl >/dev/null || {
  echo 'Install ACL tools first: sudo apt-get install acl' >&2
  exit 1
}
test -f "$config"
# Preserve ownership and existing access; grant only configuration read access.
setfacl -m "u:${runtime_user}:r--" "$config"
runuser -u "$runtime_user" -- test -r "$config"
runuser -u "$runtime_user" -- /usr/local/bin/network_monitor2 --help
echo "Verified configuration access and launcher for $runtime_user."
