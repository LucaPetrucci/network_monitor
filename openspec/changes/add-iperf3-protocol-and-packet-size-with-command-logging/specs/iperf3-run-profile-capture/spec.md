## ADDED Requirements

### Requirement: Protocol selection for iperf3 runs
The system SHALL allow operators to choose the iperf3 transport protocol as either `udp` or `tcp` from the launcher entrypoint and SHALL propagate the selected mode to the iperf client process.

#### Scenario: UDP mode selected
- **WHEN** the operator starts monitoring with mode set to `udp`
- **THEN** the client command SHALL execute iperf3 with UDP transport enabled

#### Scenario: TCP mode selected
- **WHEN** the operator starts monitoring with mode set to `tcp`
- **THEN** the client command SHALL execute iperf3 without UDP transport flags

### Requirement: Packet size configuration
The system SHALL accept an operator-provided packet size parameter and SHALL pass it to iperf3 using `-l` for both UDP and TCP runs.

#### Scenario: Packet size provided
- **WHEN** the operator provides a packet size value
- **THEN** the executed iperf3 command SHALL include `-l <packet_size>`

#### Scenario: Packet size omitted
- **WHEN** the operator does not provide a packet size value
- **THEN** the executed iperf3 command SHALL run without an explicit `-l` argument

### Requirement: Protocol-aware parsing and persistence
The system SHALL parse iperf3 interval output according to the selected protocol and SHALL persist bitrate samples with consistent metadata.

#### Scenario: UDP interval parsed
- **WHEN** a UDP interval line includes jitter and packet loss values
- **THEN** the stored sample SHALL include bitrate, jitter, and loss percentage from that line

#### Scenario: TCP interval parsed
- **WHEN** a TCP interval line is received
- **THEN** the stored sample SHALL include bitrate and SHALL store jitter and loss as zero values

### Requirement: Executed command and run profile logging
For every inserted iperf sample, the system SHALL persist the exact iperf3 command executed and SHALL persist structured run profile metadata including protocol and packet size.

#### Scenario: Sample insert includes command text
- **WHEN** a bitrate sample is written to the database
- **THEN** the row SHALL include the full command string used to launch iperf3 for that run

#### Scenario: Sample insert includes profile metadata
- **WHEN** a bitrate sample is written to the database
- **THEN** the row SHALL include protocol and packet size values matching the active run configuration
