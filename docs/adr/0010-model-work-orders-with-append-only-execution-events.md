# ADR-0010: Model work orders with append-only execution events

- **Status:** Accepted
- **Date:** 2026-10-18
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** database, oee, uns

## Context

KPIs need to know what is being made: the active product sets the rated speed
(and so every performance figure, ADR-0008), counts must be attributed to an
order, and starting a new product marks the start of a changeover (Pos 6).
Plant practice is for operators to "start the new SKU as soon as the
changeover starts", so the start of an order is an operator action with a
timestamp. Orders may later come from ERP/SAP, but v1 needs manual entry.

Rated speeds also change over time. Because KPIs are calculated at read time
(ADR-0008), editing a rate in place would silently rewrite every historical
performance figure.

## Decision

1. **Products and rated speeds.** `config.product` (SKU, description) and
   `config.product_line_rate (line_id, product_id, rate_per_hour, valid_from)`.
   The rate is the demonstrated maximum, entered in units per hour because
   that is how the floor thinks; ICT = 3600 ÷ rate. Rows are never updated: a
   new rate is a new row with a later `valid_from`, so history keeps the rate
   that applied at the time.
2. **Work orders.** `config.work_order (id, wo_number, line_id, product_id,
   planned_qty, planned_start)` is ordinary master data, editable until the
   order is first started. After that, a trigger locks `line_id` and
   `product_id`. Orders can be planned ahead or created on the spot from the
   operator screen (SKU plus quantity).
3. **Execution is append-only.** `hist.work_order_event (work_order_id, ts,
   event_type, entered_by)` has event types `start`, `changeover_end` and
   `complete`.
   - Starting an order on a line automatically completes the previous one,
     at the same timestamp.
   - The active order per line is derived from these events, never stored.
4. **Changeover window.** It opens at the order's `start` event. It closes at
   `changeover_end` (an operator button or a PLC signal), or, if none is
   recorded, at the first good count of the new order.
5. **Attribution.** Counts and time are attributed to the order active at
   their timestamp, and judged against the rate valid at that timestamp.
6. **Entry.** Work orders are started, completed and created on the operator
   whiteboard (Node-RED Dashboard 2.0, Architecture Overview §10.4). ERP/SAP
   import is a later integration that fills `config.work_order`; nothing else
   changes when it arrives.
7. **UNS.** The active order is published retained on
   `{enterprise}/{site}/{area}/{line}/workorder`, and live line KPIs on
   `{enterprise}/{site}/{area}/{line}/kpi/{name}`. Consequently `workorder`
   and `kpi` are reserved and cannot be used as machine names.

## Alternatives considered

1. **Work order row with a mutable status column** — the usual MES pattern,
   but it requires UPDATEs on execution history and contradicts ADR-0006.
   Rejected.
2. **SKU selection without work orders** (as in some whiteboard tools) —
   simpler, but loses planned quantity and the future ERP link. Rejected; an
   ad hoc order created from a SKU gives the same speed of entry.
3. **ERP/SAP integration first** — the correct long-term source, but too
   much for v1, and the interface is undecided. Deferred.
4. **Changeover end detected automatically only** — appealing, but "steady
   state" is hard to define reliably. The explicit event with a first-good-
   count fallback is used instead.

## Consequences

- Positive: performance is always judged against the right rate for the
  right product at the right time; changeovers are measured, not estimated;
  the execution history is auditable.
- Negative / cost: operators must start orders promptly, or the changeover
  and attribution are wrong. The whiteboard should keep reminding them, as
  the current plant tool does. Rated speeds must be maintained per product
  and line before any performance KPI is meaningful.
- Follow-up work: the tables and lock trigger (Phase 3a); the whiteboard
  order controls; reserved machine names `workorder` and `kpi` added to the
  naming CHECK constraint (Phase 1 DDL); `workorder` payload in `schemas/`.

## Notes / references

- How ramp-up after a changeover is treated is an open question: the
  `changeover_end` event can be placed after ramp-up, or ramp-up can count as
  speed loss.
- Related: ADR-0006, ADR-0008, ADR-0009.
