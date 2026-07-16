# ADR-0003: Timestamp policy — source time preferred, epoch milliseconds, UTC

- **Status:** Accepted
- **Date:** 2026-07-12
- **Deciders:** OFM project (design review)
- **Tags:** uns, historian, data-quality

## Context

Every value in OFM carries a timestamp, and that timestamp drives everything
downstream: historian ordering, OEE interval maths, downtime durations, and
cross-machine correlation. Two failure modes must be designed out:

1. **Arrival-time stamping.** Stamping in Node-RED with `Date.now()` records
   when the message *arrived*, not when the value *changed*. Polling jitter,
   broker buffering and store-and-forward replay all silently distort the
   record — replayed data after an outage would appear to have happened at
   replay time.
2. **Timezone ambiguity.** The plant is in Melbourne (UTC+10/+11 with DST).
   ISO strings without explicit handling, or local-time storage, guarantee a
   duplicated/missing hour every DST transition and subtle joins-across-
   systems bugs.

OPC UA delivers a `SourceTimestamp` with every value change; other sources
(Modbus polling, bare MQTT) may not provide any device time.

## Decision

1. **Precedence:** use the source timestamp when the protocol provides one
   (OPC UA `SourceTimestamp`; publisher timestamp for MQTT sources that
   include it). Fall back to Node-RED arrival time only when no source time
   exists.
2. **Provenance is recorded.** Every payload and every historian row carries
   `ts_source` ∈ {`device`, `gateway`}. A value stamped at the gateway is
   honest about it; analytics can filter or weight accordingly.
3. **Format:** epoch **milliseconds** (integer), always UTC, in payloads and
   in the historian (`timestamptz` column, inserted as UTC). No ISO strings
   in the data path; local time (Australia/Melbourne) is a **display-layer
   concern** (Grafana, reports) only.
4. **Sanity guard:** the ingest flow rejects/flags timestamps more than a
   configurable skew (default 5 minutes) ahead of gateway time, and flags
   device timestamps that go backwards for the same property — both indicate
   an unsynchronised PLC clock. Flagged values are stored with
   `quality = 'uncertain'` rather than dropped.
5. **Operational prerequisite:** PLCs, the Node-RED host and the database
   host are NTP-synchronised; PLC clock sync is part of the commissioning
   checklist for every new device.

## Alternatives considered

1. **Always stamp at the gateway** — uniform and simple, but destroys
   accuracy for buffered/replayed data and adds polling jitter to every
   sample; rejected.
2. **Always require device time** — many Modbus devices have no usable
   clock; rejected as impossible in practice, hence the fallback + tagging.
3. **ISO 8601 strings in payloads** — human-readable but heavier to parse,
   and invites naive-local-time bugs; rejected for the data path (fine in
   logs and UIs).
4. **Store local time in the historian** — rejected outright; DST makes
   interval arithmetic wrong twice a year.

## Consequences

- Positive: historian intervals and OEE maths are correct across DST and
  across outage replays; clock problems become visible data-quality flags
  instead of silent corruption; payload parsing is cheap and unambiguous.
- Negative / cost: dashboards and reports must convert to local time
  explicitly (one-time Grafana configuration); the skew guard needs a
  sensible default and an alarm route; commissioning gains an NTP step.
- Follow-up work: add `ts_source` and `quality` to the payload JSON Schema
  and the `Measurement` DDL; write the skew-check into the ingest subflow;
  add "PLC clock sync verified" to the device onboarding checklist.

## Notes / references

- Related: ADR-0002 (store-and-forward replay is precisely the case where
  source timestamps matter most).
- OPC UA also provides `ServerTimestamp`; OFM deliberately uses
  `SourceTimestamp` as it is closest to the physical event.
