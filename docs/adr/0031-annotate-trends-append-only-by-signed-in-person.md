# ADR-0031: Annotate trends append-only, by signed-in person

- **Status:** Accepted
- **Date:** 2026-11-16
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** historian, trends, people

## Context

People reading a trend need to know why it looks the way it does: a trial,
a part change, a quality hold, a setpoint changed. Today that knowledge
lives in shift notes and heads. OFM Trend (ADR-0029) should let people
write it on the chart, so everyone who looks at that signal, machine or
line later sees it. Each note must say who wrote it and when (ADR-0028),
and must not change unnoticed afterwards (ADR-0006).

## Decision

1. **Where:** an annotation is a moment or a period, attached to exactly
   one signal, machine or line (`hist.annotation`). A chart shows the
   annotations of its signals, of their machines and of their lines.
   Grafana *Line OEE* shows a line's annotations, and those of its machines
   and signals.
2. **Who:** anyone signed in on the trend page with employee number and
   PIN (the line view's sign-in, ADR-0028), for 30 minutes without
   activity (`OFM_TREND_IDLE_MINUTES`). Viewing needs no sign-in. There
   are no roles yet: anyone signed in may also correct or remove.
3. **Append-only:** a correction is a new annotation naming the one it
   replaces. A removal is a row of its own (`hist.annotation_removal`) with
   who, when and an optional reason. Nothing is updated or deleted;
   corrected and removed annotations are only hidden from the charts.
   (Removing the demo or load-test line deletes their annotations, as it
   deletes their other history.)
4. **Kinds:** each annotation has a kind with a colour
   (`config.annotation_category`, edited in Mathesar): Note, Quality issue,
   Maintenance, Process change, Trial. A kind is retired, not deleted.
5. **Access:** the trend page writes only through
   `config.fn_person_annotate` and `config.fn_person_annotation_remove`,
   which check the sign-in in the database (`config.fn_person_acting`).
   It reads through `hist.fn_trend_annotations`; Grafana reads through
   `hist.fn_line_annotations`.

Annotations are ordinary tables, not split into blocks, so they keep
foreign keys to the model. ADR-0030 is about the history hypertables.

## Alternatives considered

1. **Grafana's own annotations.** Stored in Grafana's database under
   Grafana logins, not visible on the trend page, and editable without a
   trace. Rejected.
2. **Free editing by the author.** Simpler, but a changed note loses what
   it said before, against ADR-0006. Rejected.
3. **Roles (operator, supervisor) deciding who may remove.** Better
   control, but people have no roles yet; it can come with saved charts
   and preferences (H2b) if wanted.

## Consequences

- One sign-in for the line view and the trend page: same people and PINs,
  same lockout.
- Notes outlive memory: a trend from a year ago still says why it looks
  the way it does.
- A wrong note stays in the database, hidden, with who removed it and why.
  This is deliberate.
