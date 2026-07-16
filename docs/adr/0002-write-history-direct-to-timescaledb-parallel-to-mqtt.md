# ADR-0002: Write history directly to TimescaleDB, in parallel with MQTT

- **Status:** Accepted
- **Date:** 2026-07-12
- **Deciders:** OFM project (design review)
- **Tags:** historian, uns, reliability

## Context

The original design routed all historical data through the broker:
Node-RED → Mosquitto → historian-writer service → TimescaleDB. It is an
elegant single path, but it makes the *permanent record* depend entirely on
MQTT delivery. Mosquitto is a lightweight broker, not a durable log: if the
historian writer is down, the broker restarts, or a QoS 0 message is shed,
that data is gone. In a food plant, downtime intervals, production counts and
temperature histories feed OEE and potentially quality/compliance records —
losing them is not acceptable.

The underlying insight: **live state distribution and permanent recording are
different jobs with different guarantees.** MQTT is optimised for the first;
a database transaction is the correct tool for the second.

## Decision

1. Node-RED writes each accepted value to **two independent sinks in
   parallel**:
   - publish to Mosquitto (live state, retained where appropriate), and
   - insert into TimescaleDB `Measurement` (timestamp, PropertyID, value,
     quality, ts_source) via batched inserts.
2. Historian inserts are **batched** (flush every 1–2 s or every N rows,
   whichever first) to keep insert overhead low; they carry the immutable
   `PropertyID` from the cache (ADR-0001), never the topic string.
3. A **local store-and-forward queue** protects the historian path: if the
   TimescaleDB insert fails, batches are appended to a local disk queue
   (file-based) and drained in order when the database returns. Queue depth
   is published to `ofm/_system/historian` for monitoring.
4. The MQTT path makes no durability promise beyond broker QoS. Consumers
   needing guaranteed completeness read the historian, not the broker.
5. Events with MES significance (state changes, counts, downtime records)
   use the same pattern but are written **transactionally per event**, not
   batched — they are low-rate and high-value.

## Alternatives considered

1. **MQTT-only path with hardening** (QoS 1, persistent sessions, Mosquitto
   persistence enabled) — reduces but does not eliminate loss windows
   (broker disk persistence is best-effort, writer downtime still queues in
   broker RAM/disk with limits); acceptable for a lab, not for production
   records; rejected as the primary mechanism.
2. **Kafka/Redpanda buffer between broker and historian** (UMH pattern) —
   genuinely solves durability and replay, but adds a heavyweight stateful
   service to a single-site, small-team deployment; rejected for now.
   Revisit in a new ADR if multi-site aggregation or replay-to-multiple-
   consumers becomes a requirement.
3. **Historian writes from a separate subscriber service** (keep the
   decoupled reader but subscribe QoS 1) — keeps concerns separated but the
   record still depends on broker delivery; rejected for the reason above.

## Consequences

- Positive: the permanent record survives broker restarts, writer crashes
  and network blips; UNS consumers and the historian cannot corrupt or block
  each other; OEE and compliance queries can trust completeness.
- Negative / cost: Node-RED now holds DB credentials and a write
  responsibility (mitigate: dedicated `ofm_writer` role with INSERT-only
  grants); two code paths must stay consistent about payload semantics;
  the local queue needs a disk-full policy (oldest-drop plus alarm).
- Follow-up work: implement the batcher and disk queue as a reusable
  subflow; add a reconciliation query (count per property per hour) to a
  Grafana health dashboard; define retention/compression policies on the
  `Measurement` hypertable.

## Notes / references

- Related: ADR-0001 (PropertyID from cache), ADR-0003 (which timestamp is
  stored).
- Mosquitto docs are explicit that it is not a message queue with durable
  log semantics; this ADR exists so nobody re-litigates that in a year.
