# ADR-0017: Acquire OPC UA data with a model-driven client in the runtime

- **Status:** Accepted
- **Date:** 2026-10-25
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** runtime

## Context

OFM's principle is that acquisition is configured by the model, not by
editing flows: a new PLC is a row in `config.source`, a new tag a row in
`config.plc_mapping`. The obvious tool, the `node-red-contrib-opcua` palette
nodes, is built around one fixed connection per configuration node, set up by
hand in the editor; supporting a new source means adding nodes to the flow.
Two further facts were established in step 1.3:

- The library accepts addresses only with a namespace *number*
  (`ns=3;s=SpikeData`), while OFM stores the stable namespace *URI*
  (`nsu=http://…;s=SpikeData`) because servers may renumber namespaces.
- The palette node reports errors without detail, which makes field
  diagnosis hard.

The underlying library, node-opcua (MIT licence), is already in the image as a
dependency of the palette node and offers everything needed directly.

## Decision

1. **One generic acquisition component.** A function node in the runtime flow
   ("OPC UA acquisition") uses node-opcua directly. For every OPC UA source of
   this runtime in the model, it opens one client, reads the server's
   namespace table, translates `nsu=` addresses to `ns=<number>`, creates one
   subscription and one monitored item per mapping, and emits one message per
   value change with value, status, source timestamp and arrival time.
2. **Connection status from the library.** The client's own events
   (connection lost, re-established, retrying) drive the source status topic
   `ofm/_system/sources/{source}` (ADR-0007). Reconnection and re-subscription
   are handled by node-opcua.
3. **The library is pinned and built in.** node-opcua is an explicit, pinned
   dependency of the OFM Node-RED image and is handed to function nodes
   through `functionGlobalContext`; function nodes still cannot install
   packages themselves.
4. **Scope.** OPC UA only. Each further protocol (S7, Modbus, MQTT devices)
   gets its acquisition component when a source needs it, following the same
   pattern: model in, normalised value messages out. The palette nodes remain
   in the image for ad-hoc diagnostics.
5. **Later.** When the design has settled, the component moves into a proper
   custom node package, `node-red-contrib-ofm` (Phase 5).

## Alternatives considered

1. **Palette nodes, one configuration node per source** — no code to own, but
   every new PLC means a flow edit, contradicting the model-driven principle
   and ADR-0016. Rejected.
2. **Palette node with dynamic reconnect messages** — possible, but limited to
   one source per client node and still requires namespace translation and
   status handling around it. Rejected.
3. **A separate acquisition service outside Node-RED** — clean separation, but
   another container and runtime to operate. Rejected for v1; revisit if
   acquisition load outgrows Node-RED.

## Consequences

- Positive: a new OPC UA source or tag is a model change only; namespace
  renumbering is harmless; connection state is precise; errors carry detail.
- Negative / cost: OFM owns about 120 lines of acquisition code, which need
  tests and must follow node-opcua upgrades (pinned, so upgrades are
  deliberate).
- Follow-up work: Phase 2 — model reload replaces connections without restart
  (already supported by the component), `bad` quality on connection loss,
  OPC UA security modes and user login for real PLCs.

## Notes / references

- Verified 2026-10-25 against a stand-in OPC UA server and with Jarek's
  check flow against the OPC PLC simulator: namespace translation, source
  timestamps, connection loss and recovery.
- Related: ADR-0001, ADR-0003, ADR-0007, ADR-0016.
