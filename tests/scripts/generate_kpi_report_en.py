#!/usr/bin/env python3
"""Generate an English Markdown report and CSV from a CEIT KPI campaign."""

import csv
import json
import re
import statistics
import sys
from pathlib import Path


if len(sys.argv) != 2:
    raise SystemExit(f"Usage: {sys.argv[0]} RESULTS_DIRECTORY")

root = Path(sys.argv[1])
cases = [
    ("CEIT", "Not identifiable", "CEIT_GATEWAY"),
    ("Bypass", "TN0", "BYPASS_TN0"),
    ("Bypass", "TN1", "BYPASS_TN1"),
]
fields = [
    "Path",
    "Radio",
    "Direction",
    "Test",
    "Average throughput Mbit/s",
    "Min Mbit/s",
    "Max Mbit/s",
    "Latency min ms",
    "Latency average ms",
    "Latency max ms",
    "Jitter ms",
    "Packet loss %",
    "TCP retransmissions",
    "Result",
]


def load_json(path):
    try:
        data = json.loads(path.read_text())
        return None if data.get("error") else data
    except (OSError, ValueError):
        return None


def ping_stats(path):
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return (None, None, None), None
    loss = re.search(r"([\d.]+)% packet loss", text)
    rtt = re.search(r"=\s*([\d.]+)/([\d.]+)/([\d.]+)/", text)
    latency = (
        tuple(float(rtt.group(i)) for i in range(1, 4))
        if rtt
        else (None, None, None)
    )
    return latency, float(loss.group(1)) if loss else None


def reason(case_dir):
    try:
        value = (case_dir / "case_status.txt").read_text().strip()
        return value or "NOT EXECUTABLE"
    except OSError:
        return "NOT EXECUTABLE"


def mbps(data):
    return data["end"]["sum_received"]["bits_per_second"] / 1e6


def retransmissions(data):
    return data.get("end", {}).get("sum_sent", {}).get("retransmits", 0)


def add_row(
    rows,
    path,
    radio,
    direction,
    test,
    throughput="",
    minimum="",
    maximum="",
    latency=(None, None, None),
    jitter="",
    loss="",
    retrans="",
    result="",
):
    values = [
        path,
        radio,
        direction,
        test,
        throughput,
        minimum,
        maximum,
        latency[0] if latency[0] is not None else "",
        latency[1] if latency[1] is not None else "",
        latency[2] if latency[2] is not None else "",
        jitter,
        loss,
        retrans,
        result,
    ]
    rows.append(dict(zip(fields, values)))


rows = []
summary_data = {}
for path_name, radio, directory in cases:
    case_dir = root / directory
    latency, ping_loss = ping_stats(case_dir / "ping.txt")

    for direction, stem in (
        ("NUC2→NUC1", "tcp_forward"),
        ("NUC1→NUC2", "tcp_reverse"),
    ):
        runs = [load_json(case_dir / f"{stem}_{i}.json") for i in (1, 2, 3)]
        valid_runs = [run for run in runs if run]
        values = [mbps(run) for run in valid_runs]
        retrans = [retransmissions(run) for run in valid_runs]
        complete = len(valid_runs) == 3
        result = "VALID" if complete else reason(case_dir)
        add_row(
            rows,
            path_name,
            radio,
            direction,
            "TCP 1 stream",
            round(statistics.mean(values), 2) if values else "",
            round(min(values), 2) if values else "",
            round(max(values), 2) if values else "",
            latency,
            loss=ping_loss if ping_loss is not None else "",
            retrans=sum(retrans) if retrans else "",
            result=result,
        )
        summary_data[(path_name, radio, direction, "tcp")] = (
            round(statistics.mean(values), 2) if values else None
        )

        parallel = load_json(case_dir / f"{stem}_p4.json")
        add_row(
            rows,
            path_name,
            radio,
            direction,
            "TCP 4 streams",
            round(mbps(parallel), 2) if parallel else "",
            latency=latency,
            loss=ping_loss if ping_loss is not None else "",
            retrans=retransmissions(parallel) if parallel else "",
            result="VALID" if parallel else reason(case_dir),
        )

    for rate in (400, 500, 600):
        data = load_json(case_dir / f"udp_forward_{rate}M.json")
        received = data.get("end", {}).get("sum_received", {}) if data else {}
        udp_loss = received.get("lost_percent")
        if data:
            result = "VALID" if udp_loss is not None and udp_loss <= 1 else "ABNORMAL: LOSS >1%"
        else:
            result = reason(case_dir)
        add_row(
            rows,
            path_name,
            radio,
            "NUC2→NUC1",
            f"UDP {rate}M",
            round(received.get("bits_per_second", 0) / 1e6, 2) if data else "",
            latency=latency,
            jitter=round(received.get("jitter_ms", 0), 3) if data else "",
            loss=round(udp_loss, 4) if udp_loss is not None else (
                ping_loss if ping_loss is not None else ""
            ),
            result=result,
        )
        summary_data[(path_name, radio, rate, "udp")] = (
            round(received.get("bits_per_second", 0) / 1e6, 2) if data else None,
            round(udp_loss, 2) if udp_loss is not None else None,
        )

with (root / "results.csv").open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)


def display(value):
    return "—" if value in ("", None) else str(value)


report = [
    "# Network KPI Report — CEIT and Bypass",
    "",
    "## Methodology",
    "",
    "The CEIT test uses `10.10.42.11 → 10.10.22.10`. The radio selected internally by the gateway cannot be observed or controlled from the NUCs. Bypass TN0 uses VLAN28 and bypass TN1 uses VLAN29 directly.",
    "",
    "## Results",
    "",
    "| Path | Radio | Direction | Test | Average throughput | Min/Max | Latency min/avg/max | Jitter | Loss | Retransmissions | Result |",
    "|---|---|---|---|---:|---:|---:|---:|---:|---:|---|",
]
for row in rows:
    report.append(
        f"| {row['Path']} | {row['Radio']} | {row['Direction']} | {row['Test']} "
        f"| {display(row['Average throughput Mbit/s'])} "
        f"| {display(row['Min Mbit/s'])}/{display(row['Max Mbit/s'])} "
        f"| {display(row['Latency min ms'])}/{display(row['Latency average ms'])}/{display(row['Latency max ms'])} "
        f"| {display(row['Jitter ms'])} | {display(row['Packet loss %'])}% "
        f"| {display(row['TCP retransmissions'])} | {row['Result']} |"
    )

report += [
    "",
    "## Interpretation",
    "",
    "- TCP averages and min/max values are calculated from three 30-second single-stream runs.",
    "- TCP retransmissions for the single-stream rows are the sum of the three runs.",
    "- UDP throughput is the throughput received by NUC1, not only the offered rate.",
    "- A path marked not executable failed the preliminary connectivity check, so throughput tests were safely skipped.",
    "- The CEIT result cannot be attributed to TN0 or TN1 because radio selection is internal to the gateway.",
    "",
    "## Restoration and management",
    "",
    "The initial test-route state was restored at the end of the campaign. VLAN27 and the management default route were not modified.",
    "",
    "## Summary",
    "",
]


def tcp_text(path, radio, direction):
    value = summary_data.get((path, radio, direction, "tcp"))
    return f"{value:.2f} Mbit/s" if value is not None else "not measurable"


def udp_text(path, radio):
    values = []
    for rate in (400, 500, 600):
        throughput, loss = summary_data.get((path, radio, rate, "udp"), (None, None))
        if throughput is not None:
            values.append(f"{rate}M: {throughput:.2f} Mbit/s received, {loss:.2f}% loss")
    return "; ".join(values) if values else "not measurable"


report += [
    f"- CEIT TCP: forward {tcp_text('CEIT', 'Not identifiable', 'NUC2→NUC1')}; reverse {tcp_text('CEIT', 'Not identifiable', 'NUC1→NUC2')}.",
    f"- Bypass TN0 TCP: forward {tcp_text('Bypass', 'TN0', 'NUC2→NUC1')}; reverse {tcp_text('Bypass', 'TN0', 'NUC1→NUC2')}.",
    f"- Bypass TN1 TCP: forward {tcp_text('Bypass', 'TN1', 'NUC2→NUC1')}; reverse {tcp_text('Bypass', 'TN1', 'NUC1→NUC2')}.",
    f"- Bypass TN0 UDP: {udp_text('Bypass', 'TN0')}.",
    "- CEIT radio selection is not identifiable from the NUCs; management VLAN27 remained unchanged.",
    "",
]

(root / "REPORT_EN.md").write_text("\n".join(report))
