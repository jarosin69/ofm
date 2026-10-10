# OFM — Project status

*Updated: 2026-10-09. Update this file at the end of every working session.*

## Where we are

**Process step:** end of step 3 (architecture and functional design), before the
first Phase 1 build loop. No database migrations, schemas or flows exist yet.

**Roadmap phase:** pre-Phase-1 (see Architecture Overview §18).

## Done

- Architecture Overview v0.2, aligned with all accepted ADRs.
- ADR-0001 to ADR-0007 accepted. ADR-0001 to ADR-0003 carry dated amendments;
  the template defines the amendment rule.
- Proof-of-concept Docker stack (`deploy/`) running on the Windows 11 laptop.
- GitHub repository (private).

## Next, in order

1. **Contract specifications** (`schemas/`): JSON Schemas for the live value
   payload, the `_meta` payload, and the `ofm/_system` status payloads
   (sources, runtime).
2. **Deploy kit fixes** (before any real data flows; the init script runs only
   on a fresh database volume):
   - role passwords from `.env`, not committed in `001-init.sql`;
   - pin image versions;
   - bind ports to 127.0.0.1;
   - Node-RED `adminAuth` and `credentialSecret`;
   - Mosquitto ACL file;
   - `flows_cred.json` in `.gitignore`.
3. **Phase 1 database design:** `db/migrations/001-…` covering
   - the Physical Model tables;
   - `source`, `machine_property`, `plc_mapping` and `engineering_unit`;
   - `vw_runtime_model`;
   - the `hist.measurement` hypertable;
   - audit columns and trigger;
   - `asset_relationship`.

   Plus a generated ERD (Mermaid) for review.
4. **Phase 1 build:** generic ingest flow (cache loaded at startup, runtime
   Last Will, source status topics), Grafana dashboard, first tests.

## Open questions

| # | Question | Needed by |
|---|---|---|
| 1 | Phase 1 data source: real PLC on the bench (which model?), PLCSIM Advanced, or a free OPC UA simulation server? | Phase 1 DDL |
| 2 | Docker Desktop licence vs. Docker Engine directly in WSL2 (Docker Desktop is free only for personal and small-business use) | Before plant use |
| 3 | Employer policy on open-sourcing work developed for or at the site | Before going public |
| 4 | NocoDB current licence | Before going public |
| 5 | Rule for deriving line state from machine states (ADR-0006) | Phase 3 |
| 6 | Threshold for "uncoded stop" alerts (ADR-0006) | Phase 3 |
| 7 | Runtime heartbeat interval: 60 s assumed, shorter reduces `unknown` attribution error (ADR-0006) | Phase 3 |
| 8 | Default `max_publish_interval_ms`: 60 000 assumed (ADR-0007) | Phase 2 |

## Known gaps

- `deploy/README.md` is aligned with Overview v0.2 (backup procedure, upgrade
  procedure, licensing note, hardening warning). It will need another pass
  when the deploy-kit fixes land.
- The root `README.md` has not yet been reviewed against Overview v0.2.
- Git history contains the earlier enterprise example name. Decide before going
  public whether to rewrite or squash history.
