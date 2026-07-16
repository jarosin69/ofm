# ADR-NNNN: Short, decision-stating title (verb phrase, e.g. "Cache the information model in the runtime")

- **Status:** Proposed | Accepted | Superseded by ADR-NNNN | Deprecated
- **Date:** YYYY-MM-DD
- **Deciders:** (who was involved)
- **Tags:** runtime | database | uns | historian | security | ops

## Context

What situation forces this decision? State the problem, the constraints
(technical, organisational, cost), and any relevant facts. Write it so a
reader in two years understands what you knew *at the time*. 2–4 paragraphs
maximum.

## Decision

The decision, stated in the active voice: "We will ...". Include just enough
specifics (names of views, tables, mechanisms) that an implementer knows
exactly what is meant. If the decision has parts, number them.

## Alternatives considered

For each rejected alternative: one line on what it was, one or two lines on
why it lost. Do not straw-man them — record the real trade-off, because a
future revisit of this decision starts here.

1. **Alternative A** — why rejected.
2. **Alternative B** — why rejected.

## Consequences

What becomes easier, what becomes harder, what new obligations this creates.
Include the negative consequences honestly; they are the most valuable part.

- Positive: ...
- Negative / cost: ...
- Follow-up work created: ...

## Notes / references

Links to discussion threads, benchmarks, vendor docs, related ADRs.

---

### Conventions for this repository

- One decision per ADR. If you are writing "and" in the title, split it.
- ADRs are immutable once **Accepted**. To change a decision, write a new
  ADR that supersedes the old one and update the old ADR's status line.
  Never edit history — the point of the record is what was decided and when.
- Number sequentially (`0001`, `0002`, ...); filename is
  `NNNN-kebab-case-title.md` in `docs/adr/`.
- Keep each ADR to roughly one page. If it grows past two, the decision is
  probably several decisions.
- An ADR is worth writing when a decision is (a) expensive to reverse,
  (b) surprising to a newcomer, or (c) something you already argued about.
  Routine choices do not need ADRs.
