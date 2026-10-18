# OFM — Project status

*Updated: 2026-10-18. Update this file at the end of every working session.*

## Where we are

**Process step:** step 3 (architecture and functional design) complete,
including the payload contracts. Next is the environment fix-up, then the first
Phase 1 build loop. No database migrations or flows exist yet.

**Roadmap phase:** pre-Phase-1 (see Architecture Overview §18).

## Done

- Architecture Overview v0.3.1: aligned with all accepted ADRs; manufacturing
  efficiency metrics (§10.3) and work orders with the operator whiteboard
  (§10.4) added; Phase 3 split into 3a and 3b.
- ADR-0001 to ADR-0010 accepted. ADR-0001 to ADR-0003 and ADR-0006 carry dated
  amendments; the template defines the amendment rule.
- `deploy/README.md` aligned with the overview.
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

1. **Deploy kit fixes** (before any real data flows; the init script runs only
   on a fresh database volume):
   - role passwords from `.env`, not committed in `001-init.sql`;
   - pin image versions;
   - bind ports to 127.0.0.1;
   - Node-RED `adminAuth` and `credentialSecret`;
   - Mosquitto ACL file;
   - `flows_cred.json` in `.gitignore`.
2. **Phase 1 database design:** `db/migrations/001-…` covering
   - the Physical Model tables;
   - `source`, `machine_property`, `plc_mapping` and `engineering_unit`;
   - `vw_runtime_model`;
   - the `hist.measurement` hypertable;
   - audit columns and trigger;
   - `asset_relationship`;
   - reserved names in the naming CHECK constraints: enterprise `ofm`;
     machine names `workorder` and `kpi` (ADR-0010).

   Plus a generated ERD (Mermaid) for review.
3. **Phase 1 build:** generic ingest flow (cache loaded at startup, runtime
   Last Will, source status topics), Grafana dashboard, first tests. The
   runtime validates its outgoing payloads against `schemas/` in tests.

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

- `deploy/README.md` needs another pass when the deploy-kit fixes land.
- The root `README.md` has not yet been reviewed against the current overview.
- KPI definitions must be presented as OFM's own, anchored to ISO 22400-2,
  not as a reproduction of any company-internal standard (see open question 3).
- Git history contains the earlier enterprise example name. Decide before going
  public whether to rewrite or squash history.
