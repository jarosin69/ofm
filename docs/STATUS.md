# OFM — Status and development strategy

*Updated: 2026-10-21. Update this file at the end of every working session.*

**▶ We are here: Stage B, Phase 1, step 1.1 — database design delivered,
awaiting Jarek's review.** After the review, step 1.2 adds the OPC UA simulator.

## The strategy in one view

OFM is built in four stages. Stage A lays the foundations once. Stage B builds
the system in phases; each phase is useful on its own and ends with a tested,
tagged release. Stage C takes it into the plant. Stage D, publishing it as open
source, runs alongside and must be finished before the repository goes public.

```
Stage A  Foundations ............................. ✅ done
Stage B  Build in phases
           Phase 1   Live data path .............. ▶ in progress (step 1.1 review)
           Phase 2   Robust and editable ......... ⬜
Stage C  Plant pilot (one real line) ............. ⬜  after Phase 2
Stage B  continued
           Phase 3a  Production context .......... ⬜
           Phase 3b  OEE and efficiency KPIs ..... ⬜
           Phase 3c  SPC ......................... ⬜  (OEE first, by decision)
           Phase 4   Scale and analytics ......... ⬜
           Phase 5   Ergonomics and AI ........... ⬜
Stage D  Going public (parallel track) ........... ⬜
```

Every build phase follows the same loop, like a small engineering project:

1. **Detailed design** — the SQL migrations, flows or screens for the phase,
   reviewed before building (the way an I/O list is checked before panel build).
2. **Build** — in small steps, each committed to Git.
3. **Test** — automated tests plus the phase's failure drills (Architecture
   Overview §17).
4. **Exit check** — the phase's exit criterion (Overview §18) is demonstrated.
5. **Release** — a Git tag (`v0.1` for Phase 1, `v0.2` for Phase 2, …),
   this file updated.

## Stage A — Foundations ✅

| Step | Result | Where |
|---|---|---|
| A1 Vision, scope, requirements | ✅ Defined | Architecture Overview §1–3 |
| A2 Architecture and decisions | ✅ Overview v0.4.1; ADR-0001 to ADR-0012 accepted, with dated amendments | `docs/` |
| A3 Payload contracts | ✅ 9 JSON Schemas, 33 example payloads, validation script | `schemas/`, `tests/schemas/`, `tools/` |
| A4 Hardened environment | ✅ Two-command install; secrets generated into `.env`; pinned images; localhost-only ports; Node-RED login; MQTT ACL. Verified on the Windows 11 laptop on 2026-10-21 | `deploy/` |
| A5 Way of working | ✅ GitHub repository (private), Claude Project instructions, this file | — |

Design topics covered: information model and UNS (ADR-0001, 0004, 0005);
historian path and timestamps (ADR-0002, 0003); append-only operational
history (ADR-0006); stale-data signalling (ADR-0007); efficiency waterfall,
loss classification and work orders (ADR-0008 to 0010); SPC (ADR-0011).

## Stage B — Build in phases

### Phase 1 — Live data path ▶ (release v0.1)

Goal: one simulated line's values flow simulator → UNS → historian →
dashboard, driven only by rows in the model.

| Step | Content | Status |
|---|---|---|
| 1.1 Database design | Migration runner `tools/migrate.sh` (ADR-0012, runs on every start); migrations 001–005: naming rules with reserved names, audit log, plant hierarchy, units, `source`, `machine_property`, `plc_mapping`, `vw_runtime_model`, `hist.measurement` hypertables; example plant `acme` (`db/examples/`); ERD `docs/generated/erd.md`. Tested on PostgreSQL 16 (36 checks; TimescaleDB-specific clause to be confirmed on the laptop) | ▶ delivered, awaiting review |
| 1.2 OPC UA simulator | Microsoft OPC PLC simulator (MIT licence, `mcr.microsoft.com/iotedge/opc-plc`, pinned version) as an optional container; first `source` and `plc_mapping` rows point at it | ⬜ |
| 1.3 Generic ingest flow | Node-RED: load cache at startup, map by (source, address), normalise, validate, publish `{v, ts, q, tss}`, insert into historian, quarantine unmapped values, runtime Last Will, source and cache status topics | ⬜ |
| 1.4 Dashboard, tests, release | Grafana trend from the historian; schema tests; payloads checked against `schemas/`; exit check; tag `v0.1` | ⬜ |

### Phase 2 — Robust and editable ⬜ (release v0.2)

Cache reload on model change (LISTEN/NOTIFY); `_meta` topics and retained-topic
cleanup; deadband and maximum publish interval; `bad` quality on source loss;
batched historian writer with store-and-forward; NocoDB as model editor; broker
TLS; load test (2,000 msg/s); broker-kill and PLC-disconnect drills.

### Stage C — Plant pilot ⬜ (after Phase 2)

The stack on a plant server, reading one real line (S7 or OPC UA), with IT/OT
network approval and the Docker licensing decision made. Runs alongside the
existing plant tools; nothing is replaced yet.

### Phase 3a — Production context ⬜ (release v0.3)

Machine states (append-only) and `unknown` handling; runtime heartbeat and
startup reconciliation; good and reject counts; products and rated speeds;
shift calendar; work orders; reason catalogue; operator whiteboard.
Exit: one line's whiteboard matches the plant's existing tool hour by hour.

### Phase 3b — OEE and efficiency KPIs ⬜ (release v0.4)

Time ledger; GE, OEE with A·P·Q, Downtime, MTBF, MTTR, CU, LU, TEEP; KPIs on
the UNS; Grafana operations and management dashboards; disaster-recovery
rehearsal.

### Phase 3c — SPC ⬜ (release v0.5)

Characteristics, specifications, sampling plans, sample-entry screen, inline
subgrouping, frozen control limits, rule evaluation, control charts and
capability. Depends only on 3a; OEE (3b) comes first by decision of
2026-10-21.

### Phases 4 and 5 — later ⬜

Phase 4: dashboards generated from the model, Python analytics framework,
semantic relationships. Phase 5: custom Node-RED nodes, REST API, AI assistant
over the model and historian.

## Stage D — Going public ⬜ (parallel track)

Must be complete before the repository is made public:

- [ ] Employer policy on open-sourcing work developed for or at the site (blocking)
- [ ] NocoDB licence checked; licence table in Overview §12 confirmed
- [ ] KPI terminology checked against ISO 22400-2; definitions presented as OFM's own
- [ ] Fresh-clone install tested on a second machine, ideally by someone new
- [ ] Root `README.md` written for newcomers, pointing to the two-command install
- [ ] Git history checked for the earlier enterprise example name; rewrite or squash decided

## Next actions

1. Jarek applies the step 1.1 package (`docker compose up -d`), loads the
   example plant, and reviews the tables in NocoDB and the ERD.
2. Review comments become a new migration (006) — the applied ones are never
   edited.
3. Step 1.2: add the OPC UA simulator; confirm the example plant's NodeIds and
   scaling against it.

## Open questions

Numbers are stable; answered questions are removed rather than renumbered.

| # | Question | Needed by |
|---|---|---|
| 2 | Docker Desktop licence vs. Docker Engine directly in WSL2 or on a Linux server | Plant pilot |
| 3 | Employer policy on open-sourcing work developed for or at the site | Going public |
| 4 | NocoDB current licence | Going public |
| 5 | Runtime heartbeat interval: 60 s assumed (ADR-0006) | Phase 3a |
| 6 | Default `max_publish_interval_ms`: 60 000 assumed (ADR-0007) | Phase 2 |
| 7 | Minor-stop threshold per line: 5 min assumed (ADR-0009) | Phase 3a |
| 8 | Source of good and reject counts per line: PLC counters, or manual reject entry | Phase 3a |
| 9 | Source of rated speeds, shift calendar and schedule (manual first; ERP/SAP later) | Phase 3a |
| 10 | Ramp-up after a changeover: inside the changeover window, or speed loss (ADR-0010) | Phase 3a |
| 11 | Defined capacity per line for CU: manual or from ERP/SAP | Phase 3b |
| 12 | Verify KPI terminology against ISO 22400-2 (ADR-0008) | Going public |
| 13 | Schemas still to write: machine state (3a), line KPIs (3b), state health (3a), SPC state (3c), `_cmd` write-back (when first needed) | Their phase |
| 14 | First SPC characteristics and their plans (pack weight, temper index?); how lab results arrive (manual entry or instrument interface) | Phase 3c |
| 15 | Does the OPC PLC simulator set OPC UA `SourceTimestamp` on its values, as ADR-0003 relies on? Verify in step 1.3 | Phase 1.3 |
| 16 | Example plant NodeIds (`ns=3;s=SpikeData` …) and scaling are provisional; confirm by browsing the simulator | Phase 1.2 |
| 17 | Historian compression and retention (columnstore off in Phase 1) and the 1-min/1-h continuous aggregates | Phase 2 |

## Known gaps and notes

- Pinned versions (2026-10-18): TimescaleDB 2.30.2-pg16, Mosquitto
  2.1.2-alpine, Node-RED 4.1.16 (Node 22), Grafana 13.2.4 (image
  `grafana/grafana`; `grafana/grafana-oss` is no longer updated), NocoDB
  2026.09.1. OPC PLC simulator to be pinned at 2.15.11 in step 1.2.
- Mosquitto 2.1 deprecates `password_file`/`acl_file` in favour of plugins
  (removal planned for 3.0). Migrate before any upgrade to 3.x.
- The installation has been run end-to-end on one machine only.
