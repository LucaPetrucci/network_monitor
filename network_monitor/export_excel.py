#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path
from subprocess import run
from typing import Optional
from datetime import datetime
import socket

sys.path.insert(0, str(Path(__file__).resolve().parent))
from influx_store import InfluxStore, load_config as load_storage_config

try:
    from openpyxl import Workbook
except ModuleNotFoundError:
    print(
        "Error: openpyxl is not installed. Re-run setup_v2.sh or install requirements.txt.",
        file=sys.stderr,
    )
    sys.exit(1)


SCRIPT_DIR = Path(__file__).resolve().parent
SETUP_CONF = SCRIPT_DIR / "setup.conf"


def load_config(path: Path) -> dict:
    return load_storage_config(path)


def escape_sql(value: str) -> str:
    return value.replace("'", "''")


def build_db_config(config: dict, prefix: str = "") -> dict:
    host_key = f"{prefix}DB_HOST"
    if prefix and not config.get(host_key):
        return {}

    return {
        "DB_HOST": config.get(host_key, config.get("DB_HOST", "")),
        "DB_PORT": config.get(f"{prefix}DB_PORT", config.get("DB_PORT", "")),
        "DB_NAME": config.get(f"{prefix}DB_NAME", config.get("DB_NAME", "")),
        "DB_USER": config.get(f"{prefix}DB_USER", config.get("DB_USER", "")),
        "DB_PASS": config.get(f"{prefix}DB_PASS", config.get("DB_PASS", "")),
    }


def run_query(config: dict, sql: str) -> list[list[str]]:
    cmd = [
        "mysql",
        "-B",
        "-u",
        config["DB_USER"],
        f"-p{config['DB_PASS']}",
    ]
    if config.get("DB_HOST"):
        cmd.extend(["-h", config["DB_HOST"]])
    if config.get("DB_PORT"):
        cmd.extend(["-P", config["DB_PORT"]])
    cmd.append(config["DB_NAME"])
    cmd.extend(["-e", sql])

    completed = run(cmd, check=True, capture_output=True, text=True)
    rows = []
    for line in completed.stdout.splitlines():
        rows.append(line.split("\t"))
    return rows


def build_where_clause(start: Optional[str], end: Optional[str]) -> str:
    clauses = []
    if start:
        clauses.append(f"timestamp >= '{escape_sql(start)}'")
    if end:
        clauses.append(f"timestamp <= '{escape_sql(end)}'")
    if not clauses:
        return ""
    return " WHERE " + " AND ".join(clauses)


def add_sheet(workbook: Workbook, title: str, rows: list[list[str]]) -> None:
    worksheet = workbook.create_sheet(title=title)
    for row in rows:
        worksheet.append(row)


def parse_timestamp(value: str) -> Optional[datetime]:
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None


def add_range_to_output_path(path: Path, start: Optional[str], end: Optional[str]) -> Path:
    """Append a stable start/end suffix when a complete export range is given."""
    if not start or not end:
        return path

    start_dt = parse_timestamp(start)
    end_dt = parse_timestamp(end)
    if start_dt is None or end_dt is None:
        raise ValueError("--start and --end must use YYYY-MM-DD HH:MM:SS[.ffffff]")
    if end_dt < start_dt:
        raise ValueError("--end must not be earlier than --start")

    range_suffix = (
        f"_{start_dt.strftime('%Y%m%d_%H%M%S')}"
        f"_to_{end_dt.strftime('%Y%m%d_%H%M%S')}"
    )
    if path.stem.endswith(range_suffix):
        return path
    return path.with_name(f"{path.stem}{range_suffix}{path.suffix}")


def split_rows_into_runs(rows: list[list[str]], gap_seconds: float = 15.0) -> list[list[list[str]]]:
    runs: list[list[list[str]]] = []
    current_run: list[list[str]] = []
    previous_ts: Optional[datetime] = None

    for row in rows:
        row_ts = parse_timestamp(row[1]) if len(row) > 1 else None
        if (
            previous_ts is not None
            and row_ts is not None
            and (row_ts - previous_ts).total_seconds() > gap_seconds
            and current_run
        ):
            runs.append(current_run)
            current_run = []

        current_run.append(row)
        if row_ts is not None:
            previous_ts = row_ts

    if current_run:
        runs.append(current_run)

    return runs


def merge_iperf_rows(local_rows: list[list[str]], remote_rows: list[list[str]]) -> list[list[str]]:
    merged: list[list[str]] = []
    local_runs = split_rows_into_runs(local_rows)
    remote_runs = split_rows_into_runs(remote_rows)
    max_runs = max(len(local_runs), len(remote_runs))

    for run_index in range(max_runs):
        local_bucket = local_runs[run_index] if run_index < len(local_runs) else []
        remote_bucket = remote_runs[run_index] if run_index < len(remote_runs) else []
        max_len = max(len(local_bucket), len(remote_bucket))

        for index in range(max_len):
            local_row = local_bucket[index] if index < len(local_bucket) else []
            remote_row = remote_bucket[index] if index < len(remote_bucket) else []

            merged.append([
                local_row[0] if len(local_row) > 0 else (remote_row[0] if len(remote_row) > 0 else ""),
                local_row[1] if len(local_row) > 1 else (remote_row[1] if len(remote_row) > 1 else ""),
                local_row[2] if len(local_row) > 2 else "",
                remote_row[2] if len(remote_row) > 2 else "",
                local_row[3] if len(local_row) > 3 else "",
                remote_row[3] if len(remote_row) > 3 else "",
                local_row[4] if len(local_row) > 4 else "",
                remote_row[4] if len(remote_row) > 4 else "",
                local_row[5] if len(local_row) > 5 else (remote_row[5] if len(remote_row) > 5 else ""),
                local_row[6] if len(local_row) > 6 else (remote_row[6] if len(remote_row) > 6 else ""),
                local_row[7] if len(local_row) > 7 else (remote_row[7] if len(remote_row) > 7 else ""),
                local_row[8] if len(local_row) > 8 else (remote_row[8] if len(remote_row) > 8 else ""),
            ])

    return merged


def export_influx(config, output_path, start, end):
    """Keep the established Excel column contract, including optional peer data."""
    store = InfluxStore(config)
    host = config.get('INFLUX_HOST_FILTER') or socket.gethostname()
    columns = ['id', 'timestamp', 'bitrate', 'jitter', 'lost_percentage',
               'protocol', 'packet_size', 'window_size', 'executed_command']

    def rows_for(measurement, names, reader=store, node=host):
        result = []
        maximum = int(config.get('INFLUX_EXPORT_MAX_ROWS', '200000'))
        for index, record in enumerate(reader.records(measurement, start, end, node, max_rows=maximum), 1):
            stamp = datetime.fromisoformat(record['_time'].replace('Z', '+00:00')).astimezone()
            record = dict(record, id=index, timestamp=stamp.strftime('%Y-%m-%d %H:%M:%S.%f'))
            result.append([record.get(name, '') for name in names])
        return result

    iperf = rows_for(config.get('IPERF_TABLE', 'iperf_results'), columns)
    remote = []
    if config.get('REMOTE_INFLUX_URL'):
        remote_config = dict(config)
        for key in ('URL', 'ORG', 'BUCKET', 'TOKEN'):
            remote_config['INFLUX_' + key] = config.get('REMOTE_INFLUX_' + key, config.get('INFLUX_' + key, ''))
        remote = rows_for(config.get('IPERF_TABLE', 'iperf_results'), columns,
                          InfluxStore(remote_config), config.get('REMOTE_INFLUX_HOST', ''))
    elif config.get('REMOTE_DB_HOST'):
        table = config.get('IPERF_TABLE', 'iperf_results')
        sql = f"SELECT {', '.join(columns)} FROM `{table}`{build_where_clause(start, end)} ORDER BY timestamp ASC;"
        remote = run_query(build_db_config(config, 'REMOTE_'), sql)[1:]
    workbook = Workbook()
    workbook.remove(workbook.active)
    merged = merge_iperf_rows(iperf, remote)
    headers = ['id', 'timestamp', 'Data Rate', 'Data Rate Remote', 'Jitter', 'Jitter Remote',
               'Lost Packets', 'Lost Packets Remote', 'protocol', 'packet_size', 'window_size', 'executed_command']
    add_sheet(workbook, 'iperf_results', [headers, *merged])
    for sheet, measurement, names in (
        ('ping_results', config.get('PING_TABLE', 'ping_results'), ['id', 'timestamp', 'latency']),
        ('interruptions', config.get('INTERRUPTIONS_TABLE', 'interruptions'), ['id', 'timestamp', 'interruption_time']),
    ):
        add_sheet(workbook, sheet, [names, *rows_for(measurement, names)])
    names = ['id', 'timestamp', 'protocol', 'packet_size', 'window_size', 'executed_command']
    add_sheet(workbook, 'commands', [names, *[[row[columns.index(name)] for name in names] for row in iperf]])
    workbook.save(output_path)
    print(f'Exported Excel workbook to {output_path} (InfluxDB, host={host})')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="network_monitor2 --export-excel",
        description="Export locally collected data to an Excel workbook.",
    )
    parser.add_argument("output_path", help="Output .xlsx file")
    parser.add_argument(
        "--start",
        dest="start",
        help="Inclusive start timestamp filter, for example '2026-05-07 10:00:00'",
    )
    parser.add_argument(
        "--end",
        dest="end",
        help="Inclusive end timestamp filter, for example '2026-05-07 18:00:00'",
    )
    args = parser.parse_args()

    if not SETUP_CONF.exists():
        print(f"Error: setup.conf not found in {SCRIPT_DIR}", file=sys.stderr)
        return 1

    output_path = Path(args.output_path).expanduser().resolve()
    try:
        output_path = add_range_to_output_path(output_path, args.start, args.end)
    except ValueError as exc:
        parser.error(str(exc))
    output_path.parent.mkdir(parents=True, exist_ok=True)

    config = load_config(SETUP_CONF)
    if config.get('DB_BACKEND', 'mariadb') == 'influxdb':
        try:
            return export_influx(config, output_path, args.start, args.end)
        except (ValueError, OSError, RuntimeError) as exc:
            print(f'Error exporting InfluxDB data: {exc}', file=sys.stderr)
            return 1
    required = ["DB_NAME", "DB_USER", "DB_PASS"]
    missing = [key for key in required if not config.get(key)]
    if missing:
        print(f"Error: missing DB settings in setup.conf: {', '.join(missing)}", file=sys.stderr)
        return 1

    local_db = build_db_config(config)
    remote_db = build_db_config(config, "REMOTE_")
    has_remote_db = bool(remote_db)

    iperf_table = config.get("IPERF_TABLE", "iperf_results")
    ping_table = config.get("PING_TABLE", "ping_results")
    interruptions_table = config.get("INTERRUPTIONS_TABLE", "interruptions")
    where_clause = build_where_clause(args.start, args.end)
    if args.start and args.end:
        range_label = f"{args.start} .. {args.end}"
    elif args.start:
        range_label = f"from {args.start}"
    elif args.end:
        range_label = f"until {args.end}"
    else:
        range_label = "all available rows"

    workbook = Workbook()
    workbook.remove(workbook.active)

    iperf_query = (
        f"SELECT id, timestamp, bitrate, jitter, lost_percentage, protocol, packet_size, window_size, executed_command "
        f"FROM `{iperf_table}`{where_clause} ORDER BY timestamp ASC;"
    )

    queries = {
        "ping_results": f"SELECT id, timestamp, latency FROM `{ping_table}`{where_clause} ORDER BY timestamp ASC;",
        "interruptions": f"SELECT id, timestamp, interruption_time FROM `{interruptions_table}`{where_clause} ORDER BY timestamp ASC;",
        "commands": f"SELECT id, timestamp, protocol, packet_size, window_size, executed_command FROM `{iperf_table}`{where_clause} ORDER BY timestamp ASC;",
    }

    local_iperf_rows = run_query(local_db, iperf_query)
    local_iperf_rows = local_iperf_rows[1:] if local_iperf_rows else []

    if has_remote_db:
        remote_iperf_rows = run_query(remote_db, iperf_query)
        remote_iperf_rows = remote_iperf_rows[1:] if remote_iperf_rows else []
        merged_iperf_rows = merge_iperf_rows(local_iperf_rows, remote_iperf_rows)
    else:
        merged_iperf_rows = [
            [
                row[0] if len(row) > 0 else "",
                row[1] if len(row) > 1 else "",
                row[2] if len(row) > 2 else "",
                "",
                row[3] if len(row) > 3 else "",
                "",
                row[4] if len(row) > 4 else "",
                "",
                row[5] if len(row) > 5 else "",
                row[6] if len(row) > 6 else "",
                row[7] if len(row) > 7 else "",
                row[8] if len(row) > 8 else "",
            ]
            for row in local_iperf_rows
        ]

    iperf_headers = [
        "id",
        "timestamp",
        "Data Rate",
        "Data Rate Remote",
        "Jitter",
        "Jitter Remote",
        "Lost Packets",
        "Lost Packets Remote",
        "protocol",
        "packet_size",
        "window_size",
        "executed_command",
    ]
    add_sheet(workbook, "iperf_results", [iperf_headers, *merged_iperf_rows])

    for sheet_name, query in queries.items():
        add_sheet(workbook, sheet_name, run_query(config, query))

    workbook.save(output_path)
    if has_remote_db:
        print(f"Exported Excel workbook to {output_path} ({range_label}, local+remote iperf merged)")
    else:
        print(f"Exported Excel workbook to {output_path} ({range_label}, local iperf only)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
