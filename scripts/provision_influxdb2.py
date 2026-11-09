#!/usr/bin/env python3
"""Initialize a local InfluxDB 2 instance and configure the installed runtime.

Run as root after installing InfluxDB 2. Refuses an already initialized server
unless its root-only bootstrap file is present. Does not alter MariaDB data.
"""
import json
import os
import secrets
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'network_monitor'))
from influx_store import load_config


def main():
    if os.geteuid() != 0:
        raise SystemExit('Run as root.')
    os.umask(0o077)
    url = 'http://127.0.0.1:8086'
    secret_file = Path('/root/network-monitor-influxdb-admin.json')

    def api(path, data=None, token=None, method=None):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Token ' + token
        req = Request(url + path, data=json.dumps(data).encode() if data is not None else None,
                      headers=headers, method=method)
        with urlopen(req, timeout=30) as response:
            body = response.read()
            return json.loads(body) if body else {}

    if secret_file.exists():
        admin = json.loads(secret_file.read_text())
    else:
        if not api('/api/v2/setup').get('allowed'):
            raise SystemExit('Existing InfluxDB instance has no known bootstrap credentials; refusing to overwrite.')
        password = secrets.token_urlsafe(32)
        result = api('/api/v2/setup', {'username': 'network-monitor-admin',
            'password': password, 'org': 'network-monitor', 'bucket': 'network-monitor',
            'retentionPeriodSeconds': 0})
        admin = {'url': url, 'username': 'network-monitor-admin', 'password': password,
                 'token': result['auth']['token'], 'org_id': result['org']['id'],
                 'bucket_id': result['bucket']['id']}
        secret_file.write_text(json.dumps(admin, indent=2) + '\n')
        secret_file.chmod(0o600)
    bucket = {'type': 'buckets', 'id': admin['bucket_id'], 'orgID': admin['org_id']}
    config_path = Path('/opt/network_monitor2/setup.conf')
    old = load_config(config_path)
    # Reuse a previously provisioned runtime token on rerun.
    runtime_token = old.get('INFLUX_TOKEN') if old.get('DB_BACKEND') == 'influxdb' else None
    if not runtime_token:
        auth = api('/api/v2/authorizations', {'orgID': admin['org_id'],
            'description': 'network_monitor2 local bucket read/write',
            'permissions': [{'action': a, 'resource': bucket} for a in ('read', 'write')]}, admin['token'])
        runtime_token = auth['token']
    stamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    backup = Path('/var/backups/network_monitor2') / stamp
    backup.mkdir(parents=True, exist_ok=False)
    backup.chmod(0o700)
    subprocess.run(['cp', '-a', '/opt/network_monitor2', str(backup / 'runtime')], check=True)
    values = {'DB_BACKEND': 'influxdb', 'INFLUX_URL': url, 'INFLUX_ORG': 'network-monitor',
              'INFLUX_BUCKET': 'network-monitor', 'INFLUX_TOKEN': runtime_token}
    lines = [line for line in config_path.read_text().splitlines()
             if line.split('=', 1)[0].strip() not in values]
    # Write in place to preserve the existing read ACL for tuser.
    config_path.write_text('\n'.join(lines) + '\n' + '\n'.join(k + '=' + v for k, v in values.items()) + '\n')
    for pattern in ('*.sh', '*.py'):
        for source in (ROOT / 'network_monitor').glob(pattern):
            target = config_path.parent / source.name
            shutil.copyfile(source, target)
            target.chmod(0o755)
    if subprocess.run(['id', 'tuser'], capture_output=True).returncode == 0:
        subprocess.run(['runuser', '-u', 'tuser', '--', 'test', '-r', str(config_path)], check=True)
    if not Path('/etc/grafana/provisioning/datasources').is_dir():
        print('InfluxDB runtime configured; Grafana provisioning skipped (Grafana not installed).')
        print('Previous runtime backed up to:', backup)
        print('Administrator credentials stored root-only in:', secret_file)
        return
    read_auth = api('/api/v2/authorizations', {'orgID': admin['org_id'],
        'description': 'Grafana network monitor read only',
        'permissions': [{'action': 'read', 'resource': bucket}]}, admin['token'])
    provisioning = Path('/etc/grafana/provisioning/datasources/network-monitor-influxdb.yaml')
    # JSON is valid YAML; Grafana reads .yaml files.
    provisioning.write_text(json.dumps({'apiVersion': 1, 'datasources': [{
        'name': 'NetworkMonitorInfluxDB', 'uid': 'NetworkMonitorInfluxDB', 'type': 'influxdb',
        'access': 'proxy', 'url': url, 'editable': False,
        'jsonData': {'version': 'Flux', 'organization': 'network-monitor', 'defaultBucket': 'network-monitor'},
        'secureJsonData': {'token': read_auth['token']},
    }]}, indent=2) + '\n')
    shutil.chown(provisioning, user='root', group='grafana')
    provisioning.chmod(0o640)
    dashboard_dir = Path('/var/lib/grafana/dashboards/network-monitor-influxdb')
    dashboard_dir.parent.mkdir(parents=True, exist_ok=True)
    dashboard_dir.parent.chmod(0o755)
    dashboard_dir.mkdir(parents=True, exist_ok=True)
    dashboard_dir.chmod(0o755)
    shutil.copyfile(ROOT / 'network_monitor/grafana_dashboards/network_monitor_influxdb.json',
                    dashboard_dir / 'network_monitor_influxdb.json')
    (dashboard_dir / 'network_monitor_influxdb.json').chmod(0o644)
    provider = Path('/etc/grafana/provisioning/dashboards/network-monitor-influxdb.yaml')
    provider.write_text(json.dumps({'apiVersion': 1, 'providers': [{
        'name': 'Network Monitor InfluxDB', 'folder': 'Network Monitor', 'type': 'file',
        'disableDeletion': True, 'updateIntervalSeconds': 30,
        'options': {'path': str(dashboard_dir)},
    }]}, indent=2) + '\n')
    shutil.chown(provider, user='root', group='grafana')
    provider.chmod(0o640)
    print('Provisioned network-monitor org/bucket and bucket-scoped runtime/Grafana tokens.')
    print('Previous runtime and configuration backed up to:', backup)
    print('Administrator credentials stored root-only in:', secret_file)
    print('No historical MariaDB data deleted or imported.')


if __name__ == '__main__':
    main()
