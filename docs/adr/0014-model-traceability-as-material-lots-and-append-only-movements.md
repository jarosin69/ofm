# ADR-0014: Model traceability as material lots and append-only movements

- **Status:** Accepted
- **Date:** 2026-10-25
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** database, historian, quality

## Context

A food manufacturer must be able to trace a finished lot back to the raw
material lots in it, and a raw material lot forward to every finished lot it
reached, quickly and with evidence: recall obligations and certification
schemes (BRCGS, SQF, FSSC 22000) require regular traceability exercises,
usually with a mass balance. OFM's scope listed batch genealogy as out of
scope for v1; this ADR brings traceability and inventory into the design as
Phase 3e, to be built after SPC and food safety checks.

Most of the foundations exist: immutable IDs (ADR-0004), append-only history
(ADR-0006), work orders as production steps (ADR-0010), and tank levels as
ordinary properties. Two things do not:

- ADR-0010 plans a `product` table for finished SKUs only. Traceability needs
  every kind of material — raw materials, ingredients, packaging,
  semi-finished products (a type of chocolate, a jelly mass) and finished
  goods — in one structure.
- Confectionery is largely continuous: a tank is topped up while it empties,
  so lots mix, and genealogy cannot rely on discrete batches alone.

## Decision

1. **One material master, from Phase 3a.** `config.material (id, code, name,
   material_type, base_unit_id, ...)` with `material_type` in `raw`,
   `ingredient`, `packaging`, `semi_finished`, `finished`. What ADR-0010 calls
   a product is a material of type `finished` or `semi_finished`; rated speeds,
   work orders and SPC specifications reference `material`. Building it this
   way in Phase 3a costs nothing now and avoids restructuring those tables
   later (ADR-0010 and ADR-0011 carry amendments).
2. **Lots are rows.** `hist.material_lot (id, material_id, lot_code,
   origin, work_order_id, supplier_lot, created_at, ...)`: one row per lot,
   created when material is received or produced. A lot's identity never
   changes; external codes (supplier lot, ERP batch) are attributes, not keys.
3. **Movements are append-only events.** `hist.material_movement (id, ts,
   movement_type, lot_id, quantity, unit_id, from_location_id, to_location_id,
   work_order_id, source, entered_by)` with types `receive`, `transfer`,
   `consume`, `produce`, `adjust`, `dispose`. A correction is a new movement
   that reverses the wrong one (ADR-0006 pattern). Sources are PLC totals
   (flow meters, weigh scales), operator scans and entries, and later ERP.
4. **Inventory and genealogy are derived.** Quantity on hand per lot and
   location, and the lot-to-lot genealogy graph, are views over movements —
   never stored totals. Recall queries ("which finished lots contain lot X?",
   "what went into lot Y?") and mass balance are views as well.
5. **Storage is part of the physical model.** Tanks, silos, hoppers and
   warehouse locations are equipment with a class (`process` or `storage`),
   so their level properties keep flowing through the normal pipeline and
   serve as an independent check on the movement-based contents.
6. **Mixing is handled with time windows.** Where lots mix in a vessel, a lot
   is attributed to everything drawn from that vessel during the window in
   which it may have been present. The default rule is deliberately
   conservative: when in doubt, a lot is included in the recall scope. The
   exact attribution rules are decided in a dedicated ADR when Phase 3e is
   designed in detail.
7. **Identification.** Lots are identified on the floor by scanning or
   entering their codes on Node-RED Dashboard screens; label printing and
   ERP goods-movement interfaces are later integrations.

## Alternatives considered

1. **Keep `product` and add `material` later** — saves nothing now and forces
   a restructuring of work orders, rated speeds and SPC specifications later.
   Rejected.
2. **Store current stock as editable quantities** — simple, but every change
   overwrites history and stock can no longer be explained. Rejected in favour
   of movements, as states were in ADR-0006.
3. **Batch-only genealogy** — exact for batch processes, wrong for the
   continuous mixing typical of chocolate and jelly. Rejected as the only
   mechanism; batches are the special case of a window.
4. **Leave traceability to ERP** — ERP sees receipts and finished goods but
   not what happened between them on the floor (which tank, which window).
   Rejected; OFM records the floor, ERP integration comes later.

## Consequences

- Positive: recall scope and mass balance come from recorded events, with
  evidence; inventory can always be explained movement by movement; tank
  levels become a cross-check rather than the only record.
- Negative / cost: traceability is only as good as the discipline of
  recording movements, especially manual tipping of bags and totes; the
  mixing rules need careful design and validation with the quality team.
- Follow-up work: Phase 3a builds `config.material` instead of `product`;
  Phase 3e builds lots, movements, storage classes, scanning screens, recall
  and mass-balance views, and the mixing-rules ADR.

## Notes / references

- Related: ADR-0004, ADR-0006, ADR-0010, ADR-0011, ADR-0015 (food safety
  checks link to lots and work orders).
