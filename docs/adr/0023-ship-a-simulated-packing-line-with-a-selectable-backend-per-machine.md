# ADR-0023: Ship a simulated packing line with a selectable backend per machine

- **Status:** Accepted
- **Date:** 2026-11-02
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** ops, runtime

## Context

Before a plant pilot, management must see what OFM gives the business:
machine states, OEE and downtime on a recognisable line, live. Phase 3a and
3b features (states, counts, work orders, reasons, time ledger, OEE) need a
line that runs, stops and breaks down in a controlled, repeatable way — and
whose true OEE is known, so OFM's figures can be checked. The OPC PLC
simulator (ADR-0017) produces signals, not a line.

The demo is to ship with OFM, so that anyone can start it at once and adapt
it to their own line. Testers may or may not have PLCs. Jarek's bench has
the three controller families of the real packing line: S7-300, S7-1200 and
CompactLogix (step 1.7).

## Decision

1. **A separate simulator, `linesim`.** A second Node-RED container (OFM's
   own image, so nothing new to download), Compose profile `demo`, its own
   flows in `demo/packing-line/`. It plays the plant. It is never part of
   OFM's runtime flows, and OFM sees it only as PLCs.
2. **The line.** A packing line of six machines in a row with conveyors
   (buffers) between them: carton erector → filler (the constraint) →
   checkweigher with reject → carton closer → case packer (10 cartons per
   case) → palletiser. Speeds, buffers, failure and quality behaviour,
   products and shift pattern are settings (`demo/packing-line/line.json`
   and the simulator's control panel), with presets such as *good day*,
   *typical*, *bad day*.
3. **One machine interface** for every machine and every backend: state
   code, fault code, three counters (in, good, reject), speed, speed
   setpoint, heartbeat and one process value (for example the last weight).
4. **A backend per machine, chosen in the control panel:**
   - *Simulated OPC UA* — one OPC UA server per machine, so each machine
     looks like its own PLC; values carry device timestamps.
   - *S7-300* or *S7-1200* — the simulator writes the interface into a data
     block with standard access in a real CPU (one block per machine).
   - *CompactLogix* — the simulator writes controller-scope tags.

   OFM reads a PLC backend exactly as it would read a real machine
   (ADR-0018). Several machines may share one PLC. The PLC holds the
   interface only; it runs no machine logic.
5. **Switching a backend changes model rows only.** The panel calls one
   database function, `demo.set_machine_backend(slot, backend)`, which
   rewrites that machine's `plc_mapping` rows (source and address) in one
   transaction, attributed to the role `ofm_demo` in the audit log; OFM
   follows within a second (step 2.1). The same change can be made by hand
   in Mathesar.
6. **Work orders belong to OFM.** Orders are started and completed in OFM
   (ADR-0010); the simulator follows the retained `.../workorder` topic:
   changeover, then the new product's speed and weight. An optional
   *auto-operator* starts the next order from a production plan in
   `line.json` through `demo.start_order(...)`, so the line can run
   unattended for weeks.
7. **Ground truth stays outside the UNS.** The simulator keeps its own
   ledger of time, counts and causes and serves it, with its own OEE,
   on an HTTP endpoint inside the stack. An opt-in test suite `demo`
   compares OFM's KPIs with it.
8. **Packaging.** Demo files in `demo/packing-line/` (flows, `line.json`,
   PLC data block sources and Logix tag file, guide); the model in
   `db/examples/demo-packline.sql`, loaded with `migrate demo` and removed
   with `migrate demo-remove`; included in the offline bundle. Core OFM
   never depends on anything in the demo.

## Alternatives considered

1. **Simulate inside OFM's runtime flow** — less to run, but mixes the
   plant with the platform and makes the demo look rigged. Rejected.
2. **Factory I/O or another 3D simulator** — impressive, but a paid licence
   per user and Windows only, so it cannot ship with OFM. Rejected.
3. **Machine logic in the PLCs** — the most realistic, but six machines in
   three PLC languages to write and maintain, and testers without PLCs get
   nothing. Rejected; the PLC holds the interface only.
4. **One OPC UA server for all six machines** — simpler, but one machine's
   connection cannot be lost on its own (drill X5). Rejected.
5. **The full PackML state model (ISA-TR88)** — an industry standard, but
   heavier than needed; the interface borrows its idea (state, counters,
   stop reason) and maps onto OFM's state vocabulary.

## Consequences

- Positive: Phase 3a/3b are built and tested against a line with known
  true KPIs; the same demo runs with or without PLCs; switching a machine
  to a real PLC shows model-driven acquisition live; anyone can adapt it.
- Negative / cost: the simulator writes to PLCs (bench only — OFM itself
  stays read-only); `ofm_demo` is a narrowly limited role that changes
  configuration; machine state and fault rules are exercised with simple
  codes, not with real PLC bits; the simulator's settings and OFM's demo
  model must match (a test checks the machine list).
- Follow-up work: the build steps in STATUS (Phase 3a); the demo guide
  `demo/packing-line/README.md`.

## Notes / references

- Related: ADR-0006, ADR-0008, ADR-0009, ADR-0010, ADR-0017, ADR-0018,
  ADR-0024, ADR-0025.

## Amendments

- 2026-11-06: **Work orders as built (decision 6, step 3a.5).** `migrate
  demo` creates the role `ofm_demo` (password `OFM_DEMO_DB_PASSWORD` in
  `.env`) and the schema `demo` with `demo.start_order(sku, qty, by)` and
  `demo.complete_order(by)`, which call OFM's work order functions for the
  demo line only; `demo-remove` drops both. The simulator reads
  `…/workorder` as OFM's read-only MQTT user (`orders.ofmLine` in
  `line.json`), changes over to a new product, stops at the planned
  quantity of good cartons at its output machine and waits without an
  order; a panel switch turns following off. The auto-operator (on by
  default) starts the plan's next order 2 minutes after the line ran out of
  work, inside the shift pattern only. A restarted simulator makes the
  active order's whole quantity again (it cannot know what was made
  before).
