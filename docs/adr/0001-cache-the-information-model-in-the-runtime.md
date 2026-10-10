# ADR-0001: Cache the information model in the Node-RED runtime

- **Status:** Accepted
- **Date:** 2026-07-12
- **Deciders:** OFM project (design review, Claude/ChatGPT architecture discussions)
- **Tags:** runtime, database, performance

## Context

OFM is model-driven: every incoming PLC value must be resolved against the
Industrial Information Model in PostgreSQL (machine, property, unit, deadband,
limits, MQTT topic) before it can be normalised and published to the UNS.

The original design queried PostgreSQL on every value change. At a few hundred
tags polling at 0.5–2 s, that is hundreds of multi-join SELECTs per second
against data that changes perhaps a few times per month. It couples the
real-time data path to database availability, adds per-message latency, and
puts a hard ceiling on tag count. Configuration data and telemetry have
completely different change rates and must not share a hot path.

## Decision

1. The full resolved model is exposed by a single PostgreSQL view,
   `vw_RuntimeModel`, which pre-joins
   Enterprise→Site→Area→Line→Machine→MachineProperty→PLCMapping and includes
   the pre-computed MQTT topic string for each property.
2. On startup, Node-RED executes `SELECT * FROM vw_RuntimeModel` once and
   builds **three in-memory indexes** in global context:
   - `global.assetModel` — keyed by PLC address (ingest path),
   - `global.machineModel` — keyed by MachineID (state/OEE logic),
   - `global.topicModel` — keyed by MQTT topic (command/write-back path).
   All three are built from the same result set; every lookup is O(1).
3. The runtime path is: PLC value → cache lookup → normalise → publish.
   **The runtime path never issues SQL for model resolution.**
4. Cache refresh uses PostgreSQL `LISTEN/NOTIFY`. Triggers on all
   configuration tables fire `pg_notify('model_changed', <entity hint>)`;
   a listener flow in Node-RED reloads the view and atomically swaps the
   three indexes. Target staleness after a config edit: under 1 second.
5. If a PLC address is not found in the cache, the value is published to a
   quarantine topic (`ofm/_unmapped/<plc>/<address>`) and counted, never
   silently dropped — unmapped tags are a configuration signal.

## Alternatives considered

1. **Query per message (original design)** — simplest to build, but couples
   production data flow to DB availability and fails at scale; rejected.
2. **Redis as a cache layer** — adds a second stateful service to operate for
   data that fits comfortably in Node-RED process memory (thousands of tags
   is a few MB); rejected as unnecessary complexity at this scale. Revisit
   only if multiple Node-RED instances must share one cache.
3. **Polling the config tables for changes** (e.g. re-read every 60 s) —
   simpler than LISTEN/NOTIFY but gives a staleness window and constant
   background load; rejected because NOTIFY is native, free, and immediate.
4. **Restart Node-RED on config change** — operationally unacceptable;
   engineering edits must never stop production data flow.

## Consequences

- Positive: model resolution latency drops to microseconds; PostgreSQL can be
  restarted or backed up without interrupting live data to the UNS; tag count
  scales to thousands without DB load; the database is edited freely during
  production.
- Negative / cost: a window exists (until NOTIFY is processed) where the
  runtime uses a slightly stale model — acceptable for metadata like
  deadbands; Node-RED memory footprint grows with model size; the atomic
  swap must be implemented correctly to avoid a half-updated cache.
- Follow-up work: implement NOTIFY triggers as part of the Phase 1 DDL;
  expose a `ofm/_system/cache` status topic (last reload time, row count,
  unmapped-tag count) for observability; document the quarantine topic.

## Notes / references

- Related: ADR-0002 (historian write path) relies on the same cached
  PropertyID for its inserts.
- PostgreSQL NOTIFY payload limit is 8000 bytes — send an entity hint, not
  the changed row; the reload always re-reads the full view.

## Amendments

- 2026-10-09: **Cache key.** `global.assetModel` is keyed by the pair
  (source, address), e.g. `plc1|DB20.Press`, not by address alone. Two PLCs
  can expose the same address, and an address-only key would silently send
  one PLC's value to the other's property. `plc_mapping` carries a matching
  unique constraint on `(source_id, address)`.
- 2026-10-09: **Quarantine topic encoding.** In `ofm/_unmapped/<source>/<address>`,
  the characters `/`, `+` and `#` in the address are replaced by `_` (OPC UA
  NodeIds may contain them, and they would break the topic). The original,
  unaltered address is carried in the payload as `addr`.
- 2026-10-09: **Phasing.** The startup load of the cache is part of Phase 1,
  so the runtime path never issues SQL even in Phase 1. Reload via
  LISTEN/NOTIFY follows in Phase 2; until then a model change is picked up by
  redeploying the flow.
- 2026-10-09: **Naming.** Per ADR-0005, `vw_RuntimeModel`, `MachineProperty`,
  `PLCMapping` and `MachineID` read as `vw_runtime_model`, `machine_property`,
  `plc_mapping` and `machine_id`. Per ADR-0004, each cache reload also clears
  retained topics that no longer exist in the model.
