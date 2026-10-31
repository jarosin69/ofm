# OFM tests

Every automated test runs with one command, from `C:\ofm\deploy`:

```powershell
docker compose run --rm test            # everything (the stack must be running)
docker compose run --rm test offline    # schemas and flow only; no stack needed
docker compose run --rm test live       # one suite: schemas, flows, database or live
```

The tests run in a throw-away container made from OFM's own Node-RED image,
using the libraries already inside it, so they need no internet and work on
an isolated plant network too. The repository is mounted read-only and the
database tests roll back everything they do: running the tests never changes
your data.

Each check prints one line, `PASS`, `FAIL` (with the reason underneath) or
`SKIP`. The last lines give the totals and either `ALL CHECKS PASSED` or
`SOME CHECKS FAILED`. The exit code is 0 only when everything passed, so the
same command can later run automatically on every commit (CI).

## The four suites

| Suite | Checks | Needs the stack |
|---|---|---|
| `schemas` | Every payload schema in `schemas/` is valid JSON Schema 2020-12; every example in `tests/schemas/<schema>/valid/` passes and every one in `invalid/` is rejected | no |
| `flows` | The function code in `flows/ofm-runtime.json`, run outside Node-RED: scaling, validation and timestamp rules (ADR-0003), quarantine, model cache; S7 and EtherNet/IP polling against a stand-in PLC library (report by exception, wrong addresses skipped, connection loss and recovery); every payload the flow can produce matches its schema and topics follow the topic standard | no |
| `database` | All migrations applied and unedited; UTC; hypertables; the model refuses bad names, reserved names, missing units, duplicate addresses; `vw_runtime_model` is right; every role can do exactly what Overview §13 says and no more; every model change is audited | yes |
| `live` | The automated part of the Phase 1 exit check (below): runtime and sources online, the whole model loaded, a current value on the UNS for every property, every UNS message valid, recent rows in the historian, dashboard and Grafana datasource working, editors reachable | yes, with data flowing |

The `live` suite takes its list of properties from the model, not from a file:
add a property in Mathesar, restart Node-RED, and it is checked too.

Two notes on `live` in Phase 1:

- "Current" means newer than twice the property's `max_publish_interval_ms`
  (2 minutes by default, ADR-0007). Phase 1 publishes only on change, so a
  value that never changes goes stale after 2 minutes and fails this check.
  Republishing unchanged values arrives with Phase 2 step 2.3. The simulator's
  values all change often enough.
- A `hopper_level` value of `uncertain` is not a failure (it is outside its
  range, which is the point of that example). Only `bad` fails.

## Phase 1 exit check

Exit criterion (Overview §18): *one simulated line's values flowing OPC UA
simulator → UNS → historian → dashboard from model configuration only.*

**1. Automated:** `docker compose run --rm test` — all checks pass.

**2. Drills.** Open a second PowerShell window to watch the platform topics
while you do each drill (Ctrl+C to stop):

```powershell
docker exec -it ofm-mosquitto sh -c 'mosquitto_sub -u ofm_reader -P $OFM_MQTT_READER_PASSWORD -t ofm/_system/# -v'
```

| # | Drill (from `C:\ofm\deploy`) | Expected |
|---|---|---|
| D1 | **PLC lost:** `docker compose stop opcplc`, wait 30 s, then `docker compose start opcplc` | Within about 10 s: `ofm/_system/sources/opcplc {"state":"offline",…,"error":…}`. Values stop updating; in Phase 1 they keep their last quality (`bad` on loss arrives in Phase 2 step 2.3). After the start, within about 10 s: `"state":"online"` and values flow again |
| D2 | **Runtime crash:** `docker compose kill nodered`, then `docker compose start nodered` | Immediately: `ofm/_system/runtime/ofm_runtime_01 {"state":"offline"}` (the Last Will, sent by the broker). After the start: `"state":"online"`, then the source and cache status again |
| D3 | **Database lost:** `docker compose stop timescaledb`, wait 1 minute, then `docker compose start timescaledb` | Live values keep flowing to the UNS throughout (watch `acme/#` with the command in README step 12b); Node-RED's debug sidebar shows historian write errors. After the start, historian rows resume. The minute without the database stays a gap in the historian and in Grafana: store-and-forward, which fills such gaps, arrives in Phase 2 step 2.4 |
| D4 | **Model-driven:** add a property in Mathesar (steps below), then `docker compose restart nodered` | The new topic appears in the UNS, its rows in the historian, and the property in the dashboard's *Property* list — with no change to any flow, dashboard or file. `docker compose run --rm test live` now checks 6 properties |

D4 in Mathesar (log in as yourself), schema `config`:

1. Table **machine_property**, new record: *machine* = Cooling tunnel 1,
   *name* `water_temp`, *display_name* `Cooling water temperature`,
   *datatype* `float`, *engineering_unit* = degC. Leave the rest empty or at
   its default.
2. Table **plc_mapping**, new record: *property* = the new one, *source* =
   opcplc, *address* `nsu=http://microsoft.com/Opc/OpcPlc/;s=NegativeTrendData`.
   Scale factor 1 and offset 0 are the defaults. (Any other simulator node
   that you can see in UaExpert and that is not already mapped will do.)

Afterwards you can keep it, or **retire** it: set `retired_at` on the
property and on its mapping to the current time. It cannot be deleted once it
has history (ADR-0004: history keeps its IDs).

**3. Record and release.** Paste the result line of the automated run and the
drill outcomes into the Phase 1 exit check table in `docs/STATUS.md`, commit,
then tag the release from `C:\ofm`:

```powershell
git tag -a v0.1 -m "Phase 1: live data path"
git push origin v0.1
```

From Phase 2 step 2.1 the restart in D4 is no longer needed (see below).

## Phase 2 checks so far

**Step 2.1, model changes without restart.** Automated: the `database` suite
checks that every configuration table notifies the runtime; the `live` suite
sends that notification and expects a model reload within 2 seconds. By hand,
with the command of README step 12b running:

| # | In Mathesar | Expected within about a second, without restart |
|---|---|---|
| R1 | Rename a property (e.g. `water_temp` → `water_temperature`) | The old topic disappears from the broker (an empty retained message), values arrive on the new topic; its history continues (same property ID); `ofm/_system/cache/…` shows `"trigger":"notify"` |
| R2 | Change a `scale_factor` | New values use the new scaling; no PLC reconnects |
| R3 | Change a PLC tag's `address` | Only that PLC reconnects (its "not read" warnings, if any, appear again in the log); other PLCs keep running |
| R4 | Set `retired_at` on a property, then clear it again | Its topic disappears from the broker, then values return |
| R5 | Rename the property of R1 back | As R1 |

**Step 2.2, `_meta` topics and start-up clean-up.** Automated: the `flows`
suite checks the `_meta` content, that only changed `_meta` are republished,
and which stale topics the clean-up clears or keeps; the `live` suite checks
a matching `_meta` for every property. By hand:

| # | Do | Expected |
|---|---|---|
| M1 | Watch `acme/+/+/+/+/+/_meta` (README step 12b command with that topic) | One retained line per property: property ID, data type, unit, display name, limits |
| M2 | In Mathesar change an `alarm_high` | Within about a second, only that property's `_meta` line is republished with the new limit |
| M3 | `docker compose stop nodered`; in Mathesar rename a property; `docker compose start nodered` | After start-up, the old value and `_meta` topics are gone; the Node-RED log shows `start-up clean-up: cleared 2 stale topic(s)`; values arrive on the new name |

**Step 2.3, deadband, heartbeat, `bad` on loss** (ADR-0007). Automated: the
`flows` suite (deadband rules in `normalise`, the `heartbeat` file, polled
sources sending only changes). By hand:

| # | Do | Expected |
|---|---|---|
| H1 | In Mathesar set `deadband` of `chocolate_temp` to `1`, watch it; then back to `0.1` | With 1, a new value only when it has moved by 1 °C or more (far fewer lines); with 0.1, frequent again |
| H2 | Watch a value that does not change — e.g. on the S7-1200 add a property mapped to an unused memory word, address `MI200` (reads 0) | It is republished every 60 s (its `max_publish_interval_ms`) with the current `ts` and `"tss":"gateway"`; a new historian row each time |
| H3 | Unplug a PLC's network cable for 30 s, then plug it back in | Within seconds all its values are republished with their last value and `"q":"bad"`, and repeated `bad` every 60 s while it is out; Grafana shows the orange "not good" points from that moment; back online, values return with `"q":"good"` |

**Step 2.4, no lost history; refused addresses visible.** Automated: the
`flows` suite (`writer`: batching, disk queue, size limit, refused rows, save
on stop; `polled`: refused addresses published bad); the `live` suite checks
that the writer is `writing` with nothing queued or dropped. By hand, with
`ofm/_system/historian/#` watched (README step 12b command with that topic):

| # | Do | Expected |
|---|---|---|
| S1 | In Mathesar set the address of a bench tag to one the PLC does not have (S7: `DB99,REAL0`; CompactLogix: `No_Such_Tag`) | Within about a second the property shows `"v":null,"q":"bad"` on the broker, and in Grafana's *Latest values* an empty value with quality `bad`; the log names the address; set it back and good values return |
| S2 | `docker compose stop timescaledb`, wait 2 minutes, `docker compose start timescaledb` | `"state":"buffering"` with a growing `queueDepth`; live values keep flowing; after the start, `"state":"writing"`, `queueDepth` 0 — and Grafana's charts for those 2 minutes have **no gap** |
| S3 | During S2's outage, also `docker compose restart nodered` | Rows up to the restart are kept (saved to the queue on stop, written later). After the restart, no values at all until the database is back: the runtime needs the model to start (known limitation, see STATUS) |

**Step 2.5, historian housekeeping.** Automated: the `database` suite checks
compression, refresh and retention policies and who may read the averages.
By hand:

| # | Do | Expected |
|---|---|---|
| K1 | `docker compose up -d`, then `docker compose logs migrate` | Last line: `Historian retention: raw data 365 days, 1-minute and 1-hour averages 5 years` |
| K2 | In Grafana set the time range to *Last 7 days* (or longer) | Charts load quickly; the blue line is the average inside a light grey band from the lowest to the highest value; lines break where nothing was recorded (e.g. nights with the stack off); *Last 15 minutes* shows raw values again. The `live` suite checks that Grafana serves the dashboard file of the repository |
| K3 | List the housekeeping jobs: `docker exec ofm-timescaledb psql -U ofm_admin -d ofm -c "SELECT job_id, proc_name, hypertable_name, config FROM timescaledb_information.jobs WHERE hypertable_schema = 'hist' ORDER BY 1"` | Two compression jobs (7 days), two refresh jobs, four retention jobs (365 days, 5 years) |

## Adding a test

- **A schema rule:** add an example file to `tests/schemas/<schema>/valid/`
  or `invalid/`. Nothing else to change.
- **Flow behaviour:** add a case to `tests/flows/normalise.test.js` (or a new
  `tests/flows/<name>.test.js`; every `*.test.js` file in a suite folder is
  run). `tests/lib/functions.js` runs any function node of the flow file.
- **A database rule or permission:** add an entry to `CASES` in
  `tests/database/database.test.js`: which role, which SQL, and whether it
  must succeed or be refused (with the PostgreSQL error code).
- **A new phase's exit check:** a new file in `tests/live/`.

A bug found by hand should become a test before it is fixed: the test fails,
the fix makes it pass, and it can never come back unnoticed.
