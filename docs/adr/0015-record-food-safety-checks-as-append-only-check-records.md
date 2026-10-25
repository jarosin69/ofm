# ADR-0015: Record food safety checks as append-only check records

- **Status:** Accepted
- **Date:** 2026-10-25
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** database, historian, quality

## Context

A food plant's HACCP plan defines critical control points (CCPs) and
prerequisite programmes that must be monitored and recorded: metal detector
tests with test pieces, cooking or cooling temperatures, cleaning and
allergen changeover verification, foreign-body checks. Each record says who
checked what, when, with which result, and — when a check fails — what
corrective action was taken and who verified it. These records are often
still on paper, and auditors ask for them.

The SPC design (ADR-0011) already provides most of the machinery: definitions
in the model, plans with intervals, append-only records, an entry screen,
overdue detection, publication to the UNS. Food safety checks add what SPC
lacks: critical limits that demand action, mandatory corrective actions, and
second-person verification.

## Decision

1. **Check definitions.** `config.food_safety_check` defines each check:
   name, type (`pass_fail` or `measured` with critical limits and unit),
   location (line or machine), frequency (interval, per shift, per work order
   start, per changeover), whether it is a CCP, and instructions.
2. **Check records are append-only.** `hist.check_record (id, check_id, ts,
   result, value, work_order_id, lot_id, performed_by, source)`. A correction
   is a new record that voids the wrong one, as for SPC samples.
3. **A failed check requires a corrective action.** `hist.corrective_action
   (check_record_id, ts, action_taken, product_disposition, entered_by)`. A
   failed check stays visibly "open" until its corrective action is recorded.
4. **Verification by a second person.** `hist.check_verification
   (check_record_id, ts, verified_by, comment)`. The verifier must be a
   different person from the one who performed the check, enforced by the
   database.
5. **Monitored CCPs.** A CCP measured by an instrument (e.g. a cooling-tunnel
   temperature) can be linked to a property: a value outside the critical
   limits creates a deviation record automatically, which then needs a
   corrective action like a failed manual check.
6. **Overdue and open checks are visible.** The state of each check (done,
   due, overdue, failed and open) is published retained on
   `{enterprise}/{site}/{area}/{line}/foodsafety/{check}`, which makes
   `foodsafety` a reserved machine name (migration 007).
7. **People sign as themselves.** Records carry the identity of the person who
   entered them. Operator screens therefore need per-person sign-in, which the
   operator whiteboard (Phase 3a) introduces.
8. **Shared machinery with SPC.** The entry screen framework, overdue logic and
   publication are built once for SPC (Phase 3c) and reused here (Phase 3d).
9. **Scope.** OFM records the checks; the HACCP plan itself, its validation,
   and the decision whether OFM's records satisfy a certification scheme or
   regulator stay with the site's quality function.

## Alternatives considered

1. **Implement checks as SPC attribute samples** — less code, but SPC has no
   corrective actions, verification or critical-limit semantics, and mixing
   the two would confuse both. Rejected; the two share machinery, not tables.
2. **Keep paper records** — the status quo; no overdue alerts, no link to
   work orders and lots, slow to audit. Rejected as the target state.
3. **A separate commercial food safety application** — capable, but another
   system with its own copy of lines, products and people. Rejected for v1.

## Consequences

- Positive: overdue and failed checks are visible live; every record is
  traceable to a person, a time, a work order and (from Phase 3e) a lot;
  audit evidence comes from a query instead of a filing cabinet.
- Negative / cost: requires per-person sign-in on the floor; digital records
  must be backed up and retained as carefully as paper ones; sites must
  decide whether electronic records replace or accompany paper.
- Follow-up work: migration 007 reserves `foodsafety`; Phase 3d builds the
  tables, screens, deviation detection and dashboards.

## Notes / references

- Related: ADR-0006 (append-only), ADR-0011 (SPC machinery), ADR-0014
  (lots), ADR-0010 (work orders).
