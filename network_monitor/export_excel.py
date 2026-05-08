#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path
from subprocess import run
from typing import Optional

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
    config = {}
    with path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            config[key.strip()] = value.strip()
    return config


def escape_sql(value: str) -> str:
    return value.replace("'", "''")


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
    output_path.parent.mkdir(parents=True, exist_ok=True)

    config = load_config(SETUP_CONF)
    required = ["DB_NAME", "DB_USER", "DB_PASS"]
    missing = [key for key in required if not config.get(key)]
    if missing:
        print(f"Error: missing DB settings in setup.conf: {', '.join(missing)}", file=sys.stderr)
        return 1

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

    queries = {
        "iperf_results": f"SELECT id, timestamp, bitrate, jitter, lost_percentage, protocol, packet_size, executed_command FROM `{iperf_table}`{where_clause} ORDER BY timestamp ASC;",
        "ping_results": f"SELECT id, timestamp, latency FROM `{ping_table}`{where_clause} ORDER BY timestamp ASC;",
        "interruptions": f"SELECT id, timestamp, interruption_time FROM `{interruptions_table}`{where_clause} ORDER BY timestamp ASC;",
        "commands": f"SELECT id, timestamp, protocol, packet_size, executed_command FROM `{iperf_table}`{where_clause} ORDER BY timestamp ASC;",
    }

    for sheet_name, query in queries.items():
        add_sheet(workbook, sheet_name, run_query(config, query))

    workbook.save(output_path)
    print(f"Exported Excel workbook to {output_path} ({range_label})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
