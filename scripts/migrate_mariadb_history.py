#!/usr/bin/env python3
"""Snapshot and reconcile local network-monitor history into InfluxDB 2.

Read-only on MariaDB. Only imports the configured monitoring tables and the
three known nm_* test tables in the configured DB, never LibreNMS. Original
rows are retained as JSON fields, including NULLs, IDs and unzoned timestamps.
"""
import argparse
import csv
import gzip
import hashlib
import io
import json
import math
import os
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'network_monitor'))
from influx_store import InfluxStore, load_config, line_protocol

MOD = 1 << 256
NUMERIC = ('bitrate', 'jitter', 'lost_percentage', 'packet_size', 'latency', 'interruption_time')
TEXT = ('window_size', 'executed_command')


def canonical(row):
    return json.dumps(row, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


class Digest:
    """Order-independent SHA-256 multiset fingerprint plus exact row count."""
    def __init__(self):
        self.count = self.total = self.xor = 0

    def add(self, text):
        value = int.from_bytes(hashlib.sha256(text.encode()).digest(), 'big')
        self.count += 1
        self.total = (self.total + value) % MOD
        self.xor ^= value

    def value(self):
        return {'count': self.count, 'sha256_sum': f'{self.total:064x}', 'sha256_xor': f'{self.xor:064x}'}


def stamp_ns(value, zone):
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=zone, fold=0)
    delta = dt.astimezone(timezone.utc) - datetime(1970, 1, 1, tzinfo=timezone.utc)
    return ((delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds) * 1000


def make_point(row, table, database, host, slot, zone):
    tags = {'host': host, 'run_id': f'mariadb-{database}-{table}',
            'migration_source': 'mariadb', 'source_db': database,
            'source_table': table, 'legacy_slot': f'{slot:012d}'}
    if row.get('protocol'):
        tags['protocol'] = row['protocol']
    for key, value in re.findall(r'(?:^|\s)(role|local_ip|remote_ip|direction)=([^\s]+)', row.get('executed_command') or ''):
        tags[key] = value
    fields = {key: float(row[key]) for key in NUMERIC if row.get(key) is not None}
    # Nullable/empty legacy strings are losslessly retained in legacy_row.
    fields.update({key: row[key] for key in TEXT if row.get(key)})
    fields.update(legacy_id=str(row['id']), legacy_row=canonical(row))
    return line_protocol(table, tags, fields, stamp_ns(row['timestamp'], zone))


def csv_query(store, flux):
    """Stream CSV rather than materializing millions of results in memory."""
    request = Request(store.url + '/api/v2/query?' + urlencode({'org': store.org}),
        data=json.dumps({'query': flux, 'dialect': {'annotations': [], 'header': True}}).encode(),
        headers={'Authorization': 'Token ' + store.token, 'Content-Type': 'application/json', 'Accept': 'application/csv'})
    with urlopen(request, timeout=180) as response:
        header = None
        for row in csv.reader(io.TextIOWrapper(response, encoding='utf-8', newline='')):
            if not row or row[0].startswith('#'):
                continue
            if 'result' in row and 'table' in row:
                header = row
            elif 'error' in row and 'reference' in row:
                raise RuntimeError('InfluxDB streaming query returned an error')
            elif header:
                yield dict(zip(header, row))


def validate_record(record, zone):
    row = json.loads(record['legacy_row'])
    if str(row['id']) != record['legacy_id']:
        raise ValueError('Original ID mismatch')
    actual_ns = stamp_ns(record['_time'].replace('Z', '+00:00'), zone)
    if actual_ns != stamp_ns(row['timestamp'], zone):
        raise ValueError('Timestamp mismatch')
    for key in NUMERIC:
        expected, actual = row.get(key), record.get(key)
        if expected is None:
            if actual not in (None, ''):
                raise ValueError('Unexpected numeric field: ' + key)
        elif actual in (None, '') or not math.isclose(float(expected), float(actual), rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError('Numeric field mismatch: ' + key)
    for key in (*TEXT, 'protocol'):
        if (row.get(key) or '') != (record.get(key) or ''):
            raise ValueError('Text/tag mismatch: ' + key)
    return record['legacy_row']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path('/opt/network_monitor2/setup.conf'))
    parser.add_argument('--directory', type=Path, required=True, help='Protected snapshot/report directory; reuse to resume idempotently')
    parser.add_argument('--timezone', default='Europe/Madrid', help='Timezone of legacy DATETIME values; fold=0 for ambiguous DST times')
    parser.add_argument('--apply', action='store_true', help='Import snapshots and fully reconcile every row')
    args = parser.parse_args()
    os.umask(0o077)
    args.directory.mkdir(parents=True, exist_ok=True)
    args.directory.chmod(0o700)
    config = load_config(args.config)
    database = config['DB_NAME']
    if database.lower() in ('librenms', 'mysql', 'information_schema', 'performance_schema', 'sys'):
        raise ValueError('Refusing to migrate a non-monitoring database')
    host = config.get('NM_HOST') or socket.gethostname()
    zone = ZoneInfo(args.timezone)
    store = InfluxStore(config)
    sql_args = ['mysql', '--connect-timeout=10', '--batch', '--raw', '--quick', '--skip-column-names',
                '-h', config.get('DB_HOST') or '127.0.0.1', '-P', config.get('DB_PORT') or '3306',
                '-u', config['DB_USER'], database]
    sql_env = dict(os.environ, MYSQL_PWD=config['DB_PASS'])

    def sql(query):
        result = subprocess.run(sql_args + ['-e', query], env=sql_env, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('MariaDB query failed (credentials/output suppressed)')
        return result.stdout

    def identifier(value):
        if not re.fullmatch(r'[A-Za-z0-9_]+', value):
            raise ValueError('Unsupported SQL identifier')
        return '`' + value + '`'

    manifest_path = args.directory / 'manifest.json'

    def save(manifest):
        temporary = manifest_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(manifest, indent=2) + '\n')
        temporary.replace(manifest_path)

    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
        if (manifest['source_db'], manifest['host'], manifest['timezone'], manifest['bucket']) != (database, host, args.timezone, store.bucket):
            raise ValueError('Resume settings do not match the snapshot')
    else:
        available = set(sql('SHOW FULL TABLES WHERE Table_type = "BASE TABLE"').splitlines())
        available = {line.split('\t')[0] for line in available}
        requested = [config.get('IPERF_TABLE', 'iperf_results'), config.get('PING_TABLE', 'ping_results'),
                     config.get('INTERRUPTIONS_TABLE', 'interruptions'),
                     'nm_iperf_samples', 'nm_ping_samples', 'nm_interrupt_events']
        tables = list(dict.fromkeys(t for t in requested if t in available))
        if not tables:
            raise ValueError('No monitoring tables found')
        manifest = {'source_db': database, 'host': host, 'timezone': args.timezone,
                    'bucket': store.bucket, 'created_at': datetime.now(timezone.utc).isoformat(),
                    'dst_ambiguity_policy': 'fold=0; original DATETIME preserved in legacy_row', 'tables': {}}
        for table in tables:
            name = identifier(table)
            columns = [line.split('\t')[0] for line in sql('SHOW COLUMNS FROM ' + name).splitlines()]
            if not {'id', 'timestamp'} <= set(columns):
                raise ValueError('Missing primary key or timestamp')
            stats = sql(f'SELECT COUNT(*),COALESCE(MAX(id),0),SUM(timestamp IS NULL) FROM {name}').strip().split('\t')
            if stats[2] not in ('0', 'NULL'):
                raise ValueError('NULL timestamps: manual mapping required before import')
            manifest['tables'][table] = {'columns': columns, 'source_count': int(stats[0]), 'max_id': int(stats[1])}
        save(manifest)

    # Retain a single-transaction SQL backup, with no source data modification.
    dump_path = args.directory / 'source.sql.gz'
    if not manifest.get('sql_backup_sha256'):
        print('Creating protected SQL backup...', flush=True)
        dump_args = ['mysqldump', '--single-transaction', '--skip-lock-tables', '--no-tablespaces',
                     '--skip-comments', '-h', config.get('DB_HOST') or '127.0.0.1',
                     '-P', config.get('DB_PORT') or '3306', '-u', config['DB_USER'], database, *manifest['tables']]
        with (args.directory / 'dump.stderr').open('w') as err, gzip.open(dump_path, 'wb', compresslevel=1) as backup:
            proc = subprocess.Popen(dump_args, env=sql_env, stdout=subprocess.PIPE, stderr=err)
            for chunk in iter(lambda: proc.stdout.read(1024 * 1024), b''):
                backup.write(chunk)
            if proc.wait():
                raise RuntimeError('SQL backup failed; import not started')
        manifest['sql_backup_sha256'] = hashlib.file_digest(dump_path.open('rb'), 'sha256').hexdigest()
        save(manifest)

    for table, info in manifest['tables'].items():
        path = args.directory / (table + '.jsonl.gz')
        if info.get('snapshot_sha256'):
            continue
        print('Snapshotting ' + table + '...', flush=True)
        columns = info['columns']
        expressions = []
        for col in columns:
            value = f"DATE_FORMAT({identifier(col)},'%Y-%m-%d %H:%i:%s.%f')" if col == 'timestamp' else identifier(col)
            expressions.extend(["'" + col + "'", value])
        query = f"SELECT JSON_OBJECT({','.join(expressions)}) FROM {identifier(table)} WHERE id <= {info['max_id']} ORDER BY timestamp,id"
        digest, days, ambiguous = Digest(), {}, 0
        with (args.directory / (table + '.stderr')).open('w') as err, gzip.open(path, 'wt', encoding='utf-8', compresslevel=1) as snapshot:
            proc = subprocess.Popen(sql_args + ['-e', query], env=sql_env, stdout=subprocess.PIPE, stderr=err, text=True)
            for line in proc.stdout:
                row = json.loads(line)
                text = canonical(row)
                digest.add(text)
                dt = datetime.fromisoformat(row['timestamp'])
                ambiguous += dt.replace(tzinfo=zone, fold=0).utcoffset() != dt.replace(tzinfo=zone, fold=1).utcoffset()
                day = dt.replace(tzinfo=zone, fold=0).astimezone(timezone.utc).date().isoformat()
                days[day] = days.get(day, 0) + 1
                snapshot.write(text + '\n')
                if digest.count % 250000 == 0:
                    print(f'  {table}: snapshotted {digest.count}', flush=True)
            if proc.wait():
                raise RuntimeError('Snapshot query failed')
        if digest.count != info['source_count']:
            raise ValueError('Snapshot row count mismatch')
        info.update(snapshot_sha256=hashlib.file_digest(path.open('rb'), 'sha256').hexdigest(),
                    fingerprint=digest.value(), utc_days=days, ambiguous_dst_rows=ambiguous)
        save(manifest)
        print(f'  {table}: {digest.count} rows secured', flush=True)

    if not args.apply:
        print('Snapshots ready; add --apply to import and reconcile.', flush=True)
        return

    for table, info in manifest['tables'].items():
        if info.get('verified'):
            print(table + ': already verified in this manifest', flush=True)
            continue
        path = args.directory / (table + '.jsonl.gz')
        if hashlib.file_digest(path.open('rb'), 'sha256').hexdigest() != info['snapshot_sha256']:
            raise ValueError('Snapshot checksum mismatch')
        written = info.get('imported', 0)
        if written != info['source_count']:
            print('Importing ' + table + '...', flush=True)
            previous, slot, batch, written = None, 0, [], 0
            with gzip.open(path, 'rt', encoding='utf-8') as snapshot:
                for line in snapshot:
                    row = json.loads(line)
                    slot = slot + 1 if row['timestamp'] == previous else 0
                    previous = row['timestamp']
                    batch.append(make_point(row, table, database, host, slot, zone))
                    if len(batch) == 5000:
                        store.write_lines(batch)
                        written += len(batch)
                        batch = []
                        if written % 250000 == 0:
                            print(f'  {table}: imported {written}', flush=True)
                if batch:
                    store.write_lines(batch)
                    written += len(batch)
            if written != info['source_count']:
                raise ValueError('Import count mismatch')
            info['imported'] = written
            save(manifest)
        digest = Digest()
        for day in sorted(info['utc_days']):
            start = datetime.fromisoformat(day).replace(tzinfo=timezone.utc)
            end = start + timedelta(days=1)
            count = 0
            pieces = 24 if info['utc_days'][day] > 100000 else 1
            for piece in range(pieces):
                lower = start + timedelta(seconds=86400 * piece / pieces)
                upper = start + timedelta(seconds=86400 * (piece + 1) / pieces)
                flux = (f'from(bucket: {json.dumps(store.bucket)}) '
                        f'|> range(start: {lower.isoformat().replace("+00:00", "Z")}, stop: {upper.isoformat().replace("+00:00", "Z")}) '
                        f'|> filter(fn: (r) => r._measurement == {json.dumps(table)} and r.host == {json.dumps(host)}) '
                        f'|> filter(fn: (r) => r.migration_source == "mariadb" and r.source_db == {json.dumps(database)} and r.source_table == {json.dumps(table)}) '
                        '|> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")')
                for record in csv_query(store, flux):
                    digest.add(validate_record(record, zone))
                    count += 1
            if count != info['utc_days'][day]:
                raise ValueError(f'Daily count mismatch: {table}, {day}, {count}')
            print(f'  {table}: verified {day} ({count} rows)', flush=True)
        if digest.value() != info['fingerprint']:
            raise ValueError('Full-content fingerprint mismatch: ' + table)
        # Confirm source still has exactly the same row count and boundary.
        stats = sql(f'SELECT COUNT(*),COALESCE(MAX(id),0) FROM {identifier(table)}').strip().split('\t')
        if [int(n) for n in stats] != [info['source_count'], info['max_id']]:
            raise ValueError('Source changed while migrating; another snapshot is required')
        info['verified'] = True
        info['verified_at'] = datetime.now(timezone.utc).isoformat()
        info['target_fingerprint'] = digest.value()
        save(manifest)
        print(f'{table}: VERIFIED {written} rows', flush=True)
    manifest['complete'] = True
    manifest['completed_at'] = datetime.now(timezone.utc).isoformat()
    save(manifest)
    print('All monitoring history imported and fully reconciled. MariaDB unchanged.', flush=True)


if __name__ == '__main__':
    main()
