#!/usr/bin/env python3
import sys
from pathlib import Path
from subprocess import run

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


def add_sheet(workbook: Workbook, title: str, rows: list[list[str]]) -> None:
    worksheet = workbook.create_sheet(title=title)
    for row in rows:
        worksheet.append(row)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: network_monitor2 --export-excel <output.xlsx>", file=sys.stderr)
        return 1

    if not SETUP_CONF.exists():
        print(f"Error: setup.conf not found in {SCRIPT_DIR}", file=sys.stderr)
        return 1

    output_path = Path(sys.argv[1]).expanduser().resolve()
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

    workbook = Workbook()
    workbook.remove(workbook.active)

    queries = {
        "iperf_results": f"SELECT id, timestamp, bitrate, jitter, lost_percentage, protocol, packet_size, executed_command FROM `{iperf_table}` ORDER BY timestamp ASC;",
        "ping_results": f"SELECT id, timestamp, latency FROM `{ping_table}` ORDER BY timestamp ASC;",
        "interruptions": f"SELECT id, timestamp, interruption_time FROM `{interruptions_table}` ORDER BY timestamp ASC;",
        "commands": f"SELECT id, timestamp, protocol, packet_size, executed_command FROM `{iperf_table}` ORDER BY timestamp ASC;",
    }

    for sheet_name, query in queries.items():
        add_sheet(workbook, sheet_name, run_query(config, query))

    workbook.save(output_path)
    print(f"Exported Excel workbook to {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
