# ADR-0011: Model SPC as sampled characteristics with frozen control limits

- **Status:** Accepted
- **Date:** 2026-10-21
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** database, historian, quality

## Context

Statistical Process Control (SPC) monitors product characteristics: pack
weight, chocolate temper index, crystallisation temperature, moisture. The
Architecture Overview lists SPC as an analytics function (Layer 7) but never
designed it. SPC data differs from telemetry in three ways:

- **It arrives as samples.** A sample is a *subgroup* of n readings (5 packs
  weighed every 30 minutes) or a single reading (one temper-meter result per
  batch), taken by a person or an instrument, for a known product and work
  order. A stream of property values has none of that context.
- **Two kinds of limits must not be confused.** *Specification limits*
  (LSL, target, USL) say what the customer or the law accepts; they belong to
  the product. *Control limits* (LCL, centre line, UCL) describe what the
  process normally does; they are calculated from the process's own data.
- **Records must be trustworthy.** Sample results are quality records:
  corrections must be visible, not silent overwrites.

## Decision

1. **Characteristics.** `config.quality_characteristic` defines what is
   measured: name, engineering unit, kind (`variable` for measured values,
   `attribute` for pass/fail or defect counts) and source (`manual`,
   `instrument`, or `property` when derived from inline telemetry such as a
   checkweigher).
2. **Specifications per product.** `config.product_spec (product_id,
   characteristic_id, lsl, target, usl, valid_from)` is effective-dated. A
   new specification is a new row, so history keeps the limits that applied
   at the time (the same pattern as rated speeds, ADR-0010).
3. **Sampling plans.** `config.spc_plan` defines, per line and
   characteristic (optionally per product): subgroup size, sampling interval,
   chart type (`xbar_r`, `xbar_s`, `i_mr`, `p`, `np`, `c`, `u`) and the
   out-of-control rules to apply (Western Electric rules 1–4 by default; other
   Nelson rules configurable).
4. **Samples are append-only.** `hist.spc_sample (id, line_id,
   characteristic_id, ts, work_order_id, taken_by, source, voids_sample_id)`
   with `hist.spc_value (sample_id, seq, value)` for variables, or inspected
   and defective counts for attributes. A correction is a new sample that
   names the sample it voids (ADR-0006 pattern); nothing is updated or deleted.
5. **Inline characteristics.** For a characteristic with source `property`, a
   scheduled job forms subgroups from `hist.measurement` according to the plan
   and inserts them as samples, so every chart reads from one table. Such
   properties are published and stored without deadband, because deadbanding
   would discard exactly the variation SPC measures.
6. **Control limits are frozen.** `config.control_limit (plan_id, product_id,
   centre, lcl, ucl, range_centre, range_ucl, baseline_from, baseline_to,
   valid_from, approved_by)` stores limits calculated from a chosen baseline
   period and approved by a person. They are never recalculated automatically.
   New limits are a new row with a later `valid_from`. Until limits exist, a
   chart shows specification limits only and the status "no control limits".
7. **Calculated at read time.** SQL views compute subgroup statistics, chart
   points against the limits valid at each sample, and capability indices
   (Cp and Cpk from within-subgroup variation; Pp and Ppk from overall
   variation).
8. **Violations and overdue samples are recorded and published.** After each
   new sample, a job evaluates the plan's rules and inserts any violation into
   `hist.spc_violation` (idempotent, append-only; acknowledgement is a separate
   annotation row). The current state of each characteristic (in control,
   violation, sample overdue, no control limits) is published retained on
   `{enterprise}/{site}/{area}/{line}/spc/{characteristic}`, which makes `spc`
   a reserved machine name.
9. **Entry and display.** Manual samples are entered on a Node-RED Dashboard
   screen of the same kind as the operator whiteboard (Architecture Overview
   §10.4). Control charts and capability are displayed in Grafana.
10. **Scope.** OFM *supports* SPC. It is not a validated quality system:
    whether its records satisfy trade-measurement law, customer audits or food
    safety programmes is for the site's quality function to confirm.

## Alternatives considered

1. **Integrate a commercial SPC package** — mature statistics and reports,
   but a licence cost and a second source of truth for product and
   work-order context. Rejected for v1; OFM's data stays exportable to one.
2. **Recalculate control limits continuously** (rolling window) — simpler,
   but the limits drift with the process and hide the very shifts SPC exists
   to detect. Rejected.
3. **Store samples as ordinary measurements** — no subgroup, no operator, no
   work order, no voiding of mistakes. Rejected.
4. **Evaluate rules only when a chart is viewed** — nobody would be told about
   a violation that nobody looks at. Rejected; violations are evaluated and
   recorded as samples arrive.

## Consequences

- Positive: SPC reuses product, work-order and line context already in the
  model; every chart point is traceable to who sampled what, when; limits in
  force at any past moment can be reproduced.
- Negative / cost: control limits need a deliberate baseline-and-approve step,
  which some sites skip; a sample-entry screen must be built and adopted;
  inline-derived characteristics generate more historian rows (no deadband).
- Follow-up work: Phase 3c — the tables above, the subgrouping job, rule
  evaluation, the sample-entry screen, Grafana control-chart dashboards, the
  `spc` payload schema, and `spc` added to the reserved machine names (Phase 1
  naming constraint).

## Notes / references

- ISO 7870-2: *Control charts — Part 2: Shewhart control charts.*
- Default rule set (Western Electric 1–4), the inline subgrouping approach
  and the topic layout are proposals by Claude, accepted with this ADR; they
  are configuration and can be revised per plan.
- Related: ADR-0006 (append-only history), ADR-0008 (quality loss in the
  efficiency waterfall is count-based and separate from SPC), ADR-0010
  (products, work orders, effective-dated master data).

## Amendments

- 2026-10-25: Per ADR-0014, `config.product_spec` references `material_id`
  (any material, so raw materials can also have specifications, e.g. for
  incoming inspection) instead of `product_id`.
