#!/usr/bin/env python3
"""Read-only, current MariaDB vs InfluxDB exact historical row reconciliation.

Uses an on-disk ID index to compare every source row, not just saved migration
flags or counts. Only the temporary index and report are written locally.
"""
import argparse
import json
import os
import re
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from migrate_mariadb_history import (InfluxStore, canonical, csv_query, load_config,
                                     validate_record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--config', type=Path, default=Path('/opt/network_monitor2/setup.conf'))
    args = parser.parse_args()
    os.umask(0o077)
    args.directory.mkdir(parents=True, exist_ok=False)
    args.directory.chmod(0o700)
    config = load_config(args.config)
    manifest = json.loads(args.manifest.read_text())
    if config['DB_NAME'] != manifest['source_db'] or config['INFLUX_BUCKET'] != manifest['bucket']:
        raise ValueError('Configured database/bucket differs from the migration')
    store = InfluxStore(config)
    zone = ZoneInfo(manifest['timezone'])
    sql_env = dict(os.environ, MYSQL_PWD=config['DB_PASS'])
    sql_args = ['mysql', '--connect-timeout=10', '--batch', '--raw', '--quick', '--skip-column-names',
                '-h', config.get('DB_HOST') or '127.0.0.1', '-P', config.get('DB_PORT') or '3306',
                '-u', config['DB_USER'], config['DB_NAME']]

    def ident(value):
        if not re.fullmatch(r'[A-Za-z0-9_]+', value):
            raise ValueError('Invalid identifier')
        return '`' + value + '`'

    def sql(query):
        result = subprocess.run(sql_args + ['-e', query], env=sql_env, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('Source query failed; diagnostic output suppressed')
        return result.stdout

    report = {'started_at': datetime.now(timezone.utc).isoformat(), 'source_db': config['DB_NAME'],
              'bucket': store.bucket, 'host': manifest['host'], 'tables': {}, 'complete': False}

    def save():
        (args.directory / 'report.json').write_text(json.dumps(report, indent=2) + '\n')

    save()
    for table, migrated in manifest['tables'].items():
        name = ident(table)
        cols = [line.split('\t')[0] for line in sql('SHOW COLUMNS FROM ' + name).splitlines()]
        expressions = []
        for col in cols:
            value = f"DATE_FORMAT({ident(col)},'%Y-%m-%d %H:%i:%s.%f')" if col == 'timestamp' else ident(col)
            expressions.extend(["'" + col + "'", value])
        initial = sql(f'SELECT COUNT(*),COALESCE(MAX(id),0) FROM {name}').strip()
        current_count = int(initial.split('\t')[0])
        index_path = args.directory / (table + '.sqlite')
        index = sqlite3.connect(index_path)
        index.execute('PRAGMA journal_mode=OFF')
        index.execute('PRAGMA synchronous=OFF')
        index.execute('PRAGMA cache_size=-64000')
        index.execute('CREATE TABLE expected (id INTEGER PRIMARY KEY, value TEXT NOT NULL)')
        print(f'{table}: reading current MariaDB rows...', flush=True)
        source_count, days, batch = 0, {}, []
        with (args.directory / (table + '.stderr')).open('w') as err:
            process = subprocess.Popen(sql_args + ['-e', f"SELECT JSON_OBJECT({','.join(expressions)}) FROM {name} ORDER BY id"],
                                       env=sql_env, stdout=subprocess.PIPE, stderr=err, text=True)
            for line in process.stdout:
                row = json.loads(line)
                batch.append((row['id'], canonical(row)))
                source_count += 1
                day = datetime.fromisoformat(row['timestamp']).replace(tzinfo=zone, fold=0).astimezone(timezone.utc).date().isoformat()
                days[day] = days.get(day, 0) + 1
                if len(batch) == 10000:
                    index.executemany('INSERT INTO expected VALUES (?,?)', batch)
                    batch = []
                if source_count % 500000 == 0:
                    print(f'  {table}: indexed {source_count}', flush=True)
            if process.wait():
                raise RuntimeError('Current source read failed')
        if batch:
            index.executemany('INSERT INTO expected VALUES (?,?)', batch)
        index.commit()
        if source_count != current_count:
            raise ValueError('Source changed during indexing')
        # Use the union of original and current days: catches stale target rows
        # even if a source day has since been removed completely.
        all_days = set(days) | set(migrated.get('utc_days', {}))
        matched = 0
        for day in sorted(all_days):
            start = datetime.fromisoformat(day).replace(tzinfo=timezone.utc)
            pieces = 24 if max(days.get(day, 0), migrated.get('utc_days', {}).get(day, 0)) > 100000 else 1
            daily = 0
            for piece in range(pieces):
                lower = start + timedelta(seconds=86400 * piece / pieces)
                upper = start + timedelta(seconds=86400 * (piece + 1) / pieces)
                flux = (f'from(bucket: {json.dumps(store.bucket)}) '
                        f'|> range(start: {lower.isoformat().replace("+00:00", "Z")}, stop: {upper.isoformat().replace("+00:00", "Z")}) '
                        f'|> filter(fn: (r) => r._measurement == {json.dumps(table)} and r.host == {json.dumps(manifest["host"])}) '
                        f'|> filter(fn: (r) => r.migration_source == "mariadb" and r.source_db == {json.dumps(config["DB_NAME"])} and r.source_table == {json.dumps(table)}) '
                        '|> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")')
                for record in csv_query(store, flux):
                    original = validate_record(record, zone)
                    # Removing exactly one ID also detects duplicated target IDs.
                    found = index.execute('DELETE FROM expected WHERE id=? RETURNING value', (int(record['legacy_id']),)).fetchone()
                    if found is None:
                        raise ValueError(f'{table}: extra or duplicate ID {record["legacy_id"]}')
                    if original != found[0]:
                        raise ValueError(f'{table}: differing source fields at ID {record["legacy_id"]}')
                    matched += 1
                    daily += 1
            index.commit()
            if daily != days.get(day, 0):
                raise ValueError(f'{table}: daily count mismatch on {day}')
            print(f'  {table}: exact comparison {day}: {daily} rows', flush=True)
        remaining = index.execute('SELECT COUNT(*) FROM expected').fetchone()[0]
        if remaining or matched != source_count:
            raise ValueError(f'{table}: missing {remaining} source rows in target')
        # Global sentinel count catches target records outside expected days.
        count_flux = (f'from(bucket: {json.dumps(store.bucket)}) |> range(start: 0) '
                      f'|> filter(fn: (r) => r._measurement == {json.dumps(table)} and r.host == {json.dumps(manifest["host"])}) '
                      f'|> filter(fn: (r) => r.migration_source == "mariadb" and r.source_db == {json.dumps(config["DB_NAME"])} and r.source_table == {json.dumps(table)} and r._field == "legacy_row") '
                      '|> group() |> count()')
        total_target = sum(int(row['_value']) for row in store.query(count_flux))
        if total_target != matched or sql(f'SELECT COUNT(*),COALESCE(MAX(id),0) FROM {name}').strip() != initial:
            raise ValueError('Target has additional points or source changed during verification')
        index.close()
        index_path.unlink()
        report['tables'][table] = {'mariadb_rows': source_count, 'influxdb_rows': matched,
                                   'missing': 0, 'extra_or_duplicate': 0, 'different': 0, 'status': 'PASS'}
        save()
        print(f'{table}: EXACT MATCH {matched} rows', flush=True)
    report['complete'] = True
    report['total_exact_matches'] = sum(t['mariadb_rows'] for t in report['tables'].values())
    report['completed_at'] = datetime.now(timezone.utc).isoformat()
    save()
    print('PASS: every current source row exactly matched; no missing, extra, duplicate or differing historical rows.', flush=True)


if __name__ == '__main__':
    main()
