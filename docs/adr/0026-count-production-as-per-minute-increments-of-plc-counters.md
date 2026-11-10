# ADR-0026: Count production as per-minute increments of PLC counters

- **Status:** Accepted
- **Date:** 2026-11-06
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** historian, runtime, kpi

## Context

Every KPI of ADR-0008 needs good and reject counts, and work orders
(ADR-0010) need them per order. PLCs provide counters: running totals that
only rise, until they are reset to 0 by a program download, a power loss
on a non-retentive counter, or an operator (the demo's *New run*). The raw
readings are already in `hist.measurement`, but adding up production from
them means comparing every reading with the one before, at every query,
with resets handled each time; and storing one increment per reading would
add about 31 million rows a day at plant scale (about 360 counters, one
reading a second), kept without a time limit, since production figures are
business records.

## Decision

1. **Which counters.** Properties with the role `count_in`, `count_good` or
   `count_reject` (migration 013), datatype int or float.
2. **Increment.** The runtime subtracts each good reading's previous good
   reading of the same counter. Readings with quality bad are skipped; the
   next good reading carries the difference.
3. **Reset.** A reading lower than the previous one means the counter
   restarted from 0: the increment is the reading itself. The runtime logs a
   warning naming the counter and both values. A counter that wraps at its
   maximum is treated the same way (losing at most the counts before the
   wrap); a PLC that loads a counter with a non-zero start value would be
   counted as production, which OFM cannot tell apart.
4. **Per minute.** Increments are added up per counter and minute (the
   minute of the reading's own time) and written once the minute is over to
   `hist.production_count (property_id, ts, increment, last_value, resets)`,
   one row per minute with production or a reset, through the historian
   writer and its disk queue (ADR-0002). Append-only (ADR-0006), compressed
   after 7 days, no retention limit. A reading is never booked into a
   minute already written or before the runtime first saw the counter; it
   goes into the oldest minute still open.
5. **Restart and connection loss.** At start-up the runtime takes each
   counter's `last_value` from its newest row (after the disk queue is
   empty, as for ADR-0006 reconciliation) and compares the first new
   reading with it. Units made while OFM could not read are therefore
   counted in the minute it reads again; that time already shows `unknown`
   in the state history.

## Alternatives considered

1. **Increments calculated at query time from `hist.measurement`.** No new
   table, but every KPI query would repeat the reset logic over every raw
   reading, slow for months, and raw readings expire after a year.
   Rejected.
2. **One row per reading.** Exact to the second, but about 60 times the
   rows; no KPI needs more than the minute (periods start on whole minutes;
   orders change while the line stands). Rejected.
3. **A continuous aggregate of the counter readings** (last value per
   minute). Cannot see a reset inside a minute, and loses those counts.
   Rejected.

## Consequences

- Positive: period totals are sums of a few rows; resets and outages are
  handled once, where the readings arrive; the same increments will feed
  live KPIs (step 3a.7) and the history, so they agree.
- Negative: counts are only as fine as the minute; counts made during an
  outage land in the minute after it, not spread over it; a counter loaded
  with a start value is counted as production.
- Follow-up: manual reject entry (open question 8); ramp-up and
  changeover-end detection use the raw `count_good` readings where the
  second matters (step 3a.5).

## Amendments

- 2026-11-10: **KPIs up to the last counted minute (migration 021).** A
  minute's units are written a few seconds after it ends, while running time
  is known to the second, so a period ending "now" lacked the current
  minute's units: a 3-minute-old order showed 24–88 % performance instead of
  about 96 %. Live KPIs (`…/kpi/…`) and the Grafana dashboard end such a
  period at `hist.fn_counted_until()`, the end of the last written minute;
  past periods are unchanged. The line view's order progress lags the
  panel by up to about a minute for the same reason.
