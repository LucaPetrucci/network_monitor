#!/usr/bin/env python3
"""InfluxDB 2 HTTP storage, shared by shell collectors and Excel export.

No third-party dependency. Tokens are read from protected config/environment,
never command arguments. Times from collectors are local wall times converted
to UTC; stored numeric units match the MariaDB backend (Mbit/s, ms, %, seconds).
"""
import csv
import io
import json
import math
import os
import shlex
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


def load_config(path):
    config = {}
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        value = value.strip()
        if value.startswith(('"', "'")):
            parts = shlex.split(value)
            value = parts[0] if parts else ''
        config[key.strip()] = value
    return config


def timestamp_ns(value):
    dt = datetime.fromisoformat(value.replace('Z', '+00:00'))
    # astimezone interprets naive collector timestamps in the host's local TZ.
    dt = dt.astimezone(timezone.utc)
    delta = dt - datetime(1970, 1, 1, tzinfo=timezone.utc)
    return ((delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds) * 1000


def escape_key(value):
    value = str(value)
    if '\n' in value or '\r' in value:
        raise ValueError('Newlines are not allowed in measurement/tag names')
    return value.replace('\\', '\\\\').replace(' ', '\\ ').replace(',', '\\,').replace('=', '\\=')


def field_value(value):
    if isinstance(value, str):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'
    value = float(value)
    if not math.isfinite(value):
        raise ValueError('Non-finite metric')
    return repr(value)


def line_protocol(measurement, tags, fields, ns):
    series = escape_key(measurement) + ''.join(
        ',' + escape_key(k) + '=' + escape_key(v)
        for k, v in sorted(tags.items()) if v is not None and str(v)
    )
    values = ','.join(escape_key(k) + '=' + field_value(v)
                      for k, v in fields.items() if v is not None and v != '')
    if not values:
        raise ValueError('Empty sample')
    return f'{series} {values} {int(ns)}'


class InfluxStore:
    def __init__(self, config):
        self.config = config
        required = ['INFLUX_URL', 'INFLUX_ORG', 'INFLUX_BUCKET', 'INFLUX_TOKEN']
        missing = [key for key in required if not config.get(key)]
        if missing:
            raise ValueError('Missing InfluxDB settings: ' + ', '.join(missing))
        self.url = config['INFLUX_URL'].rstrip('/')
        parsed = urlsplit(self.url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username:
            raise ValueError('INFLUX_URL must be an HTTP(S) URL without credentials')
        self.token = config['INFLUX_TOKEN']
        self.org = config['INFLUX_ORG']
        self.bucket = config['INFLUX_BUCKET']

    def request(self, path, data, content_type, retry=False):
        for attempt in range(3 if retry else 1):
            req = Request(self.url + path, data=data.encode(), headers={
                'Authorization': 'Token ' + self.token,
                'Content-Type': content_type,
                'Accept': 'application/csv',
            })
            try:
                with urlopen(req, timeout=10) as response:
                    return response.read().decode()
            except HTTPError as exc:
                if retry and exc.code in (429, 500, 502, 503, 504) and attempt < 2:
                    time.sleep(0.2 * (attempt + 1))
                    continue
                # Do not print request headers, tokens, or response bodies.
                raise RuntimeError(f'InfluxDB HTTP {exc.code}') from None
            except (URLError, TimeoutError):
                if retry and attempt < 2:
                    time.sleep(0.2 * (attempt + 1))
                    continue
                raise RuntimeError('InfluxDB connection failed') from None

    def write_lines(self, lines):
        query = urlencode({'org': self.org, 'bucket': self.bucket, 'precision': 'ns'})
        self.request('/api/v2/write?' + query, '\n'.join(lines), 'text/plain; charset=utf-8', retry=True)

    def query(self, flux):
        text = self.request('/api/v2/query?' + urlencode({'org': self.org}), json.dumps({
            'query': flux,
            'dialect': {'annotations': [], 'header': True, 'delimiter': ','},
        }), 'application/json')
        rows, header = [], None
        for row in csv.reader(io.StringIO(text)):
            if not row or row[0].startswith('#'):
                continue
            if 'result' in row and 'table' in row:
                header = row
                continue
            if 'error' in row and 'reference' in row:
                raise RuntimeError('InfluxDB query returned an error')
            if header:
                record = dict(zip(header, row))
                if record.get('error'):
                    raise RuntimeError('InfluxDB query returned an error')
                rows.append(record)
        return rows

    def records(self, measurement, start=None, end=None, host=None):
        start_ns = timestamp_ns(start) if start else 0
        stop_ns = timestamp_ns(end) + 1 if end else time.time_ns() + 1
        if start_ns >= stop_ns:
            raise ValueError('Invalid export time range')
        flux = (f'from(bucket: {json.dumps(self.bucket)}) '
                f'|> range(start: time(v: {start_ns}), stop: time(v: {stop_ns})) '
                f'|> filter(fn: (r) => r._measurement == {json.dumps(measurement)}) ')
        if host:
            flux += f'|> filter(fn: (r) => r.host == {json.dumps(host)}) '
        flux += '|> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value") |> group() |> sort(columns: ["_time"])'
        return self.query(flux)


def write_sample(config, kind, stamp, values):
    tags = {'host': config.get('NM_HOST') or socket.gethostname(),
            'run_id': config.get('NM_RUN_ID', 'standalone')}
    if kind == 'iperf':
        bitrate, jitter, loss, packet, window, protocol, metadata = values
        tags['protocol'] = protocol
        meta = dict(part.split('=', 1) for part in shlex.split(metadata) if '=' in part)
        for key in ('role', 'local_ip', 'remote_ip', 'direction'):
            if meta.get(key):
                tags[key] = meta[key]
        fields = {'bitrate': float(bitrate), 'jitter': float(jitter),
                  'lost_percentage': float(loss), 'packet_size': float(packet) if packet else None,
                  'window_size': window, 'executed_command': metadata}
        measurement = config.get('IPERF_TABLE', 'iperf_results')
    elif kind in ('ping', 'interruption'):
        value, target, source = values
        tags.update(target_ip=target, source_ip=source)
        fields = {'latency' if kind == 'ping' else 'interruption_time': float(value)}
        measurement = config.get('PING_TABLE', 'ping_results') if kind == 'ping' else config.get('INTERRUPTIONS_TABLE', 'interruptions')
    else:
        raise ValueError('Unknown measurement kind')
    InfluxStore(config).write_lines([line_protocol(measurement, tags, fields, timestamp_ns(stamp))])


def main():
    try:
        config = load_config(Path(__file__).resolve().parent / 'setup.conf')
        config.update({k: v for k, v in os.environ.items()
                       if k.startswith('INFLUX_') or k.startswith('NM_')})
        if sys.argv[1:] == ['check']:
            store = InfluxStore(config)
            store.query(f'from(bucket: {json.dumps(store.bucket)}) |> range(start: -1m) |> limit(n: 1)')
            return 0
        if len(sys.argv) < 5 or sys.argv[1] != 'write':
            raise ValueError('Usage: influx_store.py check | write KIND TIMESTAMP VALUES...')
        write_sample(config, sys.argv[2], sys.argv[3], sys.argv[4:])
        return 0
    except (ValueError, OSError, RuntimeError) as exc:
        print(f'Error storing sample: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
