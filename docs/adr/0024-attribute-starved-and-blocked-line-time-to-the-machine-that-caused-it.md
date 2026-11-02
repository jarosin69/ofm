# ADR-0024: Attribute starved and blocked line time to the machine that caused it

- **Status:** Accepted
- **Date:** 2026-11-02
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** database

## Context

A line's state is the state of its constraint machine (ADR-0008 decision 5).
When the erector breaks down, the filler (the constraint) soon runs out of
cartons and reports `starved`; when the closer breaks down, the filler is
`blocked` once the conveyor between them is full. The line loses that time,
but the constraint itself has no fault and no reason.

ADR-0009's classification order then treats the starved time as an uncoded
stop: a minor stop if short, *unaccounted* if long, and Overview §10.3
places starved and blocked under Pos 12 *Other unplanned downtime*. Either
way the line's downtime Pareto says "starved", when the question management
asks is "which machine, and why".

## Decision

1. **Flow order in the model.** Machines that feed each other on a line are
   linked by `config.asset_relationship` rows with `relation_type = 'feeds'`
   (from the upstream to the downstream machine). In v1 a line is a single
   chain; a line with branches or merges is refused by a check view and
   keeps ADR-0009's rules.
2. **A new classification rule**, inserted into ADR-0009's order after
   rule 5 (planned windows) and before rule 6 (minor stops): a slice in
   which the constraint is `starved` takes the effective reason of the
   nearest **upstream** machine that is stopped (not `running`, `starved` or
   `blocked`) at that moment, walking past machines that are themselves
   starved; `blocked` likewise walks **downstream**. The slice takes that
   reason's loss position, and the time ledger records the machine
   (`cause_machine_id`), so downtime is reported by reason and by machine.
3. **When the cause has no reason**, the slice follows the cause's
   classification (minor stop or unaccounted): coding the erector's stop
   fixes the line's figures too.
4. **When no stopped machine is found** (every neighbour running — buffer
   and flow losses), the slice is Pos 12, automatically, without operator
   coding, as Overview §10.3 already says.
5. **Versioned.** The rule belongs to the `kpi_definition_version`
   (ADR-0008), like the minor-stop threshold.

## Alternatives considered

1. **Leave starved/blocked as Pos 12** — simple and correct in total, but
   hides the root cause, which is the main value of the downtime report.
   Rejected.
2. **Operators code the constraint's starved stops** — double coding of one
   event, inconsistent between shifts. Rejected.
3. **Attribute by modelling buffer contents** — more precise when several
   machines are down at once, but needs buffer sizes and fill levels.
   Rejected for v1; nearest stopped machine is the usual practice.

## Consequences

- Positive: the line's downtime Pareto names machines and reasons; the
  operator codes each stop once, on the machine where it happened.
- Negative / cost: the time-ledger view gains a neighbour search per
  starved/blocked slice; flow order must be maintained in the model;
  branched lines need a later decision.
- Follow-up work: Overview §10.3 (Pos 12 description) and the ledger view
  in Phase 3a/3b; the demo checks it against the simulator's own
  attribution (ADR-0023).

## Notes / references

- This ADR adds one rule to ADR-0009 and changes none of its other rules.
  When accepted, ADR-0009 gets a dated amendment line pointing here.
- Related: ADR-0006, ADR-0008, ADR-0009, ADR-0023.
