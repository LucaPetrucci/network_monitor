## Why

The monitoring tools currently run `iperf3` only in UDP mode and store limited metadata, which prevents consistent TCP testing and makes historical results hard to interpret. Adding protocol selection, packet-size control, and executed-command logging is needed now to make measurements reproducible and comparable.

## What Changes

- Add runtime protocol selection for `iperf3` client execution (`udp` or `tcp`) from launcher to client.
- Add runtime packet-size option and pass it to `iperf3` via `-l`.
- Refactor `iperf3` output parsing to handle UDP and TCP output patterns explicitly and reliably.
- Persist the exact `iperf3` command executed for each sample.
- Extend result persistence to include protocol and packet size metadata for easier filtering and analysis.
- Update documentation and CLI help to reflect new options and behavior.

## Capabilities

### New Capabilities
- `iperf3-run-profile-capture`: Configure transport mode and packet size for `iperf3` runs while storing command and run profile metadata with each saved measurement.

### Modified Capabilities
- None.

## Impact

- Affected scripts: `network_monitor/server_launcher.sh`, `network_monitor/iperf_client.sh`.
- Affected install/database setup: `setup.sh` (schema migration/update path).
- Affected docs: `README.md`.
- Affected database table: `iperf_results` (new metadata columns and insert statements).
