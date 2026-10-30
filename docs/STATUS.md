# OFM — Status and development plan

*Updated: 2026-10-31. Update this file at the end of every working session.*

**▶ We are here: Phase 2, step 2.2 done — `_meta` topics and start-up
clean-up of stale topics (checks M1–M3 passed).** Next: step 2.3, deadband,
heartbeat republish and `bad` quality on source loss.

## The plan in one view

OFM is built in four stages. **Stage A** lays the foundations once. **Stage
B** builds the system in phases; each phase is useful on its own and ends with
a tested, tagged release. **Stage C** takes it into a plant. **Stage D**,
publishing it as open source, runs alongside.

```
Stage A  Foundations ............................. ✅ done
Stage B  Phase 1   Live data path ................ ✅ v0.1.1 (2026-10-30)
         Phase 2   Robust and editable ........... ▶ step 2.3 of 8
Stage C  Plant pilot (one real line) ............. ⬜  after Phase 2
Stage B  Phase 3a  Production context ............ ⬜
         Phase 3b  OEE and efficiency KPIs ....... ⬜
         Phase 3c  SPC ........................... ⬜
         Phase 3d  Food safety checks ............ ⬜
         Phase 3e  Traceability and inventory .... ⬜
         Phase 4   Scale and analytics ........... ⬜
         Phase 5   Ergonomics and AI ............. ⬜
Stage D  Going public (parallel track) ........... ⬜
```

Every phase follows the same loop: **detailed design** (reviewed by Jarek) →
**build** in small committed steps → **test** (automated tests and failure
drills, Overview §17) → **exit check** (Overview §18) → **release** (Git tag).

Legend: ✅ done · ▶ current · ⬜ to do. Step numbers in later phases are the
current plan and may be refined when the phase starts.

## Stage A — Foundations ✅

| Step | What | Status |
|---|---|---|
| A1 | Vision, scope, requirements (Overview §1–3) | ✅ |
| A2 | Architecture and decisions: Overview v0.6.1, MES coverage map, ADR-0001 to ADR-0017 | ✅ |
| A3 | Payload contracts: 9 JSON Schemas, 33 example payloads, validation script | ✅ |
| A4 | Hardened environment: two-command install, secrets in `.env`, localhost-only ports, logins, MQTT access rules | ✅ |
| A5 | Way of working: GitHub repository, Claude Project, this file | ✅ |

## Stage B — Phase 1: Live data path ✅ (release v0.1)

Goal: one simulated line's values flow simulator → UNS → historian →
dashboard, driven only by rows in the model.

| Step | What | Status |
|---|---|---|
| 1.1 | **Database:** migration runner (ADR-0012); tables for the plant model and historian (migrations 001–005); example plant `acme`; ERD | ✅ 2026-10-21 |
| 1.2 | **Simulator and model editor:** OPC UA simulator in the stack; Mathesar replaces NocoDB (ADR-0013, trial passed); personal logins; passwords from `.env` (migrations 006–007) | ✅ 2026-10-25 |
| 1.3 | **OFM Node-RED image:** Node-RED with OPC UA, S7, PostgreSQL and dashboard nodes built in at pinned versions, so no internet is needed at a plant; check flow that reads the simulator | ✅ 2026-10-25: all five simulator nodes read; namespace 3; source timestamps present |
| 1.4 | **Ingest flow:** load the model from `vw_runtime_model` at startup; translate `nsu=` addresses to namespace numbers; subscribe; scale; validate; publish `{v, ts, q, tss}` to the UNS; insert into the historian; quarantine unmapped values; runtime, source and cache status topics | ✅ 2026-10-25: live on the laptop; values, status topics and historian verified |
| 1.5 | **First dashboard:** `OFM · Live data`, model-driven (properties, units, alarm limits from the model), provisioned from `deploy/grafana/dashboards/` | ✅ 2026-10-26: on the laptop; alarm-limit test passed (line moved within one refresh, no restart) |
| 1.6 | **Tests and release:** `docker compose run --rm test` runs four suites (schemas, flow, database, live) in OFM's Node-RED image, offline; exit check with drills D1–D4 (`tests/README.md`); tag `v0.1` | ✅ 2026-10-27: exit check passed; `v0.1` tagged |

### Phase 1 exit check

Criterion (Overview §18): one simulated line's values flowing OPC UA simulator
→ UNS → historian → dashboard from model configuration only.

| Check | Result |
|---|---|
| Automated: `docker compose run --rm test` | ✅ 2026-10-27 |
| D1 PLC lost and back | ✅ 2026-10-27 |
| D2 Runtime crash (Last Will) | ✅ 2026-10-27 |
| D3 Database lost and back (UNS keeps flowing) | ✅ 2026-10-27 |
| D4 Property added in Mathesar only, appears end to end | ✅ 2026-10-27 |

### Step 1.7 — Real PLCs on the bench (release v0.1.1)

Added after the `v0.1` release, before Phase 2: Siemens S7 and Rockwell
EtherNet/IP acquisition by model-driven polling (ADR-0018, migration 008,
image `ofm/node-red:4.1.16-ofm.3`), so OFM can read controllers without
OPC UA. Guide: deploy README section 5.

| Check | Result |
|---|---|
| S7-1200 CPU 1212C (`s7`, rack 0 slot 1): tags read end to end, unplug drill | ✅ 2026-10-30 |
| S7-300 family, IM151-8 PN/DP CPU (`s7`, rack 0 slot 2): tags read end to end, unplug drill | ✅ 2026-10-30 |
| CompactLogix 1769-L16ER (`ethernetip`, slot 0): tags read end to end, unplug drill | ✅ 2026-10-30 |
| `docker compose run --rm test` with all three PLCs in the model; tagged `v0.1.1` | ✅ 2026-10-30 |

## Stage B — Phase 2: Robust and editable ▶ (release v0.2)

Goal: ready for the plant pilot — model changes without restarts, honest data
quality, no lost history, encrypted traffic. Decisions still open, with their
defaults (assumptions until decided): disk queue limit 2 GB, oldest dropped
with an alarm (2.4); raw data 90 days, 1-min/1-h averages 5 years — check
food-safety retention with QA (2.5); MQTT encrypted, PostgreSQL not yet (2.6).

| Step | What | Status |
|---|---|---|
| 2.1 | Model edits reach the runtime within a second, without restart: database triggers notify (migration 009), the runtime listens, reloads, clears topics and sources that no longer exist, and reconnects only changed sources; Grafana's Property list re-reads the model | ✅ 2026-10-30: on the laptop, tests and checks R1–R5 passed |
| 2.2 | `_meta` topics: each value's unit, limits, description and property ID published next to it, republished when they change; at start-up, stale retained topics left by renames while the runtime was stopped are cleared | ✅ 2026-10-31: on the laptop, tests and checks M1–M3 passed |
| 2.3 | Deadband and maximum publish interval; `bad` quality and source status on connection loss (ADR-0007) | ⬜ |
| 2.4 | Batched historian writer with store-and-forward disk queue (ADR-0002) | ⬜ |
| 2.5 | Historian housekeeping: compression, retention, 1-minute and 1-hour aggregates | ⬜ |
| 2.6 | Broker encryption (TLS) | ⬜ |
| 2.7 | Offline install bundle: all images and the repository for a network without internet | ⬜ |
| 2.8 | Load test (2,000 values/s) and failure drills; release `v0.2` | ⬜ |

## Stage C — Plant pilot ⬜ (after Phase 2)

| Step | What |
|---|---|
| C1 | Plant server, IT/OT network approval, Docker licensing decision |
| C2 | Install from the offline bundle |
| C3 | Connect one real line (S7 or OPC UA) and model its tags in Mathesar |
| C4 | Run alongside the existing plant tools for an agreed period; review |

## Stage B — Phase 3a: Production context ⬜ (release v0.3)

| Step | What |
|---|---|
| 3a.1 | Material master (ADR-0014), rated speeds, shift calendar and schedule |
| 3a.2 | Machine states, append-only, with `unknown`, heartbeat and startup reconciliation (ADR-0006) |
| 3a.3 | Good and reject counts |
| 3a.4 | Work orders and changeovers (ADR-0010) |
| 3a.5 | Reason catalogue mapped to the loss waterfall (ADR-0009) |
| 3a.6 | Operator whiteboard with per-person sign-in |
| 3a.7 | Exit check against the plant's existing whiteboard tool; release `v0.3` |

## Stage B — Phase 3b: OEE and efficiency KPIs ⬜ (release v0.4)

| Step | What |
|---|---|
| 3b.1 | Time ledger: every minute classified into the loss waterfall (ADR-0008, ADR-0009) |
| 3b.2 | KPI views: GE, OEE with A·P·Q, Downtime, MTBF, MTTR, CU, LU, TEEP |
| 3b.3 | Live KPIs published to the UNS |
| 3b.4 | Grafana operations dashboards |
| 3b.5 | Grafana management dashboards (week, month, year) |
| 3b.6 | Disaster-recovery rehearsal; release `v0.4` |

## Stage B — Phase 3c: SPC ⬜ (release v0.5)

| Step | What |
|---|---|
| 3c.1 | Characteristics, specifications and sampling plans (ADR-0011) |
| 3c.2 | Sample-entry screen and overdue alerts (shared later by food safety checks) |
| 3c.3 | Samples formed automatically from inline properties (checkweigher) |
| 3c.4 | Frozen control limits, rule evaluation, SPC state on the UNS |
| 3c.5 | Control charts and capability in Grafana; release `v0.5` |

## Stage B — Phase 3d: Food safety checks ⬜ (release v0.6)

| Step | What |
|---|---|
| 3d.1 | Check definitions: CCPs and prerequisite programmes (ADR-0015) |
| 3d.2 | Check entry, corrective actions, second-person verification |
| 3d.3 | Automatic deviations from instrument-monitored CCPs |
| 3d.4 | Overdue and open checks on the UNS and dashboards |
| 3d.5 | Parallel run with paper records; release `v0.6` |

## Stage B — Phase 3e: Traceability and inventory ⬜ (release v0.7)

| Step | What |
|---|---|
| 3e.1 | ADR on mixing rules for continuous processes |
| 3e.2 | Material lots, movements and storage equipment (ADR-0014) |
| 3e.3 | Scanning and entry screens on the floor |
| 3e.4 | Movements from PLC totals (flow meters, scales) |
| 3e.5 | Stock, genealogy, recall-scope and mass-balance views |
| 3e.6 | Mock recall from OFM data; release `v0.7` |

## Stage B — Phases 4 and 5 ⬜ (later)

| Step | What |
|---|---|
| 4.1 | Dashboards generated from the model |
| 4.2 | Alarm and event history |
| 4.3 | Energy KPIs |
| 4.4 | Python analytics framework |
| 4.5 | Semantic relationships between machines |
| 5.1 | Custom Node-RED nodes with model-driven dropdowns |
| 5.2 | REST API over the model |
| 5.3 | AI assistant over the model and historian |

## Stage D — Going public ⬜ (parallel track)

Must be complete before the repository is made public:

- [ ] Employer policy on open-sourcing work developed for or at the site (blocking)
- [ ] Licence table in Overview §12 confirmed for every component (NocoDB dropped over its 2026 licence change)
- [ ] KPI terminology checked against ISO 22400-2; definitions presented as OFM's own
- [ ] Fresh-clone install tested on a second machine, ideally by someone new
- [ ] Root `README.md` written for newcomers, pointing to the two-command install
- [ ] Git history checked for the earlier enterprise example name; rewrite or squash decided

## Next actions

1. Step 2.3: deadband, heartbeat republish (max publish interval) and `bad`
   quality on source loss, for OPC UA, S7 and EtherNet/IP alike (ADR-0007).

## Open questions

Numbers are stable; answered questions are removed rather than renumbered.

| # | Question | Needed by |
|---|---|---|
| 2 | Docker Desktop licence vs. Docker Engine directly in WSL2 or on a Linux server | Plant pilot |
| 3 | Employer policy on open-sourcing work developed for or at the site | Going public |
| 5 | Runtime heartbeat interval: 60 s assumed (ADR-0006) | Phase 3a |
| 6 | Default `max_publish_interval_ms`: 60 000 assumed (ADR-0007) | Phase 2 |
| 7 | Minor-stop threshold per line: 5 min assumed (ADR-0009) | Phase 3a |
| 8 | Source of good and reject counts per line: PLC counters, or manual reject entry | Phase 3a |
| 9 | Source of rated speeds, shift calendar and schedule (manual first; ERP/SAP later) | Phase 3a |
| 10 | Ramp-up after a changeover: inside the changeover window, or speed loss (ADR-0010) | Phase 3a |
| 11 | Defined capacity per line for CU: manual or from ERP/SAP | Phase 3b |
| 12 | Verify KPI terminology against ISO 22400-2 (ADR-0008) | Going public |
| 13 | Schemas still to write: machine state (3a), line KPIs (3b), state health (3a), SPC state (3c), food safety check state (3d), `_cmd` write-back (when first needed) | Their phase |
| 14 | First SPC characteristics and their plans (pack weight, temper index?); how lab results arrive (manual entry or instrument interface) | Phase 3c |
| 17 | Historian compression and retention (columnstore off in Phase 1) and the 1-min/1-h continuous aggregates | Phase 2 |
| 19 | Offline install bundle: script that saves all pinned images and the repository for transfer to an isolated network | Phase 2 |
| 20 | Phase 3a must build `config.material` (with `material_type`), not `product` (ADR-0014) | Phase 3a |
| 21 | Food safety: which checks first; who verifies; electronic records replacing or accompanying paper under the site's certification scheme | Phase 3d |
| 22 | Traceability: lot identification on the floor, tipping points, mass-balance tolerance, mixing-attribution rules (own ADR) | Phase 3e |
| 23 | Modbus driver: every current `node-red-contrib-modbus` release downloads part of its code from a third-party package server; choose a driver when the first Modbus device needs it | First Modbus device |
| 24 | S7 at the plant: is PUT/GET access acceptable to the PLC owners, or must S7-1200/1500 CPUs be read through their OPC UA server (S7-1200 from firmware 4.4, with runtime licence)? | Plant pilot |

## Known gaps and notes

- Pinned versions: TimescaleDB 2.30.2-pg16, Mosquitto 2.1.2-alpine, Grafana
  13.2.4 (`grafana/grafana`; `grafana-oss` is no longer updated), Mathesar
  0.12.0, OPC PLC simulator 2.15.11, Node-RED 4.1.16 (Node 22) built as
  `ofm/node-red:4.1.16-ofm.3` with node-opcua 2.160.0, @st-one-io/nodes7
  1.1.2, st-ethernet-ip 2.7.5, node-red-contrib-opcua 0.2.355,
  node-red-contrib-postgresql 0.16.2, node-red-contrib-s7 3.1.3,
  @flowfuse/node-red-dashboard 1.33.0.
- The OPC UA palette node accepts only `ns=<number>` addresses and is built
  around fixed per-connection configuration; OFM's acquisition therefore uses
  the node-opcua library directly (ADR-0017), translating `nsu=` addresses
  after reading the server's namespace table.
- Step 1.4 was tested on a local replica (PostgreSQL 16, Mosquitto with OFM's
  access rules, a stand-in OPC UA server): all published messages valid
  against `schemas/`; drills passed for PLC loss and return (offline in ~1 s,
  online and values resumed in ~3 s), runtime crash (Last Will `offline`),
  and database unavailable at start (model loaded 6 s after it returned).
- The official Node-RED image passes its `FLOWS` variable to Node-RED on the
  command line, which overrides `flowFile` in `settings.js`; OFM therefore sets
  `FLOWS` (found on Jarek's laptop 2026-10-25; the local test had started
  Node-RED without it).
- Example plant on the real simulator (2026-10-25): chocolate_temp 30.7–32.5 °C,
  air_temp 10.7–12.0 °C, running alternating, cycle_count rising — all
  realistic. hopper_level is mapped to `PositiveTrendData`, which climbs
  forever, so it is permanently `uncertain` (out of its 0–100 % range); kept
  deliberately as a live demonstration of validation.
- The test runner uses libraries already in the Node-RED image (ajv for JSON
  Schema, mqtt, pg), so it needs no internet; after any change to
  `deploy/nodered/Dockerfile`, run the tests. It replaced the Python schema
  check (`tools/validate_schemas.py`), which needed pip and the internet.
- Step 1.6 was tested on the local replica: schemas, flow and live suites
  pass; database suite passes except the two checks the replica cannot meet
  (no TimescaleDB; migration 005 adapted for it). Drill D3 confirmed there:
  UNS kept flowing with the database stopped; historian resumed on restart.
  On Jarek's laptop (2026-10-27) all suites and drills D1–D4 passed.
- Step 1.7 was tested on the local replica against stand-in controllers
  (snap7 server for S7, cpppo for EtherNet/IP): all address types in the
  README table that the stand-ins offer, report by exception, wrong
  addresses skipped with a warning, controller loss and recovery (offline
  within 3 s, online again after the back-off). On Jarek's bench
  (2026-10-29/30) all three PLCs were programmed from deploy README section 5
  and read end to end; with the OFM laptop disconnected from the network,
  data stopped and resumed a few seconds after reconnecting. Corrections from
  the bench run: area and line added to the table order (README 5.1); the
  CompactLogix rungs given in the rung editor's text format (README 5.3).
- Polled sources: when a PLC is lost, its values keep their last quality
  until Phase 2 step 2.3, as for OPC UA.
- Step 2.1 was tested on the local replica with OPC UA, S7 and EtherNet/IP
  stand-ins: reload 0.3–0.4 s after a committed change; a renamed property's
  old topic cleared; scaling changes applied without reconnecting; an address
  change reconnected only that PLC; after a database restart the listener
  reconnected and reloaded. Grafana's Property list refresh (on time range
  change, i.e. every auto-refresh) was not tested here.
- Step 2.2 was tested on the local replica: `_meta` for all 15 properties,
  valid against the schema; a stale value and `_meta` planted on the broker
  while the runtime was stopped were cleared at start-up, a non-OFM retained
  message beside them was left alone.
- No automatic test run on GitHub (CI) yet; the runner's exit code is ready
  for it. Candidate for Stage D.
- Mosquitto 2.1 deprecates `password_file`/`acl_file` in favour of plugins
  (removal planned for 3.0). Migrate before any upgrade to 3.x.
- The installation has been run end-to-end on one machine only.
