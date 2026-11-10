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

## Amendments

- 2026-11-03: **As built (migration 012, step 3a.2).** `config.loss_category`
  holds the positions with id = position number; Unaccounted has id 90 and
  sorts after position 12. The KPI definition version of decision 7 is the
  row of `config.line_kpi_rule` in force at the time: a line's constraint
  machine and minor-stop threshold, from a `valid_from`, never changed once
  in force (a new rule is a new row). Rated speeds are versioned the same
  way in `config.material_line_rate` (ADR-0010 amendment); the waterfall
  mapping is versioned with the KPI views themselves (migrations).
- 2026-11-06: **Line counts (decision 5; step 3a.4, migration 014).** The
  KPI rule names the line's **output machine** (`output_machine_id`, empty
  = the constraint machine). Line good count = `count_good` of the output
  machine; line reject count = `count_reject` of every machine from the
  constraint to the output machine along the flow order (`feeds`,
  ADR-0024), both included: units rejected after they used constraint
  time, so the quality loss is reject count × ICT. Rejects before the
  constraint (e.g. spoiled packaging) are machine counts only. Being part
  of the KPI rule, the output machine is dated with it. Counts per minute:
  `hist.vw_line_count`, from `hist.production_count` (ADR-0026).
- 2026-11-07: **As built (step 3a.7, migration 017).** The KPIs are SQL
  functions over the historian, because they take a line and a period:
  `hist.fn_line_kpi(line, from, to)` (positions 1–13 and unaccounted, A, P,
  Q, OEE, GE, LU, TEEP, downtime), `hist.fn_line_kpi_series(line, from, to,
  bucket)` (hour, day, week or month, bounded in the site's local time) and
  `hist.fn_machine_reliability(line, from, to)` (MTBF, MTTR per machine).
  Decided in the 3a.7 design:
  - **Scheduled time** (Pos 3) is every schedule window together,
    production and planned; anything outside is Pos 2, also when the line
    runs, and units counted outside the schedule are not counted.
  - **ICT** comes from the rated speed of the running order's product;
    between orders, from the last order's product. Units without an ICT
    (counted before the line's first order, or a product without a rated
    speed) leave positions 10, 11 and 13 of their period, and every KPI that
    needs them, empty (null): never guessed.
  - **Version** (decision 7): each result carries `kpi_rule_id`, the KPI
    rule in force at the start of the period, and `kpi_rule_changed` when
    another came into force within it.
  - **MTBF and MTTR** are per machine: a breakdown is the machine's own stop
    with an effective Pos 9 reason; MTBF = the machine's running time ÷
    breakdowns.
  - **Shift periods** (decision 6) wait for a shift model; until then the
    periods are hour, day, week and month.
  - **Live KPIs.** The runtime republishes `hist.fn_live_line_kpi()` (the
    current hour, today and the running order of every line) every minute,
    retained, on `{line}/kpi/hour`, `/kpi/day` and `/kpi/order`
    (`schemas/line-kpi.schema.json`); it calculates nothing itself
    (alternative 3 stays rejected), so the topics always agree with the
    queries.
  - **Speed.** The functions run with PostgreSQL's JIT compilation off,
    which costs seconds for these queries; a day takes about 0.2 s and a
    week 0.7 s on a simulated busy week. No materialised views needed yet.
  The waterfall closes (positions add up to Pos 1) in the database tests,
  including both daylight-saving days.
- 2026-11-09: **Shifts and the Line OEE dashboard (step 3a.8b, migration
  019).** Decision 6's shift periods: each line's shifts are rows of
  `config.line_shift` (name, start, end, the days a shift starts on, valid
  from/to), edited in Mathesar, in the site's local time; a shift ending at
  or before its start ends the next day. Shifts only cut time, like hours
  and days: scheduled time stays `config.line_schedule`. Overlapping shifts
  are listed in `config.vw_line_shift_problem`. The Grafana dashboard
  *OFM · Line OEE* shows, for the time picker's period or one chosen shift:
  OEE, availability, performance and quality as gauges, coloured red below
  and green from OEE 60/85 %, availability 80/90 %, performance 80/95 %,
  quality 95/99 % (assumed common targets; amber between); downtime by
  reason and by machine charged; OEE trend per hour or day; OEE per shift;
  the loss waterfall; machines (MTBF, MTTR); stops and orders. The line
  view's KPI tiles use the same colours. There is deliberately **no OEE per
  machine**: OEE belongs to the line at its constraint, and a machine next
  to the constraint would look poor whenever the constraint starves or
  blocks it; *downtime by machine* (time charged per ADR-0024) answers
  which machine costs the line most.
- 2026-11-10: **A work order as the dashboard's period (migration 022).**
  *OFM · Line OEE* can show a work order: the running one (the default,
  moving on to the next order by itself) or one of the last two weeks. An
  order wins over a shift, a shift over the time picker; a *Period shown*
  bar names the period.
