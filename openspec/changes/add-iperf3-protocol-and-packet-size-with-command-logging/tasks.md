## 1. CLI and command construction

- [x] 1.1 Add `-m <mode>` and `-l <packet_size>` options to `network_monitor/server_launcher.sh` help text, argument parsing, validation, and defaults.
- [x] 1.2 Forward protocol and packet size options from `server_launcher.sh` to `iperf_client.sh` when launching the client process.
- [x] 1.3 Update `network_monitor/iperf_client.sh` option parsing to accept protocol and packet size, and build a single `iperf3` command from those inputs.
- [x] 1.4 Implement protocol rules in command build logic: UDP enables `-u` (and optional `-b`), TCP excludes UDP flags, and both modes support optional `-l`.

## 2. Parsing and persistence behavior

- [x] 2.1 Refactor `iperf_client.sh` parsing loop to use protocol-aware matching that reliably captures UDP jitter/loss and TCP throughput.
- [x] 2.2 Ensure insert payloads are normalized: TCP inserts jitter/loss as zero; UDP inserts parsed jitter/loss when present.
- [x] 2.3 Persist run metadata on each insert by adding `executed_command`, `protocol`, and `packet_size` to INSERT statements.

## 3. Database schema migration

- [x] 3.1 Extend `setup.sh` table creation SQL for `iperf_results` with `executed_command`, `protocol`, and `packet_size` columns.
- [x] 3.2 Add idempotent migration SQL in `setup.sh` to add missing metadata columns for existing installations.

## 4. Documentation and validation

- [x] 4.1 Update `README.md` command options and examples to include protocol and packet size usage and mode-specific behavior.
- [x] 4.2 Add verification notes (or troubleshooting guidance) for UDP and TCP test runs, including command logging checks in MySQL.
- [x] 4.3 Run smoke checks to confirm command propagation, parsing correctness, and DB inserts for both UDP and TCP paths.
