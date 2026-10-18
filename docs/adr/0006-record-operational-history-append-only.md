# ADR-0006: Record operational history append-only

- **Status:** Accepted
- **Date:** 2026-10-09
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** historian, database, security

## Context

OEE availability needs state *intervals* (start, end, state, reason). The
obvious design, described in the Architecture Overview §10.1–10.2, stores each
interval as a row with an end time that is `NULL` while the state lasts. On
every transition it UPDATEs the open row to close it and inserts a new one;
the operator's reason code is later UPDATEd onto the row. This conflicts with
existing decisions:

- **Least privilege** (Overview §13, ADR-0002): the runtime role may not
  rewrite history, but closing intervals and coding reasons are rewrites.
- **Store-and-forward** (ADR-0002): after a database outage, queued events can
  arrive out of order, and a late event would close the wrong open row.
- **Integrity:** the design permits two open rows for one machine, so it
  needs a watchdog job to detect and repair them.

## Decision

1. **Transitions, not intervals, are stored.**
   `hist.machine_state_event (machine_id, ts, state_id, source)`, primary key
   `(machine_id, ts)`. One row is inserted per transition. It is complete when
   written and is never updated or deleted. There is no end-time column.
2. **Intervals are derived.** `vw_machine_state_interval` computes each
   interval's end as the next event's `ts` (SQL window function `lead()`).
   The last event per machine is its current state, with an open end. Exactly
   one open interval per machine is guaranteed by the structure, not by a job.
3. **Reasons are annotations.**
   `hist.state_reason (machine_id, event_ts, reason_id, assigned_by, assigned_at)`
   has a foreign key `(machine_id, event_ts)` → `machine_state_event (machine_id, ts)`.
   Rows are insert-only, and the latest `assigned_at` wins. PLC fault codes
   (`assigned_by = 'plc'`), operator selections and supervisor corrections
   are all rows, so every reason change is kept.
4. **`unknown` is a first-class state.** It is added to the vocabulary in
   Overview §10.1. OEE reports `unknown` time explicitly and never counts it
   as running. It is recorded in two situations:
   - *Communication loss while the runtime is running* (ADR-0007): the
     runtime inserts `unknown` at the moment the connection dropped.
   - *Runtime outage*: see point 5.
5. **Startup reconciliation.** The runtime inserts a row into
   `hist.runtime_heartbeat` every 60 s. On start, for each machine whose last
   event is not `unknown`, it does three things:
   1. Inserts `unknown` at the later of the last heartbeat and that machine's
      last event, so `unknown` can never be placed before a state that was
      genuinely observed.
   2. Reads the actual state from the PLC.
   3. Inserts that state at the read time.
6. **Replay safety.** Inserts use `ON CONFLICT (machine_id, ts) DO NOTHING`,
   so replaying the store-and-forward queue twice is harmless. Out-of-order
   arrival is harmless because the view orders by `ts`.
7. **Level.** States are recorded per machine only; line, area and site states
   are derived. A line with its own PLC state signal is modelled as a
   line-level machine.
8. **Health query, not repair job.** A read-only query flags anomalies
   (consecutive identical states, future timestamps, uncoded stops older than
   a threshold) and reports on `ofm/_system/state_health`. It never modifies
   data.

## Alternatives considered

1. **Open-interval rows closed by UPDATE** — the common commercial-MES
   pattern, and sound with a single in-order writer. If adopted, a partial
   unique index `ON (machine_id) WHERE end_ts IS NULL` would let the database
   enforce one open row without a watchdog. Rejected because it needs UPDATE
   rights on history and mishandles out-of-order replay.
2. **Deriving states retrospectively from raw signals** — already rejected in
   Overview §10.1.
3. **Events plus a trigger-maintained interval table** — stores the same truth
   twice. Kept in reserve as a materialised view if derived queries prove slow.

## Consequences

- Positive: the runtime role needs only SELECT and INSERT on `hist`, so the
  "cannot rewrite history" promise holds; every reason change is auditable;
  replay and out-of-order arrival are safe.
- Negative / cost: interval queries need window functions, hidden behind
  views; OEE and Grafana query the view, not raw events.
- Negative / cost: a runtime outage is attributed to `unknown` from the last
  heartbeat, so up to one heartbeat interval of genuinely observed time may be
  counted as `unknown`. A shorter interval reduces this at negligible cost.
- Follow-up work: Phase 3 DDL (`machine_state_event`, `state_reason`,
  `runtime_heartbeat`, `vw_machine_state_interval`; `unknown` in the
  vocabulary); heartbeat writer and startup reconciliation flow; update
  Overview §10.1–10.2, replacing "closes the previous interval" and the
  `downtime` table.

## Notes / references

- State changes are infrequent (thousands of rows per day, not millions), so
  `machine_state_event` is an ordinary table, not a hypertable. This allows
  normal foreign keys and constraints.
- The 60 s heartbeat interval is an assumption, to be confirmed in Phase 3.
- Open question: the rule for deriving line state from machine states
  (constraint machine, worst state, or configured per line).
- Open question: the threshold for "uncoded stop" alerts.
- Related: ADR-0002, ADR-0003, ADR-0007.

## Amendments

- 2026-10-18: The open question on deriving line state is resolved by
  ADR-0008: line state is the state of the designated constraint machine, or
  of a line-level machine where the PLC provides a line state signal.
- 2026-10-18: `state_reason` gains an optional free-text `comment` column
  (ADR-0009). The "uncoded stop" threshold is the minor-stop threshold of
  ADR-0009.
