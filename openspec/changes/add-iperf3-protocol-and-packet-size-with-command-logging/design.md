## Context

The current launcher/client flow always executes `iperf3` in UDP mode and parses mixed output patterns in a single loop. This creates two issues: TCP tests are not supported from the tool CLI, and UDP lines can be matched by a generic parser branch before jitter/loss extraction. The database currently stores throughput-oriented values but not run metadata needed to reconstruct test conditions.

Constraints:
- Preserve current default behavior for existing users.
- Keep shell scripts portable and dependency-free beyond current stack.
- Keep setup idempotent on fresh installs and upgrades.

## Goals / Non-Goals

**Goals:**
- Add protocol selection (`udp|tcp`) end-to-end from launcher to client.
- Add configurable packet size (`-l`) end-to-end.
- Ensure parser reliability by handling TCP and UDP formats explicitly.
- Persist executed command and run profile metadata (`protocol`, `packet_size`) with each inserted sample.
- Maintain backward compatibility with current command usage by defaulting to UDP.

**Non-Goals:**
- Replacing shell-based parsing with JSON mode in this change.
- Redesigning Grafana dashboards for protocol-specific panels.
- Modifying server-side `iperf3` behavior beyond existing bind options.

## Decisions

1. Add `-m <mode>` and `-l <packet_size>` options in `server_launcher.sh`, and forward them to `iperf_client.sh`.
- Rationale: Keeps user entrypoint stable and explicit.
- Alternative considered: configure only in `iperf_client.sh`; rejected because launcher is the public interface.

2. Build client command from explicit parameters, then store an `executed_command` string used for launch and persistence.
- Rationale: Single source of truth for reproducibility.
- Alternative considered: reconstruct command string at insert time; rejected to avoid drift.

3. Split parsing into protocol-aware branches and evaluate UDP-specific pattern before generic throughput fallback.
- Rationale: prevents UDP samples from being downgraded to throughput-only inserts.
- Alternative considered: keep current ordering with regex tweaks; rejected as fragile.

4. Extend `iperf_results` with `executed_command` (TEXT), `protocol` (VARCHAR), and `packet_size` (INT).
- Rationale: command text gives full traceability; structured fields allow straightforward filtering.
- Alternative considered: only store command text; rejected because structured queries become expensive/fragile.

5. Handle schema updates in both creation and migration paths in `setup.sh`.
- Rationale: existing deployments must be upgradable without manual SQL steps.
- Alternative considered: document manual ALTER operations; rejected due to operational risk.

## Risks / Trade-offs

- [Regex parsing differences across iperf3 versions] -> Mitigation: match stable interval-line patterns and ignore summary lines.
- [Invalid packet sizes or protocol typos] -> Mitigation: input validation with clear error/help output.
- [`-b` used in TCP mode causing ambiguity] -> Mitigation: explicit rule to ignore with warning (or fail fast if stricter behavior is preferred).
- [DB migration failures on restricted MySQL versions] -> Mitigation: use defensive `ALTER TABLE` checks and continue idempotently.

## Migration Plan

1. Update DB table definition in install path.
2. Add safe alter logic for existing `iperf_results` table columns.
3. Deploy updated scripts under `/opt/network_monitor`.
4. Validate with two smoke tests:
- UDP run with packet size and bandwidth.
- TCP run with packet size and without `-u`/`-b` behavior.
5. Rollback: restore previous scripts and ignore new nullable columns (data remains readable).

## Open Questions

- Should TCP mode with `-b` be hard-error instead of warning+ignore?
- Do we want to surface `protocol`/`packet_size` immediately in Grafana queries in this change, or defer?
