# ADR-0004: Use immutable integer IDs for model entities

- **Status:** Accepted
- **Date:** 2026-10-09
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** database, historian, uns

## Context

Equipment gets renamed (`Line01` becomes `MouldingLine01`), moved between
areas, and re-tagged in the PLC. MQTT topics are derived from names
(Architecture Overview §6.1), so any rename changes topics. If history,
mappings or operational records referred to names or topics, every rename
would orphan years of data or force a risky bulk rewrite of the historian.

Physical asset numbering solves the same problem on the plant floor: the
asset number never changes, even when the description does.

## Decision

1. Every entity in the `config` schema has a surrogate primary key
   `id integer GENERATED ALWAYS AS IDENTITY`. An ID is never updated and
   never reused.
2. Names are ordinary attributes, unique only within their parent (two sites
   may each have an area called `packaging`), enforced by a unique constraint
   on `(parent_id, name)`.
3. All foreign keys, historian rows and operational rows reference IDs.
   Names and topic strings never appear as keys in `hist`.
4. Topics are computed from names at cache load (`vw_runtime_model`, ADR-0001)
   and are never stored as the identity of anything.
5. Entities that have history are retired, not deleted: they get a
   `retired_at` timestamp. Foreign keys use `ON DELETE RESTRICT`, so the
   database refuses to hard-delete anything that history still references.
6. External identifiers (CMMS asset number, ERP equipment code) are separate
   optional attributes, never keys.
7. **Retained-topic cleanup.** When a property's topic changes (rename) or the
   property is retired, the runtime publishes an empty retained message to
   the old value topic and the old `_meta` topic, which removes them from the
   broker, then publishes under the new topic. Without this, renamed
   equipment would leave "zombie" topics on the broker indefinitely.

## Alternatives considered

1. **UUIDs** — globally unique, which helps when merging data from several
   sites. Rejected for v1: 16 bytes against 4 per historian row (significant
   at billions of rows), and awkward for engineers reading NocoDB grids or
   writing SQL. Revisit in a new ADR if multi-site federation is required.
2. **Natural keys** such as `DEP01_TEMP` — readable, but they embed names,
   which is exactly the rename problem this ADR solves.
3. **Topic string as key** — rejected for the same reason; topics also change
   whenever any ancestor is renamed.

## Consequences

- Positive: a rename is a one-column update; history, mappings and dashboards
  keyed by ID are unaffected.
- Negative / cost: readable queries need joins, so these are provided as
  views; raw tables show numbers, not names.
- Negative / cost: IDs are local to one database. Moving a model from the PoC
  laptop to a plant server by export/import produces different IDs. This is
  acceptable because history stays with its own database, but any future
  model-transfer tool must match entities by path
  (site/area/line/machine/property), not copy IDs.
- Follow-up work: Phase 1 DDL (identity keys, `(parent_id, name)` uniqueness,
  `retired_at`, `ON DELETE RESTRICT`); runtime compares old and new topic
  sets on every cache reload and clears topics that have disappeared.

## Notes / references

- Related: ADR-0001 (cache and topic computation), ADR-0005 (naming).
- `GENERATED ALWAYS` stops IDs being typed by hand; `pg_dump`/restore handles
  it correctly.

## Amendments

- 2026-10-30: **Clean-up, as built (steps 2.1, 2.2).** On every model reload
  the runtime clears the value and `_meta` topics of properties that no
  longer exist, and the status topics of removed sources. At start-up it also
  reads the retained topics under each enterprise in the model and clears a
  topic only if it has the shape of a property topic (6–7 levels, or that
  plus `/_meta`), is not a reserved line-level topic (`workorder`, `kpi`,
  `spc`, `foodsafety`) or a machine `state` topic, carries an OFM value or
  `_meta` payload, and belongs to no property of any runtime. Anything else
  on the broker is left alone.
