# Protocol Metadata Persistence Spec

## Goal

Every row written to `iperf_results` must describe the test sample that actually
produced it. The `protocol` column is the source of truth used by Excel export
and Grafana dashboards, so it must be correct for both local client-side samples
and remote/server-side samples.

## Current Bug

`network_monitor2 --server` starts a long-lived iperf server through
`iperf_client.sh --server`. In that path, `iperf_client.sh` initializes
`protocol=udp` and no caller passes a per-test protocol into the server process.

As a result, TCP samples collected on the server side can be inserted as:

```text
protocol=udp
executed_command=... protocol=udp ...
```

Export and Grafana then display the wrong protocol because they read the stored
DB value directly.

## Required Behavior

- Client-side rows must keep using the requested protocol from the command line.
- Server-side rows must infer the protocol from each parsed iperf output sample.
- UDP samples are identified by iperf interval lines that include jitter and
  loss fields.
- TCP samples are identified by throughput interval lines without UDP
  jitter/loss fields.
- `executed_command` metadata must match the same protocol stored in the
  `protocol` column for that row.
- Existing dashboards and Excel export should continue to read `protocol` from
  `iperf_results`; they should not need to guess protocol from text.

## Data Contract

For every inserted iperf row:

```text
iperf_results.protocol in ('udp', 'tcp')
executed_command contains protocol=<same value>
```

If the extended columns do not exist on an older installation, the script may
fall back to the legacy insert path, but new installs and migrated installs must
store protocol metadata.

## Verification Plan

- Run Bash syntax checks on the modified shell scripts.
- Confirm the insert path accepts an explicit per-sample protocol.
- Confirm server-side UDP regex inserts `udp`.
- Confirm server-side generic throughput regex inserts `tcp`.
- Confirm Excel export and Grafana queries still read the `protocol` column.
