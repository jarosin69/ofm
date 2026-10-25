# ADR-0013: Use Mathesar as the model editor

- **Status:** Accepted (trial passed 2026-10-23)
- **Date:** 2026-10-23, accepted 2026-10-25
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** database, security, ops

## Context

Engineers need a friendly way to maintain the model (sites, lines, machines,
properties, PLC mappings) without writing SQL: a grid with pick-lists for
related rows, with the database's own rules still enforced. The Architecture
Overview named NocoDB for this. Two facts changed the picture:

- On 9 January 2026 NocoDB moved from AGPL-3.0 to the Sustainable Use
  License: source-available, not open source, and requiring a commercial
  licence when NocoDB is part of a paid offering or a customer-facing
  platform. That conflicts with OFM being built from open-source parts and
  could catch integrators who deliver OFM to clients.
- Most OFM installations will sit on automation networks without internet
  access, so every component must run offline and should not depend on
  external services.

The Overview also had to admit a weakness: an editor connecting with one
shared database role makes the audit log record the role, not the person.

## Decision

1. **Mathesar** (GPL-3.0, Mathesar Foundation, a non-profit) replaces NocoDB
   as the model editor, pinned at `mathesar/mathesar:0.12.0` and published on
   `127.0.0.1:8080`.
2. **Its own settings** (Mathesar users, saved views) live in a separate small
   database container, `mathesar-db`, built from the TimescaleDB image the
   stack already uses. No plant data is stored there.
3. **Connection role.** Mathesar connects to the OFM database as
   `ofm_mathesar` (migration 006): a member of `ofm_config` with CREATE on
   the database, which Mathesar needs to install its helper schemas (`msar`,
   `__msar`, `mathesar_types`) on first connection. It has no access to the
   historian or the audit log.
4. **Personal logins.** Each person who edits the model gets a database login
   of their own (`migrate adduser NAME`), a member of `ofm_config`, assigned
   to them as a Mathesar collaborator. The audit log and `updated_by` then
   record the person, closing the gap stated in Overview §11.
5. **Pick-lists.** Mathesar offers related rows as a pick-list only for
   single-column foreign keys. Migration 006 adds one alongside the existing
   two-column key from `machine_property` to `sub_asset`; the two-column key
   keeps enforcing "same machine".
6. **Secrets.** All Mathesar passwords and its secret key are generated into
   `.env` by `make-env.sh`. Mathesar creates its administrator on the first
   visit; the README tells the user to type the generated
   `MATHESAR_ADMIN_USER`/`MATHESAR_ADMIN_PASSWORD` there.
7. **Trial criteria** for accepting this ADR: the `config` tables of `acme`
   can be browsed and edited; foreign keys appear as pick-lists; database
   rules (names, units, duplicate addresses) are reported as readable errors;
   an edit by a personal login appears under that name in `audit.audit_log`;
   no internet access is needed after installation.

## Alternatives considered

1. **NocoDB** — mature and familiar; rejected for its licence change.
2. **Baserow** — open source, but keeps data in its own database and cannot
   edit existing tables.
3. **Directus** — wraps existing databases well, but is under the Business
   Source License, which is not open source.
4. **CloudBeaver / DBeaver** (Apache 2.0) — excellent and offline, but an
   administrator's tool: raw tables and IDs and a full SQL editor rather than
   guided editing. Recommended instead as an optional engineer's tool.
5. **pgAdmin** — open and offline; a database administration tool with no
   friendly pick-lists for technicians.
6. **OFM's own editing screens** (Node-RED Dashboard) — the long-term plan
   (Phase 5) once the model has settled; too early now.

## Consequences

- Positive: open source and offline throughout; per-person audit attribution;
  database rules remain the single line of defence, whatever the tool.
- Negative / cost: Mathesar is at version 0.x, so expect changes between
  releases; two more containers (`mathesar`, `mathesar-db`); Mathesar adds
  its helper schemas to the OFM database; saved views and "explorations" are
  visible to all collaborators regardless of their role; composite foreign
  keys are not offered as pick-lists.
- Follow-up work: the trial (STATUS Phase 1 step 1.2); if Mathesar fails it,
  CloudBeaver is the fallback and this ADR is superseded.

## Notes / references

- Trial result (2026-10-23): Mathesar connected as `ofm_mathesar`; the
  `acme` model was browsed and edited; an edit made by the personal login
  `jarek` was recorded in `audit.audit_log` as `changed_by = jarek`.

- NocoDB licence: https://nocodb.com/docs/self-hosting/license
- Mathesar access control: https://docs.mathesar.org/0.4.0/user-guide/access-control/
- Mathesar relationships (record selector, no composite keys):
  https://docs.mathesar.org/latest/user-guide/relationships/
- Related: ADR-0004 (immutable IDs), ADR-0012 (runner sets role passwords,
  `adduser`), Architecture Overview §11 and §13.
