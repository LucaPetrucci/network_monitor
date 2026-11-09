#!/usr/bin/env bash
# Pinned local InfluxDB 2 deployment for the current amd64 Debian/Ubuntu NUCs.
set -euo pipefail
[[ $(id -u) = 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $(dpkg --print-architecture) = amd64 ]] || { echo 'This installer requires amd64.' >&2; exit 1; }
version=2.7.12
package="/var/tmp/influxdb2_${version}-1_amd64.deb"
if ! dpkg-query -W -f='${Status}' influxdb2 2>/dev/null | grep -q 'install ok installed'; then
  curl -fL "https://dl.influxdata.com/influxdb/releases/v${version}/influxdb2_${version}-1_amd64.deb" -o "$package"
  echo "aab12ffaad81bd15579ee171f7fb9c82c2ea778c2a7f4af24deb712bc5f42a13  $package" | sha256sum -c
  dpkg -i "$package"
fi
mkdir -p /etc/systemd/system/influxdb.service.d
cat > /etc/systemd/system/influxdb.service.d/network-monitor.conf <<'CONF'
[Service]
Environment=INFLUXD_HTTP_BIND_ADDRESS=127.0.0.1:8086
CONF
systemctl daemon-reload
systemctl enable influxdb
systemctl restart influxdb
for attempt in {1..30}; do
  if curl -fsS http://127.0.0.1:8086/health >/dev/null; then exit 0; fi
  sleep 1
done
echo 'InfluxDB did not become healthy.' >&2
exit 1
