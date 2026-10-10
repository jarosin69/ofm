# ADR-0007: Signal stale data explicitly

- **Status:** Accepted
- **Date:** 2026-10-09
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** uns, historian, data-quality

## Context

Values are published on change beyond the deadband, and retained
(Architecture Overview §6.2). So when a PLC connection drops or the runtime
stops, the last value of every affected property stays on the broker with
`q: "good"` indefinitely. A dead sensor looks exactly like a stable one.
The historian has the same gap: a stable process and a dead connection both
produce no rows.

Sparkplug B solves this with birth and death certificates. v1 deliberately
chose plain JSON instead (Overview §6.4), so it needs an equivalent mechanism
of its own.

## Decision

1. **Source status topics.** Each acquisition source (PLC connection) has a
   retained topic `ofm/_system/sources/{source_name}` with payload
   `{"state": "online"|"offline", "ts": <epoch ms>}`, updated on every
   connection change.
2. **Bad quality on loss.** When a source goes offline, the runtime
   republishes every property mapped to it with:
   - its last value;
   - `q: "bad"`;
   - `ts` = the moment the loss was detected, with `tss: "gateway"`.

   The same rows go to the historian, so the gap is visible in trends.
   Affected machines get an `unknown` state event (ADR-0006).
3. **Runtime Last Will.** Node-RED's MQTT connection registers a Last Will
   and Testament (LWT): a message the broker publishes on the runtime's behalf
   if it disconnects without saying goodbye. The LWT sets
   `ofm/_system/runtime/{runtime_name}` to `offline` (retained); on connect,
   the runtime publishes `online`. Consumers treat all data from an offline
   runtime as stale.
4. **Maximum publish interval (heartbeat).** Each property has
   `max_publish_interval_ms` in the model (default 60 000). If nothing has
   been published within that interval, the current value is republished to
   the UNS and the historian regardless of deadband. Consumer rule: a value
   older than twice its interval is stale.

## Alternatives considered

1. **Sparkplug B** — provides this natively; still rejected for v1 for the
   reasons in Overview §6.4. This ADR is the deliberate substitute, and the
   two map onto each other if Sparkplug is adopted later.
2. **Consumers infer staleness from `ts` alone** — without a heartbeat, the
   age of a deadbanded value means nothing: an old timestamp fits both a
   stable process and a dead link.
3. **Do nothing** — contradicts the "honest data quality" principle
   (Overview §2).

## Consequences

- Positive: a dead source, a dead runtime and a stable process are all
  distinguishable by any consumer, live and in history.
- Negative / cost: heartbeat traffic of about 5,000 properties ÷ 60 s ≈
  85 msg/s, small against the 2,000 msg/s target; one more model column;
  consumers must check `q`, and value age where it matters.
- Follow-up work: Phase 1 — runtime LWT and source status topics. Phase 2 —
  bad-quality republish on loss, max-interval heartbeat in the generic
  pipeline, a "kill the PLC connection" drill in the test strategy (Overview
  §17). `schemas/` — payloads for `ofm/_system/sources` and
  `ofm/_system/runtime`.

## Notes / references

- The 60 000 ms default is an assumption, to be tuned per property class in
  Phase 2.
- Related: ADR-0003 (gateway timestamps), ADR-0004 (retained-topic cleanup),
  ADR-0006 (`unknown` state).
