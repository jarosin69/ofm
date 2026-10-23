# ADR-0012: Apply database migrations with a small runner script

- **Status:** Accepted
- **Date:** 2026-10-21
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** database, ops

## Context

The database structure grows phase by phase as numbered SQL files
(*migrations*) in `db/migrations/`. Several databases will exist at different
points in that series: the PoC laptop, a plant server installed later, and every
fresh clone by someone else. Each needs exactly its missing migrations applied,
in order, never one twice — the database equivalent of engineering change
notices applied to a machine fleet, with a revision log on each machine.

The established tool for this is Flyway. It does the job well but is another
product to pin, learn and follow (it is commercially owned, with features split
across editions). OFM's needs are small: apply in order, record, refuse
surprises. The "boring technology, few moving parts" principle (Architecture
Overview §2) favours the smallest tool that does this safely.

## Decision

1. **Runner.** `tools/migrate.sh`, a short POSIX shell script using `psql`,
   runs in a one-shot `migrate` service in `deploy/docker-compose.yml`, built
   from the TimescaleDB image the stack already uses. No new image, no local
   installation.
2. **Revision log.** `public.schema_migrations (version, filename, checksum,
   applied_at, applied_by)` records every applied migration. It sits outside
   the `config` schema, so NocoDB and the editing role never see it.
3. **Files.** `db/migrations/NNN-description.sql` — three digits, lowercase,
   hyphens. The runner refuses badly named files and duplicate numbers.
4. **One transaction per migration.** Each file and its log entry are applied
   in one transaction: a failing migration leaves no trace. A file whose first
   line contains `ofm:no-transaction` is run outside a transaction, for the few
   statements PostgreSQL cannot run inside one (e.g. creating TimescaleDB
   continuous aggregates). Migration files never contain `BEGIN`/`COMMIT`.
5. **Checksums.** The SHA-256 of each file (line endings normalised) is
   stored. If an applied file has been edited since, the runner stops with an
   error. A change is always a new migration.
6. **Forward only.** There are no "down" migrations. A mistake is corrected by
   a new migration, as a wrong ECN is corrected by a new ECN.
7. **Applied automatically.** The `migrate` service runs on every
   `docker compose up`; Node-RED starts only after it has completed
   successfully. The database structure therefore can never lag behind the
   code, and a failed migration stops the runtime rather than letting it run
   against the wrong structure.
8. **Owner.** Migrations run as the superuser `POSTGRES_USER`, so the default
   privileges set by `db/init/001-init.sh` apply to every object they create.
9. **Commands.** `docker compose run --rm migrate [up|status|example|erd]`:
   apply, report, load the example plant (`db/examples/acme.sql`, kept out of
   the migrations so plant databases never receive demo data), and regenerate
   the ERD (`docs/generated/erd.md`) from the live database.

## Alternatives considered

1. **Flyway** — mature, with repair and reporting features; rejected as an
   extra dependency whose extras OFM does not need. Switching later is easy:
   Flyway can be told which versions are already applied (baseline).
2. **Manual `psql` discipline** — no tool at all; rejected because nothing
   records what was applied where, and a repeated or skipped file is only
   discovered when something breaks.
3. **Migrations applied only by explicit command** — more deliberate, but
   newcomers and upgrades forget the step and run new flows against an old
   structure. Rejected in favour of automatic application with a fail-safe stop.

## Consequences

- Positive: installation stays at two commands; every database carries its own
  revision log; edited or broken migrations are caught before they do harm.
- Negative / cost: OFM maintains about 150 lines of shell script; there are no
  automatic rollbacks, so upgrades must be preceded by a database backup;
  migrations cannot run concurrently from two machines (not a v1 scenario).
- Follow-up work: back-up-before-upgrade step in `deploy/README.md`; schema
  tests (Phase 1 step 1.4) run against a database built by this runner.

## Notes / references

- `db/migrations/README.md` holds the conventions for writing migrations.
- Related: ADR-0004 (immutable IDs), ADR-0005 (naming), Architecture Overview §11.
