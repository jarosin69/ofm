# ADR-0021: Read S7-1200 and S7-1500 CPUs by PUT/GET from an export data block

- **Status:** Proposed — to be accepted after the PLC owners' answer (STATUS open question 24)
- **Date:** 2026-11-02
- **Deciders:** Jarek (OFM project, with Claude); the plant's PLC owners
- **Tags:** security, runtime

## Context

OFM reads Siemens CPUs with S7 communication (ISO-on-TCP, port 102;
ADR-0018). On S7-300/400 CPUs this is always available. On S7-1200 (from
firmware 4.0) and S7-1500 CPUs it works only when *Permit access with
PUT/GET communication from remote partner* is ticked (CPU properties →
Protection & Security → Connection mechanisms). That setting:

- applies to the whole CPU; there is no read-only or per-block variant;
- authenticates nothing: any device that can reach port 102 can then read
  **and write** the memory areas M, I, Q and every data block with
  optimised access switched off;
- cannot reach optimised data blocks (TIA Portal's default), so values held
  only there need either a block switched to standard access (which changes
  its layout and reinitialises its values) or a copy elsewhere;
- is part of the hardware configuration, so turning it on is a planned
  download, on most CPUs with a stop (assumption: confirm for the pilot CPU).

The CPU's own OPC UA server is the alternative: per-variable exposure, user
login, encryption. It needs firmware 4.4 or later and a runtime licence on
an S7-1200 (*SIMATIC OPC UA S7-1200 Basic*), a licence sized to the CPU on
an S7-1500, and also a hardware download. OFM's OPC UA client is not ready
for it yet: it logs in anonymously, accepts any server certificate, and its
own client certificate is created inside the container, so it changes when
the container is recreated and the CPU would have to trust it again
(ADR-0017 follow-up, not yet done).

Many plants already have PUT/GET switched on because a third-party HMI,
SCADA driver or data logger needs it; then OFM adds no new opening.

## Decision

1. **Use what is already open.** If the pilot CPU already permits PUT/GET
   (or already serves OPC UA to other clients), OFM uses that and asks for
   no change on the CPU.
2. **Where PUT/GET must be switched on**, OFM asks for it only together with:
   1. **Read-only by design.** OFM's polling component has no write path
      (ADR-0018 decision 8); write-back stays a separate decision (`_cmd`).
   2. **A firewall rule.** Port 102 of that CPU is reachable only from the
      OFM server and the engineering stations (cell firewall, switch access
      list or plant firewall — the plant's choice).
   3. **An export data block.** The PLC owner adds one data block with
      standard (non-optimised) access, filled every scan by a small block of
      MOVE instructions with exactly the values OFM is to read. OFM's model
      addresses only that block (`DB<n>,REAL0` …). Existing optimised blocks
      stay untouched. Adding two blocks is normally loadable in RUN
      (assumption: confirm on the pilot CPU and TIA Portal version).
   4. **A change record** in the plant's PLC change process, signed off by
      the PLC owner.
3. **OPC UA instead**, where the owner requires authentication or prefers
   it: only after OFM's OPC UA client supports signed-and-encrypted sessions
   with a user name and password and keeps a fixed client certificate (a
   build step before C3). The CPU licence is the plant's cost.
4. **S7-300/400 CPUs** are read as they are; the firewall rule of 2.2 is
   recommended but not a condition.

## Alternatives considered

1. **OPC UA on every S7-1200/1500** — the better-secured protocol, but a
   licence per CPU, the same planned download, and client work in OFM first.
   Kept as option 3, and preferred long term.
2. **Switch existing data blocks to standard access** — no new blocks, but
   reinitialises their values and ties OFM's addresses to the internal
   layout of production blocks. Rejected.
3. **A commercial gateway** (KEPServerEX and similar) — still needs PUT/GET
   or OPC UA on the CPU, adds a licence and a Windows host. Rejected
   (ADR-0018 alternative 4).
4. **The PLC publishes by MQTT itself** — authenticated and pushed, but PLC
   code per CPU, certificates on the PLC, and the model partly defined in
   PLC programs. Rejected for v1.

## Consequences

- Positive: the PLC owner sees and controls exactly what OFM reads; OFM's
  addresses are stable when the PLC program changes; one contiguous block is
  read in fewer requests, so less communication load on the CPU.
- Negative / cost: PUT/GET still lets any device that reaches port 102 write
  to the CPU, so the firewall rule carries the security; a new value for OFM
  means a small PLC change by the owner; the export block costs a little
  scan time and memory.
- Follow-up work: a one-page request to the PLC owners (the four conditions
  and the change in TIA Portal); deploy README section 5.5 to describe the
  export block; if option 3 is chosen, OPC UA security in the client
  (STATUS step C1.5).

## Notes / references

- To confirm in the pilot CPU's manual: whether the CPU's access protection
  level restricts PUT/GET once it is permitted (assumption: it does not).
- Related: ADR-0017, ADR-0018, Overview §13, STATUS open question 24.
