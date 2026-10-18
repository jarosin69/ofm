# ADR-0008: Measure efficiency with a time-based loss waterfall

- **Status:** Accepted
- **Date:** 2026-10-18
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** historian, database, oee

## Context

The platform needs operations KPIs (GE, OEE, Downtime, MTBF, MTTR) and
management KPIs (GE, OEE, CU, LU, TEEP). Calculated independently, such KPIs
drift apart: different time bases, different treatment of changeovers, numbers
that cannot be reconciled with each other. A loss waterfall solves this. It
steps calendar time down through loss categories to good production, so that
every KPI is a ratio between two of its positions, and the sum of the
positions always equals calendar time.

Two inputs were missing from earlier drafts. First, speed and quality losses
are not events; they can only be calculated from counts and a rated speed.
Second, MTBF had been defined on Operating Time, a virtual quantity that is
reduced by speed and quality losses even though neither is a failure.

## Decision

1. **Waterfall.** OFM uses a 13-position time waterfall. The positions are
   reference data in `config.loss_category`, seeded by a migration.
   - **Milestones:** 1 Maximum Time, 3 Hours Used, 8 Production Hours,
     13 Operating Time.
   - **No activity:** 2 No Activity.
   - **Planned downtime:** 4 Maintenance, 5 Cleaning, 6 Changeover,
     7 Other Planned DT.
   - **Unplanned and performance losses:** 9 Breakdowns, 10 Speed Loss,
     11 Quality Loss, 12 Other Unplanned DT.
   - **Unaccounted:** a further category for `unknown` time and uncoded stops
     (ADR-0009). It is shown as its own bar after Pos 12 and treated as
     unplanned, so it reduces GE, OEE and TEEP. Leaving stops uncoded therefore
     never improves a KPI.
2. **Speed and quality are calculated, not classified.** With ICT the ideal
   cycle time at rated speed (ADR-0010):
   - running time = Production Hours − Pos 9 − Pos 12 − unaccounted;
   - Pos 13 Operating Time = good count × ICT;
   - Pos 11 Quality Loss = reject count × ICT;
   - Pos 10 Speed Loss = running time − total count × ICT.
3. **KPIs.**

   | KPI | Definition |
   |---|---|
   | GE | Pos 13 ÷ Pos 3 |
   | OEE | Pos 13 ÷ Pos 8 = A × P × Q |
   | Availability (A) | running time ÷ Pos 8 |
   | Performance (P) | (total count × ICT) ÷ running time |
   | Quality (Q) | good count ÷ total count |
   | Downtime | Pos 9 + Pos 12 + unaccounted, in hours |
   | MTBF | machine running time ÷ number of breakdowns |
   | MTTR | total breakdown duration ÷ number of breakdowns |
   | LU | Pos 3 ÷ Pos 1 |
   | CU | Pos 3 ÷ defined capacity (configured per line) |
   | TEEP | Pos 13 ÷ Pos 1 = LU × GE |

4. **Performance above 100 % is a master-data error.** A negative speed loss
   means the rated speed is set below what the line achieves. It is stored and
   flagged, never clipped.
5. **Level.** Line KPIs are calculated from line output counts and the line's
   state. The line state is the state of the line's designated constraint
   machine, or of a line-level machine where the PLC provides a line state
   signal. Machine-level waterfalls serve diagnosis, MTBF and MTTR. Line
   figures are never sums of machine figures, because downstream machines
   report `starved` during an upstream stop and would double-count it.
6. **Periods.** Hourly, shift, day, week, month and year periods are bounded
   in Australia/Melbourne local time and calculated from UTC data
   (ADR-0003). Maximum Time is the real elapsed duration, so a daylight-saving
   day has 23 or 25 hours.
7. **Calculated at read time and versioned.** KPIs are SQL views over the
   historian, never values computed in the runtime. Every rule that affects a
   result (waterfall mapping, minor-stop threshold, rated speeds) belongs to a
   `kpi_definition_version`. A KPI value is always reported with its version.
8. **Terminology.** OEE, availability, performance, quality, TEEP, MTBF and
   MTTR follow ISO 22400-2 terminology where an equivalent exists. GE (Global
   Efficiency, with Hours Used as denominator) is OFM's named variant.

## Alternatives considered

1. **Classic OEE (A × P × Q) only** — standard, but it cannot express planned
   downtime, no-activity time or capacity utilisation, so it cannot serve the
   management KPIs. Kept as a decomposition of OEE instead.
2. **A more granular waterfall (around 20 positions)** — finer root-cause
   categories, but more classification burden for operators. Finer detail
   lives in the reason catalogue below each position instead.
3. **KPIs computed in the Node-RED runtime** — rejected. They could not be
   recalculated after a reason is corrected, and they would duplicate logic
   that SQL expresses more clearly.
4. **MTBF on Operating Time (Pos 13)** — rejected. It penalises reliability
   for speed and quality losses that are not failures.

## Consequences

- Positive: every KPI reconciles with every other KPI; the hourly whiteboard
  and the management waterfall are the same calculation, in units or hours;
  correcting a reason or a schedule corrects every affected KPI.
- Negative / cost: everything depends on rated speeds and on good and reject
  counts. A line without counts can report downtime, MTBF and MTTR only.
  Read-time calculation may need materialised views for long periods.
- Follow-up work: seed migration for `loss_category`; `kpi_definition_version`
  table; KPI views (Phase 3b); verify the terminology mapping against the
  ISO 22400-2 text; a test that the waterfall closes (positions sum to
  Maximum Time) for every period, including both daylight-saving days.

## Notes / references

- ISO 22400-2: *Automation systems and integration — Key performance
  indicators (KPIs) for manufacturing operations management — Part 2:
  Definitions and descriptions.*
- Related: ADR-0006 (state events; this ADR resolves its open question on
  line state), ADR-0009 (classification), ADR-0010 (rated speeds and work
  orders).
