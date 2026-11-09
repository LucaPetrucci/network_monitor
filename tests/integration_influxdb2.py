#!/usr/bin/env python3
"""Live storage/export contract test in a disposable bucket (root bootstrap).

Creates its own bucket and scoped token, then removes only those resources.
Never inserts synthetic samples into the production network-monitor bucket.
"""
import json
import socket
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'network_monitor'))
from influx_store import InfluxStore, write_sample
from export_excel import export_influx
from openpyxl import load_workbook


def main():
    admin = json.loads(Path('/root/network-monitor-influxdb-admin.json').read_text())

    def api(path, data=None, method=None):
        request = Request(admin['url'] + path, headers={
            'Authorization': 'Token ' + admin['token'], 'Content-Type': 'application/json'},
            data=json.dumps(data).encode() if data is not None else None, method=method)
        with urlopen(request, timeout=10) as response:
            body = response.read()
            return json.loads(body) if body else {}

    bucket = api('/api/v2/buckets', {'orgID': admin['org_id'],
        'name': 'network-monitor-check-' + uuid.uuid4().hex,
        'retentionRules': [{'type': 'expire', 'everySeconds': 3600}]})
    auth = None
    try:
        auth = api('/api/v2/authorizations', {'orgID': admin['org_id'],
            'permissions': [{'action': action, 'resource': {'type': 'buckets',
                'id': bucket['id'], 'orgID': admin['org_id']}} for action in ('read', 'write')]})
        config = {'INFLUX_URL': admin['url'], 'INFLUX_ORG': admin['org_id'],
                  'INFLUX_BUCKET': bucket['name'], 'INFLUX_TOKEN': auth['token'],
                  'NM_HOST': socket.gethostname(), 'NM_RUN_ID': 'isolated-verification'}
        stamp = datetime.now(timezone.utc).isoformat()
        metadata = 'role=client protocol=udp direction=reverse note="comma, quote"'
        write_sample(config, 'iperf', stamp, ['1.25', '0.125', '2.5', '1200', '', 'udp', metadata])
        write_sample(config, 'ping', stamp, ['3.5', '127.0.0.1', '127.0.0.1'])
        write_sample(config, 'interruption', stamp, ['5.25', '127.0.0.1', '127.0.0.1'])
        store = InfluxStore(config)
        iperf = store.records('iperf_results')
        assert len(iperf) == 1 and iperf[0]['protocol'] == 'udp'
        assert iperf[0]['executed_command'] == metadata
        assert float(iperf[0]['bitrate']) == 1.25
        assert float(store.records('ping_results')[0]['latency']) == 3.5
        assert float(store.records('interruptions')[0]['interruption_time']) == 5.25
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'contract.xlsx'
            export_influx(config, output, None, None)
            wb = load_workbook(output)
            assert all(wb[sheet].max_row == 2 for sheet in wb.sheetnames)
        # Read-only tokens must be rejected on writes.
        readonly = api('/api/v2/authorizations', {'orgID': admin['org_id'],
            'permissions': [{'action': 'read', 'resource': {'type': 'buckets', 'id': bucket['id'], 'orgID': admin['org_id']}}]})
        try:
            ro = InfluxStore(dict(config, INFLUX_TOKEN=readonly['token']))
            assert len(ro.records('iperf_results')) == 1
            try:
                ro.write_lines(['must_not_write value=1.0 1'])
            except RuntimeError:
                pass
            else:
                raise AssertionError('Read-only token allowed writing')
        finally:
            api('/api/v2/authorizations/' + readonly['id'], method='DELETE')
        print('Live InfluxDB write/query/export and read-only permission checks passed.')
    finally:
        if auth:
            api('/api/v2/authorizations/' + auth['id'], method='DELETE')
        api('/api/v2/buckets/' + bucket['id'], method='DELETE')
        print('Disposable verification bucket removed; production data untouched.')


if __name__ == '__main__':
    main()
