# OFM tests

Every automated test runs with one command, from `C:\ofm\deploy`:

```powershell
docker compose run --rm test            # everything (the stack must be running)
docker compose run --rm test offline    # schemas, flow and deployment files; no stack needed
docker compose run --rm test live       # one suite: schemas, flows, deploy, database or live
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

## The suites

| Suite | Checks | Needs the stack |
|---|---|---|
| `schemas` | Every payload schema in `schemas/` is valid JSON Schema 2020-12; every example in `tests/schemas/<schema>/valid/` passes and every one in `invalid/` is rejected | no |
| `flows` | The function code in `flows/ofm-runtime.json`, run outside Node-RED: scaling, validation and timestamp rules (ADR-0003), quarantine, model cache; S7 and EtherNet/IP polling against a stand-in PLC library (report by exception, wrong addresses skipped, connection loss and recovery); heartbeat, historian writer and its disk queue; the saved model copy and the start without the database; every payload the flow can produce matches its schema and topics follow the topic standard. The simulated packing line (`demo/packing-line/linesim-flows.json`, `linesim`): `line.json` checked; the constraint sets the pace; no flapping; a breakdown spreads through the conveyors and clears; rejects, breakdown rate, shift pattern, changeover, pause (frozen heartbeat) and commands, in simulated time | no |
| `deploy` | The deployment files: every image pinned to a version and OFM's own never pulled; only the encrypted ports may be opened to the network, the database never; no password written into `docker-compose.yml`; every component's telemetry and update checks off; the offline bundle covers every image | no |
| `database` | All migrations applied and unedited; UTC; hypertables; the model refuses bad names, reserved names, missing units, duplicate addresses; `vw_runtime_model` is right; every role can do exactly what Overview §13 says and no more; every model change is audited | yes |
| `load`, `watch` | **Opt-in, never part of `all`.** The Phase 2 load test and the drill recorder (step 2.9, below); they run for minutes and need the load-test line | yes, with the load-test line |
| `live` | The automated part of the Phase 1 exit check (below): runtime and sources online, the whole model loaded, a current value on the UNS for every property, every UNS message valid, recent rows in the historian, dashboard and Grafana datasource working, editors reachable; model reload; encryption (`tls`: certificates, MQTT over TLS, HTTPS for every page, checked as a client computer would); the simulated packing line when it runs (`linesim`: all six simulated PLCs answer, nine Good signals each, heartbeat moving; skipped otherwise) | yes, with data flowing |

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
| S3 | During S2's outage, also `docker compose restart nodered` | Rows up to the restart are kept (saved to the queue on stop, written later). From step 2.6 values return within seconds of the restart (check B1); before it, not until the database was back |

**Step 2.5, historian housekeeping.** Automated: the `database` suite checks
compression, refresh and retention policies and who may read the averages.
By hand:

| # | Do | Expected |
|---|---|---|
| K1 | `docker compose up -d`, then `docker compose logs migrate` | Last line: `Historian retention: raw data 365 days, 1-minute and 1-hour averages 5 years` |
| K2 | In Grafana set the time range to *Last 7 days* (or longer) | Charts load quickly; the blue line is the average inside a light grey band from the lowest to the highest value; lines break where nothing was recorded (e.g. nights with the stack off); *Last 15 minutes* shows raw values again. The `live` suite checks that Grafana serves the dashboard file of the repository |
| K3 | List the housekeeping jobs: `docker exec ofm-timescaledb psql -U ofm_admin -d ofm -c "SELECT job_id, proc_name, hypertable_name, config FROM timescaledb_information.jobs WHERE hypertable_schema = 'hist' ORDER BY 1"` | Two compression jobs (7 days), two refresh jobs, four retention jobs (365 days, 5 years) |

**Step 2.6, start without the database** (ADR-0001). Automated: the `flows`
suite (`modelcopy`: the copy is saved after every load from the database;
a restart without the database starts from it; a missing, damaged or foreign
copy is not used; the database's model replaces the copy when it answers);
the `live` suite checks that the runtime is not still running on the copy.
By hand, with `ofm/_system/#` watched (README step 12b command with that
topic):

| # | Do (from `C:\ofm\deploy`) | Expected |
|---|---|---|
| B1 | `docker compose stop timescaledb`, then `docker compose restart nodered`; wait 30 s | Within about 10 s of the restart: `ofm/_system/cache/ofm_runtime_01` shows `"trigger":"disk"` with `savedAt`; sources `online`; values flow on `acme/#`; historian `buffering`. `docker compose logs nodered` shows `starting from the copy saved …` |
| B2 | `docker compose start timescaledb`; wait 30 s | Within about 10 s of the database being ready: cache `"trigger":"startup"` (no `savedAt`), historian `writing` with `queueDepth` 0; Grafana shows no gap for the outage; `docker compose run --rm test` passes |
| B3 | With everything running, change an `alarm_high` in Mathesar; then repeat B1 and B2 | During B1 that property's `_meta` shows the **new** limit (after the restart every `_meta` is republished from the copy, and the copy is saved after every model change). `docker exec ofm-nodered ls -l /data/model` shows the copy with the time of your edit |

**Step 2.7, encryption** (ADR-0019). Automated: the `live` suite (`tls`):
the certificate is signed by OFM's authority, valid for more than 30 days and
names every address clients use (including `OFM_TLS_NAMES`);
`deploy/certs/ofm-ca.crt` is the authority in use; MQTT over TLS logs in as
`ofm_reader` and refuses a wrong password and a client that does not trust
OFM's authority; Grafana, Mathesar and the Node-RED editor answer over
HTTPS; `http://` is redirected. By hand, after README step 8a:

| # | Do | Expected |
|---|---|---|
| T1 | Open https://localhost:3000, https://localhost:8080 and https://localhost:1880; log in to each; in Mathesar change and save one value (e.g. a `description`) | A padlock and no warning on all three; logins work; Mathesar saves (its login and saving check that the page really came over HTTPS) |
| T2 | Open http://localhost:3000 (plain) | Redirected to https://localhost:3000 |
| T3 | MQTT Explorer: host `localhost`, port 8883, encryption on, validate certificate on, Advanced → Certificates → Server Certificate (CA) = `C:\ofm\deploy\certs\ofm-ca.crt`, user `ofm_reader`. Then the old connection, port 1883 without encryption | 8883: the `acme/…` tree as before. 1883: cannot connect (plain MQTT exists only inside the stack) |
| T4 | From another computer on the same network. In `.env` edit the existing lines (each must appear once; the last one wins): `OFM_LISTEN_ADDRESS=0.0.0.0` and `OFM_TLS_NAMES=<laptop name>,<laptop IP>`; then `docker compose up -d` and `docker ps --format "table {{.Names}}\t{{.Ports}}"`; then follow deploy README section 6, *Reaching OFM from other computers* (firewall rule, `ofm-ca.crt` on the other computer) | `ofm-proxy` and `ofm-mosquitto` listen on `0.0.0.0:…`; `docker compose logs certs` says `reachable from: the network` and lists both names; `https://<laptop IP>:3000` on the other computer shows Grafana with a padlock ("refused" = still bound to 127.0.0.1; "timed out" = firewall). Afterwards set `OFM_LISTEN_ADDRESS=127.0.0.1` again if the laptop should not stay open |

**Step 2.8, offline install bundle.** Automated: the `deploy` suite (images
pinned, bundle covers every image, telemetry off in the files) and the
`database` suite (TimescaleDB telemetry really off). By hand, on the laptop:

| # | Do | Expected |
|---|---|---|
| O1 | Commit everything, then `powershell -ExecutionPolicy Bypass -File C:\ofm\tools\make-bundle.ps1` | Ends with `Bundle: C:\ofm-bundles\ofm-<version> (… GB, 8 images)`; `MANIFEST.txt` lists 8 images, all `linux/amd64` |
| O2 | Damage a copy of the bundle: `Copy-Item -Recurse <bundle> C:\ofm-bundles\damaged`, open `damaged\images.txt` in Notepad, add a space, save; run `damaged\offline-load.ps1`; then delete `damaged` | `DAMAGED  images.txt` and "copy the bundle again"; nothing is loaded |
| O3 | **Offline reinstall** of the laptop's images: unplug the network (Wi-Fi off); in `C:\ofm\deploy`: `docker compose down`, then `Get-Content <bundle>\images.txt \| ForEach-Object { docker image rm $_ }`, then `<bundle>\offline-load.ps1`, then `docker compose up -d` (no `--build`) and `docker compose run --rm test` | All images load from the bundle without network; the stack starts with its data (volumes are kept); tests pass; Grafana shows the history. If the bench PLCs share the disconnected network, their checks fail too (sources offline) — expected. Network back on afterwards. (If anything fails here, `docker compose up -d --build` with the network on restores the images) |
| O4 | In Mathesar: menu at the top right (your user name) → *Administration* → *Settings*, or https://localhost:8080/administration/settings/ | Under *Usage Data Collection*, *Enable anonymous usage data collection* is unticked (untick it if it was ticked) |

**Step 2.9, load test and failure drills — the Phase 2 exit check.** Exit
criterion (Overview §18): *model edit visible in the runtime within a second;
broker-kill and PLC-disconnect drills pass; 2,000 values per second
sustained.* The load comes from a second OPC PLC simulator, `opcplc-load`,
whose 2,000 values change every second, read into a separate test line
(`ofmload/lab/loadtest/loadline01`) — it never touches the bench PLCs or the
example plant. Set up once, from `C:\ofm\deploy`:

```powershell
docker compose --profile loadtest up -d
docker compose run --rm migrate loadtest
```

Within a second the runtime adds 2,000 properties (no restart). In Grafana,
the *Line* list now also offers `ofmload/lab/loadtest/loadline01` (20
machines of 100 properties; pick a *Machine* before looking at charts), and
*Values stored per minute* shows about 120,000.

| # | Do | Expected |
|---|---|---|
| L1 | `docker compose run --rm -e OFM_LOAD_MINUTES=10 test load` (10 minutes) | Every 10 s a line like `UNS 2000 values/s (100%), historian 2000 rows/s, writer writing`; at the end `ALL CHECKS PASSED`: rate held, 95 % of values on the UNS within 2 s of their device time (ADR-0022), every UNS value in the historian, nothing buffered or dropped, all values good |
| L2 | During L1, in a second window: `docker stats --no-stream` (twice, a minute apart) | Note *CPU %* and *MEM USAGE* of `ofm-nodered`, `ofm-mosquitto`, `ofm-timescaledb`: the figures for STATUS. Node-RED uses one CPU core at most, so its CPU % shows the headroom (100 % = one core full) |
| L3 | *Optional, the ceiling:* in `.env` set `OFM_LOAD_VALUES=4000`, then `docker compose --profile loadtest up -d`, `docker compose run --rm migrate loadtest 4000`, then `docker compose run --rm -e OFM_LOAD_MINUTES=5 test load`; repeat with 6000, 8000 … | The highest number that still passes is what this computer can carry. Set `OFM_LOAD_VALUES=2000` and `migrate loadtest` back afterwards |

**Drills under load.** **One drill per recording:** start the recorder in
one window, wait for its first two lines (about 20 s), run *one* drill's
commands in a second window, then leave everything alone until the REPORT
appears. The recorder runs 3 minutes, then prints a REPORT: the events it
saw, gaps on the UNS, gaps in the historian, and values that reached the UNS
but are missing from the historian. Two drills in one recording mix their
effects, and the report can no longer be judged.

```powershell
docker compose run --rm -e OFM_WATCH_MINUTES=3 test watch
```

| # | Drill (second window) | Expected REPORT |
|---|---|---|
| X1 | **Broker down:** `docker compose stop mosquitto`, wait 20 s, `docker compose start mosquitto` | UNS gap ≈ 20 s; **historian gaps: none**; lost 0 (history does not go through the broker, ADR-0002) |
| X2 | **Database down:** `docker compose stop timescaledb`, wait 60 s, `docker compose start timescaledb` | Writer `buffering`, then `writing`; UNS gaps: none; **historian gaps: none**; lost 0 |
| X3 | **Runtime crash:** `docker compose kill nodered`, wait 15 s, `docker compose start nodered` | `runtime offline`, then `online`; UNS and historian gap ≈ 20–30 s (down time plus start-up); lost **at most 2,000** — the last second in the writer's memory, the one loss a crash can cause |
| X4 | **Runtime restart:** `docker compose restart nodered` | Gaps of about 10–20 s; lost **0** (the writer saves its memory to the disk queue on stop) |
| X5 | **PLC lost:** `docker compose --profile loadtest stop opcplc-load`, wait 20 s, `docker compose --profile loadtest start opcplc-load` | `load source offline` within seconds, `online` after the start; values return by themselves; lost 0 |
| X6 | **Data path restart:** `docker compose restart timescaledb mosquitto nodered` | Everything returns without any manual step; gaps of about the restart time; lost 0 |

**Afterwards**, remove the test line with all its history, and stop its
simulator:

```powershell
docker compose run --rm migrate loadtest-remove
docker compose --profile loadtest stop opcplc-load
```

**Release.** When `docker compose run --rm test` passes and L1, X1–X6 behave
as expected, record the results in `docs/STATUS.md`, commit, and tag the
release from `C:\ofm`:

```powershell
git tag -a v0.2 -m "Phase 2: robust and editable"
git push origin v0.2
```

## Phase 3a checks so far

**Step 3a.1 part 1, the simulated line's engine and simulated OPC UA PLCs**
(ADR-0023). Automated: the `flows` suite (`linesim`) and, with the demo
running, the `live` suite (`linesim`). By hand, on the laptop:

| # | Do | Expect |
|---|---|---|
| P1 | `docker compose run --rm test offline` | all checks pass, including the `linesim` unit tests |
| P2 | `demo` added to `COMPOSE_PROFILES` in `.env`; `docker compose up -d`; `docker compose logs linesim` | `linesim` running; `Started flows`, no `[error]` |
| P3 | `https://localhost:1881`, tab *Line simulator* (inside the shift pattern, or with it switched off as in demo README section 12) | statuses: `6 machines, loaded …`; `run · mix250 · filler running 97/min · good …` with good rising; `6 of 6 OPC UA servers up` |
| P4 | `docker compose run --rm test live` | the `linesim` checks pass for all six machines |
| P5 | `docker compose restart linesim`, then P4 again | all six simulated PLCs back within about 15 s; counters start again from 0 |
| P6 | *(optional)* a desktop OPC UA client (e.g. UaExpert) on `opc.tcp://localhost:4842`, anonymous, no security | Objects → `filler` → nine values; `Heartbeat` +1 per second |

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
