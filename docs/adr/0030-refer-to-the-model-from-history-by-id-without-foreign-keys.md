# ADR-0030: Refer to the model from history by ID, without foreign keys

- **Status:** Accepted
- **Date:** 2026-11-15
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** historian, database, model editor

## Context

History is keyed by immutable integer IDs (ADR-0004). Until migration 024,
three history tables (`hist.measurement`, `hist.measurement_text`,
`hist.production_count`) also had a foreign key to
`config.machine_property`.

TimescaleDB copies a hypertable's foreign key onto each of its blocks
(chunks), one per day. With a year of history (made up for testing,
step H1), `machine_property` was referenced by about 370 tables. Mathesar
(ADR-0013) shows a panel of linked records for every table that references
a record, and reloads them all on each save: saving one property in
Mathesar took minutes. A year of real history would have done the same.
Every value written also checked the key, which costs time at thousands of
values per second.

## Decision

History refers to `config.machine_property` by ID only, with no foreign
key. What the keys gave is kept as follows:

1. **IDs cannot change:** model IDs are generated identity columns;
   PostgreSQL refuses to set them.
2. **A property with history cannot be deleted:** a trigger on
   `config.machine_property` refuses it with the same error as a foreign
   key (23503) and the hint to retire it instead. Removing the demo or the
   load-test line deletes their history first, as before.
3. **Only the runtime writes history,** with IDs from its copy of the
   model (ADR-0001).

New history tables follow the same rule. Model tables keep their foreign
keys among themselves; they are small and Mathesar uses them to show links.

## Alternatives considered

1. **Keep the keys and hide history from Mathesar.** Mathesar finds
   linked tables from the database catalogue, whatever the user may read.
   Not possible.
2. **Fewer, larger blocks** (a week or a month instead of a day). Fewer
   links, but the problem returns with time. It also changes compression
   and retention granularity. Rejected.

## Consequences

- Saving a property in Mathesar is instant again: 5 ms in the database
  against 0.4 s, and no extra panels in Mathesar.
- Writing history no longer checks the key. That is slightly faster.
- A history row with an unknown ID cannot be prevented by the database.
  The runtime writes only IDs from the model.
