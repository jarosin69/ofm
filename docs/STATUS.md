# OFM — Status and development plan

*Updated: 2026-11-02. Update this file at the end of every working session.*

**▶ We are here: Phase 3a, detailed design for review.** Decided
2026-11-02: before the plant pilot, management sees OFM on a **simulated
packing line** (six machines, work orders, OEE and downtime) built with the
real Phase 3a features; the simulator ships with OFM as its demo, with a
selectable backend per machine (simulated OPC UA, S7-300, S7-1200,
CompactLogix). Design accepted 2026-11-02: ADR-0023 (the simulator),
ADR-0024 (starved and blocked time), ADR-0025 (frozen data),
`demo/packing-line/README.md`. **Step 3a.1 built:** part 1 (line engine,
six simulated OPC UA PLCs, profile `demo`; P1–P5 passed on the laptop
2026-11-02) and part 2 (control panel, presets; P7–P8 passed on the
laptop 2026-11-03; P9 found the product back at mix250 after a changeover
— cause not found, see notes; added: changeover minutes, *New run*,
"Operating the simulator" in the demo guide, section 13); next: P9–P11,
then step 3a.2. Stage C
decisions prepared and still to accept: ADR-0020, ADR-0021, ADR-0022.

## The plan in one view

OFM is built in four stages. **Stage A** lays the foundations once. **Stage
B** builds the system in phases; each phase is useful on its own and ends with
a tested, tagged release. **Stage C** takes it into a plant. **Stage D**,
publishing it as open source, runs alongside.

```
Stage A  Foundations ............................. ✅ done
Stage B  Phase 1   Live data path ................ ✅ v0.1.1 (2026-10-30)
         Phase 2   Robust and editable ........... ✅ v0.2 (2026-11-02)
Stage B  Phase 3a  Production context and OEE
                   on the simulated line ......... ▶ design
Stage C  C0  Management demo ..................... ⬜ after v0.3
         C1–C4 Plant pilot (one real line) ...... ▶ C1 decisions prepared
Stage B  Phase 3b  Remaining KPIs, management views ⬜
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

## Stage B — Phase 2: Robust and editable ✅ v0.2 (2026-11-02)

Goal: ready for the plant pilot — model changes without restarts, honest data
quality, no lost history, encrypted traffic. Decided (2026-10-31): disk
queue limit 10 GB, compressed, configurable in `.env`, oldest dropped and
reported when full (2.4); retention raw data 1 year, 1-min/1-h averages
5 years, configurable in `.env` (2.5; to be confirmed against food-safety
record requirements with QA); encryption for every connection from another
computer — MQTT over TLS and HTTPS for the three web pages, the database
local to the server — with certificates from OFM's own certificate
authority, plant IT certificates as a drop-in (2.7, ADR-0019).

| Step | What | Status |
|---|---|---|
| 2.1 | Model edits reach the runtime within a second, without restart: database triggers notify (migration 009), the runtime listens, reloads, clears topics and sources that no longer exist, and reconnects only changed sources; Grafana's Property list re-reads the model | ✅ 2026-10-30: on the laptop, tests and checks R1–R5 passed |
| 2.2 | `_meta` topics: each value's unit, limits, description and property ID published next to it, republished when they change; at start-up, stale retained topics left by renames while the runtime was stopped are cleared | ✅ 2026-10-31: on the laptop, tests and checks M1–M3 passed |
| 2.3 | Deadband (opt-in per property; 0 = every value, for SPC) and heartbeat republish at the maximum publish interval; all values of a lost source republished `bad` at once — for OPC UA, S7 and EtherNet/IP alike (ADR-0007) | ✅ 2026-10-31: on the laptop, H1–H3 passed |
| 2.4 | Batched historian writer with compressed store-and-forward disk queue (10 GB, `.env`), status on `ofm/_system/historian/…`; addresses a PLC refuses published `v: null, q: bad` (ADR-0002, ADR-0007) | ✅ 2026-10-31: on the laptop, S1–S3 passed (S1 after migration 010) |
| 2.5 | Historian housekeeping: compression after 7 days; 1-minute and 1-hour averages (avg, min, max, worst quality); retention from `.env` (raw 1 year, averages 5 years); long-range charts read the averages (migration 011) | ✅ 2026-10-31: on the laptop, K1–K3 passed, all 227 checks pass |
| 2.6 | Runtime starts without the database: it keeps a copy of the last model on disk and starts from it when the database cannot be reached (added 2026-10-31, found in check S3; ADR-0001 amendment) | ✅ 2026-10-31: installed and pushed on the laptop |
| 2.7 | Encryption (TLS) for every connection from another computer: MQTT on 8883, HTTPS for Grafana, Mathesar and the Node-RED editor through a Caddy front door; OFM's own certificate authority, renewed automatically; plant IT certificates importable; open to the network with one `.env` setting (ADR-0019) | ✅ 2026-11-01: on the laptop, T1–T4 passed (Grafana over HTTPS from a second laptop) |
| 2.8 | Offline install bundle (`tools/make-bundle.ps1`): every pinned image, the repository at one commit, checksums, load scripts for Windows and Linux; no component contacts the internet by itself (Node-RED, Grafana, TimescaleDB telemetry off; Mathesar's usage data unticked); `deploy` test suite | ✅ 2026-11-01: on the laptop, O1–O3 passed (offline reinstall: images identical, data kept) |
| 2.9 | Load test (2,000 values/s) and failure drills: a second OPC PLC simulator (`opcplc-load`, profile `loadtest`) feeding a removable test line (`migrate loadtest` / `loadtest-remove`); opt-in suites `load` (rate, delay, historian completeness) and `watch` (drill recorder); dashboard shows one line at a time; release `v0.2` | ✅ 2026-11-02: exit check passed; tagged `v0.2` |

### Phase 2 exit check

Criterion (Overview §18): model edit visible in the runtime within a second;
broker-kill and PLC-disconnect drills pass; 2,000 values per second
sustained. Procedure: tests/README, step 2.9.

| Check | Result |
|---|---|
| Automated: `docker compose run --rm test` | ✅ 2026-11-02, after removing the load-test line (only the two intentionally wrong bench addresses fail) |
| R1–R5, M1–M3, H1–H3, S1–S3, K1–K3, B1–B3, T1–T4, O1–O4 (steps 2.1–2.8) | ✅ 2026-10-30 … 2026-11-01 |
| L1 2,000 values/s for 10 minutes (`test load`) | ✅ 2026-11-02: all 10 checks; median 2,000/s, worst 10 s 1,892/s; delay median 0.7 s, 99 % within 1.1 s; 1,132,000 UNS values = 1,132,000 historian rows |
| L2 CPU and memory under load (`docker stats`) | ✅ 2026-11-02: Node-RED 35 % of one core, 427 MiB; Mosquitto 10 %, 8 MiB; TimescaleDB 10 %, 255 MiB; Grafana 1 %, 497 MiB; load simulator 3.5 % |
| L3 ceiling (optional) | not run |
| X1 broker down — no historian gap | ✅ 2026-11-02 (second run, after the broker fix): UNS gap 35 s, historian gaps none, lost 0. First run ❌: the broker did not come back (see notes) |
| X2 database down — no gap anywhere | ✅ 2026-11-02: about 1.5 min down, 121,057 rows buffered and written, no gaps, lost 0 |
| X3 runtime crash — loss at most one second | ✅ 2026-11-02: gap 32 s, lost 0 |
| X4 runtime restart — no loss | ✅ 2026-11-02: gap 6 s, 513 rows saved on stop, lost 0 |
| X5 PLC lost and back | ✅ 2026-11-02: source offline 35 s, back by itself, lost 0 |
| X6 data path restart | ✅ 2026-11-02: gap 6 s, everything back by itself, lost 0 |

## Stage C — Plant pilot ▶

Goal: OFM running on a plant server, reading one real line, alongside the
existing plant tools, without any risk to production. Server requirements,
networks, preparation, checks and pilot backups: deploy README section 7.

| Step | What | Status |
|---|---|---|
| C0 | Management demo on the simulated line, after `v0.3`: presentation, live demo (line calibrated to the real packing line's figures), recorded backup; the decision to go ahead with C1–C4 | ⬜ |
| C1.1 | Docker and operating system: plant servers on Ubuntu Server 26.04 LTS with Docker Engine (ADR-0020); the laptop keeps Docker Desktop for development | ▶ ADR proposed 2026-11-02 |
| C1.2 | Latency target: 2 s for 95 % at default read settings, OFM's own share < 250 ms (ADR-0022); load-test threshold 2.0 s | ▶ ADR proposed 2026-11-02 |
| C1.3 | Pilot line and its controllers chosen (question 31); S7 access agreed with the PLC owners (ADR-0021, question 24); pilot duration and success criteria agreed (question 32) | ⬜ |
| C1.4 | Server: VM or industrial PC to deploy README 7.1; networks and firewall rules (7.2) approved by plant IT and OT; how Docker is installed (question 30) | ⬜ |
| C1.5 | *Only if the PLC owners require OPC UA:* OPC UA security in the acquisition client — signed and encrypted sessions, user name and password from `.env`, a fixed client certificate kept in a volume, server certificates trusted explicitly (ADR-0017 follow-up) | ⬜ |
| C2.1 | Dry run on a Linux VM (e.g. Hyper-V on the laptop): offline bundle, deploy README 7.3–7.5, checks C1–C8 — the first end-to-end run on Linux with the real images | ⬜ |
| C2.2 | Plant server prepared (7.3), OFM installed from the bundle (7.4), checks C1–C8 (7.5), nightly model backup (7.7) | ⬜ |
| C3.1 | In the PLC, by its owner: export data block (or OPC UA interface); firewall rule for port 102 | ⬜ |
| C3.2 | Model the line in Mathesar (deploy README 5.1); checks 5.6 | ⬜ |
| C3.3 | Measure OFM's own latency on a polled source (ADR-0022); disk growth after one week (7.6) against the estimate | ⬜ |
| C4 | Run alongside the existing plant tools for the agreed period; review against the criteria of C1.3 | ⬜ |

## Stage B — Phase 3a: Production context and OEE on the simulated line ▶ (release v0.3)

Goal: machine states, counts, work orders, reasons, OEE and downtime,
built as real OFM features and proven against a simulated packing line whose
true KPIs are known (ADR-0023, ADR-0024; design in
`demo/packing-line/README.md`). Brings forward the time ledger, OEE with
A·P·Q, Downtime, MTBF, MTTR, live KPIs and the operations dashboard from
Phase 3b. Docker Desktop on the laptop for this phase (development only).

| Step | What | Status |
|---|---|---|
| 3a.0 | Detailed design reviewed: ADR-0023, ADR-0024, ADR-0025, demo README (decisions in its section 11) | ✅ 2026-11-02, ADRs accepted |
| 3a.1 | Simulator: line engine, six simulated OPC UA PLCs, `line.json`, Compose profile `demo`, HTTPS port 1881 (part 1); control panel with presets and commands (part 2) | ▶ part 1 ✅ 2026-11-02 (P1–P5 on the laptop); part 2 built 2026-11-02, tested on the replica; P7–P10 to do |
| 3a.2 | Production context and demo model: `config.material` with `material_type` (ADR-0014), rated speeds per line, shift calendar, flow order (`feeds`), constraint machine, minor-stop threshold; `migrate demo` / `demo-remove` | ⬜ |
| 3a.3 | Machine states (ADR-0006): property roles, state rules in the model, state events, `unknown`, runtime heartbeat, startup reconciliation, `.../state` topic; frozen-data detection by heartbeat property (ADR-0025), drills F1 (simulator stopped, PLC still answering) and F2 (S7 CPU in STOP) | ⬜ |
| 3a.4 | Counts: count roles, counter increments with reset handling, line good and reject | ⬜ |
| 3a.5 | Work orders (ADR-0010): events, `.../workorder` topic; the simulator follows; auto-operator | ⬜ |
| 3a.6 | Reasons (ADR-0009, ADR-0024): catalogue, PLC fault code → reason, starved/blocked attribution, automatic *waiting for order* (Pos 7) for scheduled time without an active order | ⬜ |
| 3a.7 | Time ledger and KPI views: OEE with A·P·Q, Downtime, MTBF, MTTR; live line KPIs on the UNS | ⬜ |
| 3a.8 | Screens: OFM line view (drawn from the UNS; work orders; stops to code; per-person sign-in) and Grafana *Line OEE* | ⬜ |
| 3a.9 | Simulator, part 2: S7-300, S7-1200 and CompactLogix backends, PLC data block and tag files, `demo.set_machine_backend` | ⬜ |
| 3a.10 | Ground truth and `demo` test suite; demo in the offline bundle; demo guide; exit check (OFM's KPIs agree with the simulator, on OPC UA and on each PLC family); release `v0.3` | ⬜ |

## Stage B — Phase 3b: Remaining KPIs and management views ⬜ (release v0.4)

The time ledger, OEE with A·P·Q, Downtime, MTBF, MTTR, live KPIs and the
operations dashboard moved to Phase 3a (2026-11-02).

| Step | What |
|---|---|
| 3b.1 | KPI views: GE, CU, LU, TEEP |
| 3b.2 | Grafana management dashboards (week, month, year) |
| 3b.3 | Disaster-recovery rehearsal; release `v0.4` |

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

1. Step 3a.1 part 2 on the laptop: checks P7–P10 (tests/README, Phase 3a);
   then step 3a.2, production context and the demo model.
2. Accept or change ADR-0020, ADR-0021 and ADR-0022 (Stage C; may wait for
   the management decision at C0).
3. Update the Claude Project instructions: model editor is Mathesar (not
   NocoDB, ADR-0013); secrets live in deploy/.env, the Mosquitto password
   file (generated) and the Docker volume `certs`.

## Open questions

Numbers are stable; answered questions are removed rather than renumbered.

| # | Question | Needed by |
|---|---|---|
| 2 | Docker Desktop licence vs. Docker Engine directly in WSL2 or on a Linux server — **ADR-0020 proposed:** plant servers on Linux with Docker Engine; laptops any Docker with Engine and Compose; Jarek's laptop keeps Docker Desktop for development. Removed when accepted | Plant pilot |
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
| 20 | Phase 3a must build `config.material` (with `material_type`), not `product` (ADR-0014) | Phase 3a |
| 21 | Food safety: which checks first; who verifies; electronic records replacing or accompanying paper under the site's certification scheme | Phase 3d |
| 22 | Traceability: lot identification on the floor, tipping points, mass-balance tolerance, mixing-attribution rules (own ADR) | Phase 3e |
| 23 | Modbus driver: every current `node-red-contrib-modbus` release downloads part of its code from a third-party package server; choose a driver when the first Modbus device needs it | First Modbus device |
| 24 | S7 at the plant: is PUT/GET access acceptable to the PLC owners, or must S7-1200/1500 CPUs be read through their OPC UA server (S7-1200 from firmware 4.4, with runtime licence)? **ADR-0021 proposed:** use PUT/GET if already on; otherwise only with read-only OFM, a port-102 firewall rule, an export data block and a change record; OPC UA if required, after step C1.5. Needs the PLC owners' answer | Plant pilot (C1.3) |
| 25 | Remote database access (Power BI, DBeaver or Python on another computer): when needed, PostgreSQL over TLS with the same certificates, read-only role `ofm_reader` (ADR-0019 follow-up) | First remote database client |
| 26 | UNS latency target (Overview §3.2: < 250 ms typical) vs. how often sources are read: with the example OPC UA settings (sampling 0.5 s, publishing 1 s) values reach the UNS about 1.3 s after their device time; with 0.1 s about 0.3 s, at more load on the PLC. Keep 1 s as the default and relax the target to about 1–2 s for monitoring, or set faster intervals per source where needed? **ADR-0022 proposed:** defaults stay; target 2 s for 95 % at default settings, OFM's own share < 250 ms; faster per source only for a named need. Removed when accepted | Plant pilot |
| 28 | Historian backup during the pilot: VM backup (if a VM), or accept no historian backup until Phase 3b (the pilot runs alongside existing tools; the model is backed up nightly) | C2.2 |
| 29 | Disk: the 1-minute averages are stored uncompressed and would take about three-quarters of the disk at plant scale (estimate, deploy README 7.1). Compress them (TimescaleDB columnstore on continuous aggregates, a new migration) or keep them shorter than 5 years? Decide with the measured growth from C3.3 | Before plant-wide use |
| 30 | Plant server: VM on plant IT's servers or an industrial PC near the line; who administers and patches it; Docker from IT's package mirror or as packages with the offline bundle | C1.4 |
| 31 | Pilot line: which line, which controllers (S7-1200/1500, S7-300, Logix, OPC UA) and roughly how many properties | C1.3 |
| 32 | Pilot: duration and success criteria (for example: values agree with the HMI/SCADA, no unexplained gaps, no effect on PLC scan or communication load, operators' and engineers' feedback) | C1.3 |

## Known gaps and notes

- Pinned versions: TimescaleDB 2.30.2-pg16, Mosquitto 2.1.2-alpine, Grafana
  13.2.4 (`grafana/grafana`; `grafana-oss` is no longer updated), Mathesar
  0.12.0, OPC PLC simulator 2.15.11, Caddy 2.11.7-alpine (HTTPS front door), Alpine 3.22 (runs
  `make-env.sh`; in the offline bundle),
  Node-RED 4.1.16 (Node 22) built as
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
- Step 2.3 was tested on the local replica: a static value republished at
  its interval (5 s in the test) with gateway time; with the S7 stand-in
  stopped, all its values were republished `bad` at once and repeated `bad`
  while it was out; restarted, values returned `good` within one poll.
- Step 2.4 was tested on the local replica: with the database stopped for
  32 s, 6 compressed queue files, status `buffering`; after the restart the
  queue drained within one tick and the historian had one row per second for
  every second of the outage (no gap); refused S7 and EtherNet/IP addresses
  published `v: null, q: bad`. Found by Jarek in S1: Grafana still showed the
  last good value, because the historian could not store a row without a
  value; corrected with migration 010 (NULL value allowed with quality bad)
  and a `stale` quality in the dashboard's latest-values table. The queue moved from the unused `sf-queue`
  volume to `/data/sfqueue` in the `nodered-data` volume (owned by the
  Node-RED user); the old volume can be removed with
  `docker volume rm ofm_sf-queue`.
- Step 2.5 was tested on a local TimescaleDB 2.30.2 (built from source, the
  version in the stack) — the first time the full migration series 001–011
  ran on real TimescaleDB outside Jarek's laptop: compression of a 10-day-old
  chunk (712 kB → 40 kB); late and replayed inserts into a compressed chunk
  (written once, no error); averages readable by `ofm_reader`, not by
  `ofm_config`; retention set from the environment, unchanged on a second run,
  too-short values refused; the chart query at raw, 1-minute and 1-hour
  resolution. Grafana's rendering was not tested here; on Jarek's laptop
  (K2) the min/max lines were correct but hard to read, and lines were drawn
  across periods without data. Corrected: points of a minute or longer with
  no data stay empty (TimescaleDB gap-filling), so lines break at gaps;
  min–max shown as a band; the `live` suite now checks that Grafana serves
  the repository's dashboard file. The first version of that correction
  failed in Grafana ("No data", red triangle): with Grafana's quoted time
  bounds, PostgreSQL picked the time-zone variant of `time_bucket_gapfill`;
  fixed with explicit casts. The `live` suite now runs every dashboard query
  with Grafana-style macros at three resolutions, which catches this.
- A property whose `max_publish_interval_ms` is longer than a minute and
  whose value does not change can show breaks on charts at 1-minute
  resolution (no row in those minutes).
- Rows written late by store-and-forward appear in the averages at the next
  refresh if they are less than 30 days old; older late rows need a manual
  `CALL refresh_continuous_aggregate(…)`.
- Step 2.9 was tested on the local replica (stand-in OPC UA server with the
  real node names, Node-RED, Mosquitto, TimescaleDB 2.30.2 on 2 CPU cores):
  2,000 values/s for 2 minutes and 6,000 values/s for 1 minute both passed
  every check — every UNS value in the historian, nothing buffered, all
  good; Node-RED at about 77 % of one core at 6,000/s. Delay device time →
  UNS: median 1.3 s with OPC UA sampling 0.5 s / publishing 1 s, 0.3 s with
  0.1 s / 0.1 s (open question 26). Drills under 2,000 values/s: broker down
  10–15 s → UNS gap of that length, no historian gap, nothing lost; database
  down 30 s → no gap anywhere, writer buffered and caught up; runtime killed
  → 20 s gap, 350 values lost (the writer's memory, under one second);
  runtime stopped gracefully → nothing lost (memory saved to the disk
  queue). Found and fixed on the way: the dashboard drew one chart per
  property for the whole plant (2,000 charts) — it now shows one line at a
  time; the drill recorder first reported false one-second gaps (a 1 Hz
  source drifting across second boundaries) — gaps are now judged on a
  3-second average; removing the test line while it was being read produced
  refused rows — removal now stops acquisition first. On Jarek's laptop
  (2026-11-02) L1 and L2 passed (exit-check table). Found there: Grafana's
  home page still showed the old dashboard (no Line selector) and struggled
  to draw a chart for each of 2,015 properties — Grafana reads the home-page
  copy only at start, while the provisioned dashboard had updated. Fixed by
  restarting Grafana; the `live` suite now checks the home page too
  (Grafana 13 answers with a forward to `/d/default-home-dashboard/…`; the
  check follows it).
  Drill X1 found a real fault: after `docker compose stop mosquitto` and
  `start`, the broker restarted in a loop (`Error: Unable to open file
  /mosquitto/secure/passwd for writing. File exists`). Mosquitto 2.1's
  `mosquitto_passwd -c` no longer overwrites an existing file (it opens with
  O_EXCL, although its help text still says it overwrites), and a stopped and
  started container keeps last start's file. Until then the broker had only
  ever been started as a new container, so a server restart would have hit
  the same fault. Fixed: the start script empties the folder first; the
  `deploy` suite checks it. Node-RED kept retrying every 10 s throughout and
  needed nothing. With the load line selected, Grafana froze: the Property
  selector kept "All", i.e. a chart for each of the line's 2,000
  properties. A Machine selector now sits between Line and Property; charts
  show one machine's properties (tens on a real machine, 100 on a load
  machine), the table still the whole line (2,000 rows in 25 ms).
- Step 2.8 was tested on the local replica with Docker Engine 29.8 and
  Compose 5.5: the compose file validated by Compose itself (also the first
  validation of the step 2.7 changes); the bundle built by
  `make-bundle.ps1` under PowerShell 7.4 from a Git copy of the repository
  (uncommitted changes refused; `.env` not in the archive), then loaded by
  both `offline-load.ps1` and `offline-load.sh` after removing every image; a
  damaged file stopped both. The images were stand-ins tagged with the real
  names (Docker Hub is not reachable from the replica), so the real bundle
  size and `docker save`/`load` of the real images are checked in O1 and O3.
  Windows PowerShell 5.1 itself was not available; the scripts avoid
  everything 5.1 lacks. TimescaleDB accepted `telemetry_level=off` at start.
  Found while checking outbound connections: Mathesar's first-visit page
  ticks "installation confirmation" and "usage data" by default (README
  step 16 said nothing was sent; corrected). On Jarek's laptop
  (2026-11-01): O1 bundle built; O2 damaged and missing files refused; O3
  with the network disconnected: all eight images removed and loaded from
  the bundle, image IDs identical, volumes and history kept, stack started
  without downloading, all checks passed except those of the bench PLCs,
  which were disconnected with the network (expected).
- Step 2.7 was tested on the local replica (Mosquitto 2.0 with OFM's
  configuration, Caddy 2.11.7, the certificate script under busybox, as in
  the Alpine-based image): certificate authority and server certificate
  created once, unchanged on the next run, reissued when the names change,
  when renewal is due and after a new authority; a bad name refused; plant
  IT import checked (wrong key refused, expiry warned, never replaced). All
  11 `tls` checks pass and fail when they should (a name missing, the proxy
  stopped); WebSockets through the proxy (Node-RED editor) work. Not tested
  here: Grafana and Mathesar themselves behind the proxy (stand-ins only),
  Docker Compose itself, and browsers on Windows — that is T1–T4. Mathesar's
  login over HTTPS relies on its production settings trusting the proxy's
  `X-Forwarded-Proto` header (read in its 0.12.0 source). On Jarek's laptop
  (2026-11-01) T1–T3 passed at once, including saving in Mathesar over
  HTTPS. T4 first failed with "connection refused": `.env` still had the
  defaults (`127.0.0.1`, no names); after setting them, Grafana opened over
  HTTPS from a second laptop. The `certs` log now states whether OFM is
  reachable from this computer only or the network, and warns when it is
  open to the network without `OFM_TLS_NAMES`.
- Step 2.6 was tested on the local replica: with the database stopped and
  Node-RED restarted, the runtime started from the saved copy 4 s after the
  restart (cache `trigger: disk`, all three sources online, values flowing,
  historian `buffering`); with the database started again, the model was
  reloaded from it within 10 s (`trigger: startup`), the queue was written
  and the minute of the outage was complete in the historian; the copy was
  saved again. A brand-new runtime (no copy yet) still needs the database for
  its first start, and `docker compose up` waits for the database on purpose
  (migrations first); a Node-RED or server restart does not.
- After a short OPC UA outage in which the session survives, a value that has
  not changed is not resent by the server; it returns to `good` with the next
  heartbeat (within its max publish interval), not immediately.
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
- Step 3a.1 part 1 was tested on a local replica (Node-RED 4.1.16 with
  node-opcua 2.160.0, the image's versions; no Docker): `flows` suite 168
  checks including 33 for the simulator; the flow running in Node-RED with
  all six OPC UA servers up; read and subscribed with an OPC UA client like
  OFM's (sampling 0.5 s, publishing 1 s): nine Good values per machine,
  device timestamps, heartbeat +1/s; a full Deploy closes and reopens the
  servers; the `live` check passes with the simulator running and is
  skipped without it. Not tested here: Docker Compose itself, the proxy
  route 1881, the bind-mounted `demo/` folder — that is P2–P5. Found on the
  way: faster machines flapped between running and starved/blocked, and a
  case packer collecting a set of 10 showed as starved; starved/blocked now
  need the neighbour to have delivered or taken nothing for 2 s plus 1.5 of
  its normal intervals. With the default settings an 8-hour run gives
  55–85 % of rated output depending on the random seed, about 15 state
  changes per machine per hour.
- Step 3a.1 part 2 was tested on the replica: `flows` suite 174 checks
  (39 for the simulator); the panel opened in a headless browser at 1400
  and 820 px wide: *Break and hold* on the closer turned the upstream
  machines blocked and the downstream ones starved, preset, changeover,
  *Stop simulator* and a typed setting all reached the engine. Presets were
  calibrated with 10 random seeds × 8 hours each: good 75 %, typical 60 %,
  bad 41 % of rated output. Found on the way: SVG attribute names lose
  their capitals in a Dashboard 2 template (`viewBox`), so the picture did
  not scale; written with Vue's `.camel` modifier.
- 2026-11-03, P9 on the laptop: after a changeover to mix500 the panel
  showed product mix250 and the filler at 97/min. Changeovers to mix500
  worked on the replica (in simulated time and with a 1-minute changeover in
  real time, panel driven by a browser). The only code that sets mix250 is
  rebuilding the line from `line.json`, which a container restart or a flow
  restart does — it reset the product to `freeRunSku`. Now a re-read of
  `line.json` keeps product, changeover and a stopped line; a container
  restart still starts at `freeRunSku` until step 3a.5 (product from OFM's
  work order). Also from P9: 20-minute changeovers are too long to wait for
  in a test, so the panel has a changeover-minutes box (default the
  product's `changeoverMin`); `line.json` keeps the realistic 10–20 minutes.
  Asked for the same day: a *New run* button (counters, conveyors,
  breakdowns and changeover cleared; product and settings kept), tested in
  a browser including its confirmation question; offline suites 205 checks
  (44 for the simulator).
- Docker Desktop stays on the laptop for development (decided 2026-11-02).
  Its licence applies to development use too: within an organisation above
  Docker's small-business limit, the laptop needs a paid seat.
- Stage C preparation (2026-11-02) is documentation only: three proposed
  ADRs, deploy README section 7, Overview 0.6.13, load-test threshold
  2.5 → 2.0 s. Nothing was run; the Linux steps in section 7 are first
  tested in C2.1. Storage figures in 7.1 are estimates from assumed row
  sizes.
- OPC UA client, found while preparing question 24 (from the flow code and
  node-opcua 2.160.0): sessions are anonymous; server certificates are
  accepted automatically; the client's own certificate is created in
  node-opcua's default folder (`~/.config/node-opcua-default-nodejs/PKI`,
  assumed inside the container's home `/usr/src/node-red`, not in a volume),
  so it changes whenever the container is recreated. Harmless with
  `securityMode: None`; must be fixed before an encrypted connection to a
  real PLC (step C1.5). To confirm on the laptop:
  `docker exec ofm-nodered sh -c 'echo $HOME; ls -a ~/.config'`.
- Mosquitto 2.1 deprecates `password_file`/`acl_file` in favour of plugins
  (removal planned for 3.0). Migrate before any upgrade to 3.x.
- The installation has been run end-to-end on one machine only.
