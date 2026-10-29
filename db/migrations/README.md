# Database migrations

Numbered SQL files that build the OFM database structure, applied in order by
`tools/migrate.sh` (ADR-0012). They are normative: when a document and a
migration disagree, the migration wins.

## Rules

- **Name:** `NNN-description.sql` — three digits, lowercase, hyphens
  (`006-machine-states.sql`). Take the next free number.
- **Never edit a migration once it has been applied anywhere.** The runner
  detects it (checksum) and stops. Put every change in a new migration.
- **No `BEGIN` / `COMMIT`.** The runner wraps each file in one transaction.
  For the rare statement that cannot run in a transaction, put
  `-- ofm:no-transaction` on the first line.
- **Follow ADR-0004 and ADR-0005:** snake_case; `id integer GENERATED ALWAYS
  AS IDENTITY`; `retired_at` instead of deleting; foreign keys
  `ON DELETE RESTRICT`; names checked with `config.fn_is_valid_name()`.
- **Configuration tables** carry `created_at/_by` and `updated_at/_by` and
  call `CALL audit.fn_enable('config.<table>');`.
- **History tables** in `hist` are append-only: the runtime role gets SELECT
  and INSERT only (automatic, from the default privileges).
- **No secrets.** A migration may create a role, never set its password:
  passwords come from `deploy/.env` and are set by the runner.
- **Reference data** every installation needs (e.g. engineering units) goes in
  a migration. **Example or site data** does not: see `db/examples/`.

## Commands (from `C:\ofm\deploy`)

```powershell
docker compose run --rm migrate status    # what is applied, what is pending
docker compose run --rm migrate           # apply pending (also runs on every "docker compose up")
docker compose run --rm migrate example   # load or refresh the example plant "acme"
docker compose run --rm migrate erd       # regenerate docs/generated/erd.md
docker compose run --rm migrate adduser jarek   # personal model-editing login
```

## Contents

| File | Creates |
|---|---|
| `001-foundations.sql` | Naming and time-zone checks; audit columns; `audit.audit_log` |
| `002-physical-model.sql` | `enterprise`, `site`, `area`, `line`, `machine`, `sub_asset` |
| `003-information-model.sql` | `engineering_unit` (with units), `source`, `machine_property`, `plc_mapping`, `asset_relationship` |
| `004-runtime-model-view.sql` | `vw_runtime_model` (the runtime cache), `vw_property_path` |
| `005-historian.sql` | `hist.measurement`, `hist.measurement_text` (hypertables), `hist.vw_measurement` |
| `006-model-editor-support.sql` | Single-column key `machine_property` → `sub_asset` (for pick-lists); login `ofm_mathesar` for the model editor (ADR-0013) |
| `007-reserve-foodsafety-topic.sql` | Machine name `foodsafety` reserved for food safety check topics (ADR-0015) |
| `008-polled-plc-sources.sql` | Protocol `ethernetip`; S7 sources must state rack and slot; poll interval at least 100 ms (ADR-0018) |
