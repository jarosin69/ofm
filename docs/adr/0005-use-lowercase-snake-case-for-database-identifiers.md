# ADR-0005: Use lowercase snake_case for database identifiers

- **Status:** Accepted
- **Date:** 2026-10-09
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** database

## Context

Early documents mixed PascalCase names (`MachineProperty`, `PLCMapping`,
`vw_RuntimeModel`, `Measurement`) with snake_case ones (`measurement`,
`machine_state_history`). PostgreSQL folds unquoted identifiers to lowercase:
`CREATE TABLE MachineProperty` actually creates `machineproperty`. Keeping the
capitals would require double quotes in every query and every tool (NocoDB,
Grafana, Node-RED, Python) forever, and a single forgotten pair of quotes
produces a "relation does not exist" error.

The convention must be fixed before the first migration, because renaming
tables afterwards means a migration plus updating every query that uses them.

## Decision

We will write all database identifiers in lowercase snake_case and never quote them:

| Object | Convention | Example |
|---|---|---|
| Schemas | short nouns | `config`, `hist` |
| Tables | singular noun | `machine`, `machine_property`, `plc_mapping` |
| Primary key | `id` | `machine.id` |
| Foreign key | `<referenced_table>_id` | `machine_property.machine_id` |
| Timestamps | `ts` for event time, `*_at` for audit times; type `timestamptz` | `ts`, `created_at` |
| Booleans | `is_` / `has_` prefix | `is_active` |
| Views | `vw_` prefix | `vw_runtime_model` |
| Functions / triggers | `fn_` / `trg_` prefix | `fn_notify_model_changed` |

Names in earlier documents read as their snake_case equivalents:
`MachineProperty` → `machine_property`, `PLCMapping` → `plc_mapping`,
`vw_RuntimeModel` → `vw_runtime_model`, `Measurement` → `measurement`,
`AssetRelationship` → `asset_relationship`, `PropertyID` → `property_id`.

## Alternatives considered

1. **PascalCase, quoted everywhere** — rejected: a permanent tax on every
   query and a constant source of errors in third-party tools.
2. **Plural table names** (`machines`) — a matter of taste. Singular reads
   more naturally in foreign keys (`machine_id` references `machine`). Only
   changeable now, before the first migration.

## Consequences

- Positive: SQL can be typed in any case (`SELECT * FROM Machine` works);
  no quoting anywhere.
- Negative / cost: NocoDB and Grafana show lowercase table names; display
  names for people come from the model, not from table names.
- Follow-up work: apply in the Phase 1 DDL; correct table names in the
  Architecture Overview §5, §7.2 and §10 at its next revision. ADR-0001 to
  ADR-0003 carry naming amendments.

## Notes / references

- Singular table names and the `fn_` / `trg_` prefixes were proposed by
  Claude and accepted without debate.
- Related: ADR-0004.
