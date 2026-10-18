# OFM — Project status

*Updated: 2026-10-18. Update this file at the end of every working session.*

## Where we are

**Process step:** step 3 (architecture and functional design) and the
environment hardening are complete. Next is the first Phase 1 build loop,
starting with the database design. No database migrations or flows exist yet.

**Roadmap phase:** pre-Phase-1 (see Architecture Overview §18).

## Done

- Architecture Overview v0.3.1: aligned with all accepted ADRs; manufacturing
  efficiency metrics (§10.3) and work orders with the operator whiteboard
  (§10.4) added; Phase 3 split into 3a and 3b.
- ADR-0001 to ADR-0010 accepted. ADR-0001 to ADR-0003 and ADR-0006 carry dated
  amendments; the template defines the amendment rule.
- Deploy kit hardened: role passwords from `.env` (`db/init/001-init.sh`),
  image versions pinned, ports bound to 127.0.0.1, Node-RED editor login and
  credential secret (`nodered/settings.js`), Mosquitto ACL, Grafana datasource
  provisioned as `ofm_reader`, `.gitattributes` for LF line endings.
- Installation simplified to two commands: `make-env.sh` (run in a throw-away
  Alpine container) generates `.env` with random passwords; the broker builds
  its password file from `.env` at every start; Node-RED checks its login
  against `.env` directly (no bcrypt hash). `deploy/README.md` rewritten.
- Payload contracts in `schemas/` (JSON Schema 2020-12): live value, `_meta`,
  unmapped, work order, and `ofm/_system` source, runtime, cache and historian
  status. 33 example payloads in `tests/schemas/`, checked by
  `tools/validate_schemas.py` (run through Docker; see `schemas/README.md`).
- ADR-0001, ADR-0002 and ADR-0007 amended: per-runtime `_system/cache` and
  `_system/historian` topics; the Last Will `offline` message has no `ts`.
- The external metrics draft (PDF) is fully absorbed into Overview §10.3 and
  ADR-0008 to ADR-0010. It is not part of the repository.
- Proof-of-concept Docker stack (`deploy/`) running on the Windows 11 laptop.
- GitHub repository (private).

## Next, in order

1. **Phase 1 database design:** `db/migrations/001-…` covering
   - the Physical Model tables;
   - `source`, `machine_property`, `plc_mapping` and `engineering_unit`;
   - `vw_runtime_model`;
   - the `hist.measurement` hypertable;
   - audit columns and trigger;
   - `asset_relationship`;
   - reserved names in the naming CHECK constraints: enterprise `ofm`;
     machine names `workorder` and `kpi` (ADR-0010).

   Plus a generated ERD (Mermaid) for review.
2. **Phase 1 build:** generic ingest flow (cache loaded at startup, runtime
   Last Will, source status topics), Grafana dashboard, first tests. The
   runtime validates its outgoing payloads against `schemas/` in tests
   (`ajv` in its 2020-12 mode). Confirm that `${ENV_VAR}` references work in
   the MQTT and PostgreSQL config-node password fields.

## Open questions

| # | Question | Needed by |
|---|---|---|
| 1 | Phase 1 data source: real PLC on the bench (which model?), PLCSIM Advanced, or a free OPC UA simulation server? | Phase 1 DDL |
| 2 | Docker Desktop licence vs. Docker Engine directly in WSL2 (Docker Desktop is free only for personal and small-business use) | Before plant use |
| 3 | Employer policy on open-sourcing work developed for or at the site | Before going public |
| 4 | NocoDB current licence | Before going public |
| 5 | Runtime heartbeat interval: 60 s assumed, shorter reduces `unknown` attribution error (ADR-0006) | Phase 3a |
| 6 | Default `max_publish_interval_ms`: 60 000 assumed (ADR-0007) | Phase 2 |
| 7 | Minor-stop threshold per line: 5 min assumed (ADR-0009) | Phase 3a |
| 8 | Source of good and reject counts per line: PLC counters, or manual reject entry where no counter exists | Phase 3a |
| 9 | Source of rated speeds per product and line, and of the shift calendar and schedule (manual first; ERP/SAP later) | Phase 3a |
| 10 | Treatment of ramp-up after a changeover: inside the changeover window, or counted as speed loss (ADR-0010) | Phase 3a |
| 11 | Defined capacity per line for CU: entered manually or taken from ERP/SAP | Phase 3b |
| 12 | Verify OFM's KPI terminology against the ISO 22400-2 text (ADR-0008) | Before going public |
| 13 | Schemas still to write: machine state (3a), line KPIs (3b), state health (3), `_cmd` write-back (when first needed) | Their phase |

## Known gaps

- Pinned versions (2026-10-18): TimescaleDB 2.30.2-pg16, Mosquitto
  2.1.2-alpine, Node-RED 4.1.16 (Node 22), Grafana 13.2.4 (image
  `grafana/grafana`; `grafana/grafana-oss` is no longer updated), NocoDB
  2026.09.1.
- Mosquitto 2.1 deprecates `password_file`/`acl_file` in favour of plugins
  (removal planned for 3.0). Migrate before any upgrade to 3.x.
- The root `README.md` has not yet been reviewed against the current overview;
  it should point newcomers straight to the two-command install in
  `deploy/README.md`.
- The installation has been run end-to-end on one machine only (Windows 11,
  Docker Desktop). A fresh-clone install test on a second machine, or by
  someone else, is worth doing before going public.
- KPI definitions must be presented as OFM's own, anchored to ISO 22400-2,
  not as a reproduction of any company-internal standard (see open question 3).
- Git history contains the earlier enterprise example name. Decide before going
  public whether to rewrite or squash history.
