# ADR-0009: Classify losses through the reason catalogue

- **Status:** Accepted
- **Date:** 2026-10-18
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** database, oee

## Context

Each stretch of non-running time must land in exactly one waterfall position
(ADR-0008). The machine state alone cannot decide which:

- `maintenance` may be planned PM (Pos 4) or a breakdown repair (Pos 9);
- `fault` may be a breakdown (Pos 9) or a minor stop (Pos 12);
- an operator stop for a meal break is planned downtime (Pos 7);
- any time outside the scheduled shifts is No Activity (Pos 2), whatever
  the machine is doing.

MTBF and MTTR also need a precise definition of a breakdown. Finally, a single
line produces many short stops per shift, far too many to code by hand.

## Decision

1. **Reasons carry the position.** Every reason in `config.reason` maps to
   exactly one loss position (4, 5, 6, 7, 9 or 12). Reasons are grouped under
   positions and filtered per machine, as in Architecture Overview §10.2.
2. **Classification order.** Each slice of time is classified by the first
   rule that applies:
   1. Outside scheduled production time (shift calendar and schedule) →
      Pos 2 No Activity.
   2. Machine state `unknown` → unaccounted.
   3. A stop with an effective reason (ADR-0006) → that reason's position.
   4. A stop inside a changeover window (ADR-0010) → Pos 6.
   5. A stop inside a scheduled planned-downtime window (PM, cleaning) → that
      window's position.
   6. A stop shorter than the minor-stop threshold → Pos 12 (automatic minor
      stop; no operator coding required).
   7. Any other stop → unaccounted, until someone codes it.
3. **Breakdown definition.** A breakdown is a stop classified as Pos 9, which
   can only happen through a reason. MTBF and MTTR count distinct Pos 9 stops
   per machine. The duration threshold applies only to uncoded stops; an
   explicit reason always wins.
4. **Threshold.** The minor-stop threshold is configured per line and belongs
   to the KPI definition version (ADR-0008).
5. **Classified at read time.** Classification is computed by a view,
   `vw_time_ledger`, over state events, reasons, the schedule and work-order
   windows. It is never stored. A late reason, a supervisor correction or a
   schedule fix therefore reclassifies history automatically, without any
   UPDATE.
6. **Comments.** `state_reason` carries an optional free-text `comment`, for
   example "Cleaned glue from rails as well".

## Alternatives considered

1. **Fixed mapping from state to position** — simple, but cannot separate
   planned from unplanned, or breakdowns from minor stops. Rejected.
2. **Operators code every stop** — complete, but impractical with dozens of
   minor stops per shift; coding quality collapses. Rejected in favour of the
   threshold.
3. **Uncoded stops default to Pos 12** — hides the coding gap and lets
   uncoded downtime look like ordinary minor stops. Rejected; the unaccounted
   bar keeps the gap visible.
4. **Store the classification when the stop happens** — faster to query,
   but every correction would need an UPDATE (against ADR-0006) and late
   reasons would never propagate. Kept in reserve as a materialised view if
   needed.

## Consequences

- Positive: one rule set produces the whiteboard, the waterfall, Downtime,
  MTBF and MTTR; corrections propagate; the coding burden is limited to stops
  that matter.
- Negative / cost: the schedule becomes mandatory master data, because
  without it all time counts as scheduled. The classification view is the
  most complex SQL in the platform and needs thorough tests.
- Follow-up work: `config.reason` with its position mapping;
  `config.shift_calendar` and planned-downtime windows; the `comment` column
  on `state_reason`; `vw_time_ledger` with test cases covering every rule
  above (Phase 3).

## Notes / references

- The default minor-stop threshold of 5 minutes is an assumption, to be
  confirmed per line.
- Related: ADR-0006, ADR-0008, ADR-0010.
