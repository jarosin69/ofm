# ADR-0018: Acquire S7 and EtherNet/IP data by model-driven polling

- **Status:** Accepted
- **Date:** 2026-10-28
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** runtime, security

## Context

The first real controllers to connect are a Siemens S7-1200 (CPU 1212C), a
Siemens S7-300-family CPU (IM151-8 PN/DP CPU, ET 200S) and a Rockwell
CompactLogix 1769-L16ER. None of them can be relied on to offer OPC UA: the
S7-300 family and the L16ER have no OPC UA server, and an S7-1200 has one only
from firmware 4.4 with a runtime licence. ADR-0017 established the pattern for
OPC UA (a generic, model-driven acquisition component using a pinned library
directly) and deferred other protocols until a source needed them. Two
protocols now need it:

- **S7 communication** (ISO-on-TCP, port 102), the protocol STEP 7 and HMIs
  use; available on every S7 CPU, on S7-1200/1500 only when "PUT/GET access"
  is permitted. Addresses are absolute (`MD100`, `DB10.DBD4`).
- **EtherNet/IP with CIP**, Rockwell's protocol (port 44818); Logix
  controllers are read by tag name (`Line_Speed`, `Program:Main.Count`).

Neither protocol has subscriptions or device timestamps: the client asks,
the controller answers with current values.

## Decision

1. **One generic polled-acquisition component.** A function node in the
   runtime flow ("S7 and EtherNet/IP acquisition") opens one connection per
   source of protocol `s7` or `ethernetip` in the model, reads all its mapped
   addresses in as few requests as the protocol allows, every
   `pollIntervalMs` (source setting, default 1000, minimum 100), and emits the
   same messages as the OPC UA component, so normalisation, UNS publication
   and historian are unchanged.
2. **Libraries, pinned and built in:** `@st-one-io/nodes7` 1.1.2 (GPL-3.0, the
   library already inside `node-red-contrib-s7`) and `st-ethernet-ip` 2.7.5
   (MIT, a maintained fork of `ethernet-ip`), handed to function nodes through
   `functionGlobalContext` as for node-opcua.
3. **Addresses in the model** use each library's syntax: nodes7 for S7
   (`MR100`, `II64`, `DB10,REAL4`, `I0.0`), the Logix tag name for EtherNet/IP.
   The deploy README gives a TIA Portal → OFM address table. Only atomic
   types are read in this step (BOOL, integers, REAL; S7 also STRING).
4. **Report by exception.** A value is sent when it differs from the last
   one sent, or when the property's `max_publish_interval_ms` has passed
   (ADR-0007), so polling every second does not store unchanged values every
   second.
5. **Gateway time.** Values carry no device timestamp; normalisation stamps
   them with arrival time, `tss: "gateway"` (ADR-0003).
6. **Robust to one wrong address.** After connecting, each address is probed
   once; an address that cannot be read is logged as a warning and left out,
   so it never stops the others. Probing repeats on every reconnection.
7. **Connections.** A failed read or connect marks the source offline on
   `ofm/_system/sources/{source}` with the error, closes the connection and
   retries after 1, 2, 5, then every 10 seconds.
8. **Read-only.** The component never writes to a controller. Write-back is
   a separate, later decision (`ofm/_cmd`).
9. **Model rules** (migration 008): protocol `ethernetip` is allowed; an S7
   source must state `rack` and `slot` (S7-1200/1500: 0/1; S7-300/400: 0/2);
   `pollIntervalMs`, when given, is a number of at least 100.

## Alternatives considered

1. **OPC UA everywhere**, via the S7-1200's own server or a gateway product —
   one protocol in OFM, but impossible on the S7-300 and the L16ER without
   extra hardware or licences. Kept as the preferred option wherever a
   controller offers it.
2. **Palette nodes** (`node-red-contrib-s7`, `node-red-contrib-cip-st-ethernet-ip`)
   — one configuration node per PLC, so every new PLC is a flow edit,
   contradicting ADR-0016/0017. Rejected; they stay available for diagnostics.
3. **Publish every poll** — simpler, but multiplies UNS and historian load by
   the poll rate for values that rarely change. Rejected.
4. **A commercial OPC server/gateway** (e.g. KEPServerEX) in front of all
   PLCs — mature drivers, but a licence, a Windows host and another system to
   operate. Rejected for v1; OFM reads such a gateway like any OPC UA source.

## Consequences

- Positive: three common controller families connect by adding model rows
  only; no PLC program change for CompactLogix; one wrong address cannot stop
  a PLC's data.
- Negative / cost: about 200 more lines of acquisition code to own and test;
  S7 needs PUT/GET enabled and, for data blocks, optimised access switched
  off, both of which weaken the CPU's own protection; neither protocol
  authenticates the client, so network segmentation is the only control
  (Overview §13); a GPL-3.0 library is used directly (already present through
  `node-red-contrib-s7`).
- Follow-up work: Phase 2 step 2.3 — `bad` quality on source loss for polled
  sources too; structures, strings and arrays from Logix when needed; Modbus
  when the first Modbus device needs it (open question 23).

## Notes / references

- Tested 2026-10-28 against stand-in controllers (snap7 server for S7, cpppo
  for EtherNet/IP): reading, report by exception, wrong addresses skipped,
  connection loss and recovery. Real controllers: Jarek's bench tests, step 1.7.
- Related: ADR-0003, ADR-0007, ADR-0016, ADR-0017.
