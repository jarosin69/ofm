# OFM Proof of Concept — Windows 11 setup

This folder is the complete PoC environment as containers under Docker
Compose: TimescaleDB (model and historian), Mosquitto (UNS broker), Node-RED
(runtime), Grafana (dashboards), Mathesar (model editor) and, for development,
an OPC UA simulator as the data source. The same file, with different `.env`
values, is the plant deployment (Architecture Overview §14).

The kit is hardened for a single laptop (Architecture Overview §13):

- every service port is bound to `127.0.0.1`, so it is reachable from this
  laptop only;
- all passwords live in one generated file, `.env` (never committed); the
  database role passwords, MQTT users and Grafana datasource are set from it
  at every start;
- the database structure is built and kept up to date automatically by
  numbered migrations (`db/migrations/`, ADR-0012);
- the Node-RED editor requires a login;
- Mosquitto refuses anonymous clients and applies per-user topic rules
  (`mosquitto/config/acl`);
- image versions are pinned in `docker-compose.yml`.

## 1. Prepare Windows

1. **Check virtualisation is enabled.** Task Manager → Performance → CPU →
   "Virtualization: Enabled". If it says Disabled, enable Intel VT-x / AMD-V
   in the BIOS/UEFI first.
2. **Install WSL2.** Open PowerShell *as Administrator*:
   ```powershell
   wsl --install
   ```
   Reboot when prompted. (If WSL was already present, run `wsl --update`.)
3. **Install Docker Desktop** from https://www.docker.com/products/docker-desktop/.
   Keep **"Use WSL 2 based engine"** checked (the default). Start Docker
   Desktop once and let it finish initialising. In Docker Desktop → Settings →
   General, enable **"Start Docker Desktop when you sign in"** — a historian
   that does not start with Windows records nothing. If any `docker` command
   reports `open //./pipe/dockerDesktopLinuxEngine`, Docker Desktop is not
   running: start it and wait until it reports "running".

   *Licensing:* Docker Desktop is free for personal use, education and small
   businesses only. For use within a larger organisation, either obtain a
   subscription or install the free Docker Engine directly inside the WSL2
   Ubuntu distribution; the Compose file is identical either way.
4. **Stop the laptop from sleeping.** Settings → System → Power → Screen and
   sleep → "When plugged in, put my device to sleep" → **Never**. Also
   disable Fast Startup (Control Panel → Power Options → Choose what the
   power buttons do → untick "Turn on fast startup").
5. *(Optional but recommended)* Cap the WSL VM in
   `C:\Users\<you>\.wslconfig`:
   ```ini
   [wsl2]
   memory=6GB
   processors=4
   ```
   Then `wsl --shutdown` once; Docker Desktop restarts the VM.

## 2. Install OFM (two commands)

6. Get the repository into `C:\ofm` (clone it, or download and unzip it), then
   open PowerShell in the deploy folder:
   ```powershell
   cd C:\ofm\deploy
   ```
7. **Generate the secrets.** This creates `.env` with a random password for
   every service and prints the three logins you need (Node-RED, Grafana,
   Mathesar). It runs inside a small throw-away container, so nothing needs
   installing, and the same command works in a Linux shell:
   ```powershell
   docker run --rm -v "${PWD}:/work" -w /work alpine:3.22 sh make-env.sh
   ```
   Save a copy of `.env` in a password manager: it is the only place these
   passwords exist, and it is never committed to Git. Running the script again
   is always safe: on an existing `.env` it only adds settings that are
   missing (e.g. after an upgrade) and never changes an existing value.
8. **Start the stack:**
   ```powershell
   docker compose up -d --build
   docker compose ps
   ```
   The first start downloads the images and builds OFM's Node-RED image
   (`nodered/Dockerfile`: Node-RED plus its OPC UA, S7, PostgreSQL and
   dashboard nodes) — several minutes, and the only time internet is needed. Seven services
   should then be "running": `timescaledb`, `mosquitto`, `nodered`, `grafana`,
   `mathesar`, `mathesar-db` and `opcplc` (the simulator; it runs because
   `.env` contains `COMPOSE_PROFILES=simulator` — leave that empty at a plant).
   One more, `migrate`, runs once at every start to apply database migrations
   and set the database passwords, then stops: `docker compose ps -a` shows
   it as "Exited (0)", which is correct. With any other exit code, Node-RED
   and Mathesar do not start: see `docker compose logs migrate`.

That is the whole installation. On every start the stack creates or updates
the database structure, the passwords, the MQTT users and the Grafana
datasource by itself.

*Optional:* load the example plant `acme` (five properties read from the OPC
UA simulator), to have something to look at in Mathesar and, from Phase 1
step 1.3, on the dashboards. Running it again later refreshes the example:
```powershell
docker compose run --rm migrate example
```

## 3. Check it works

9. **Logins** (users and passwords were printed by step 7; they are also in
   `.env`):
   - **Node-RED** — http://localhost:1880 must ask for a login.
   - **Grafana** — http://localhost:3000. Then Connections → Data sources →
     **OFM historian** → **Test** must report success.
   - **Mathesar** — http://localhost:8080; the first visit is described in steps 16–17.
10. **Database** — roles exist and every migration is applied:
    ```powershell
    docker exec ofm-timescaledb psql -U ofm_admin -d ofm -c "\du"
    docker compose run --rm migrate status
    ```
    Expect roles `ofm_runtime`, `ofm_config`, `ofm_reader`, `ofm_mathesar`,
    and every migration under "Applied" with "Pending: (none)".
11. **MQTT access rules** — one allowed and two forbidden publishes. The
    commands read the passwords inside the broker container, so nothing needs
    typing. They use MQTT version 5 with QoS 1 (`-V mqttv5 -q 1`), so the
    broker answers every publish and a refusal is reported explicitly. (With
    the older MQTT 3.1.1, a refused message is dropped silently and the test
    would rely on silence.) In one PowerShell window, subscribe as the reader:
    ```powershell
    docker exec -it ofm-mosquitto sh -c 'mosquitto_sub -u ofm_reader -P $OFM_MQTT_READER_PASSWORD -t test/# -t ofm/# -v'
    ```
    In a second window, run the three publishes one at a time:
    ```powershell
    docker exec ofm-mosquitto sh -c 'mosquitto_pub -V mqttv5 -q 1 -u ofm_runtime -P $OFM_MQTT_RUNTIME_PASSWORD -t test/hello -m allowed'
    docker exec ofm-mosquitto sh -c 'mosquitto_pub -V mqttv5 -q 1 -u ofm_reader -P $OFM_MQTT_READER_PASSWORD -t test/hello -m reader-publish'
    docker exec ofm-mosquitto sh -c 'mosquitto_pub -V mqttv5 -q 1 -u ofm_runtime -P $OFM_MQTT_RUNTIME_PASSWORD -t ofm/_cmd/test -m cmd'
    ```
    Expected result — **all three must match**:

    | Publish | Second window prints | Subscriber prints |
    |---|---|---|
    | runtime → `test/hello` | nothing (accepted) | `test/hello allowed` |
    | reader → `test/hello` | `Warning: Publish 1 failed: Not authorized.` | nothing |
    | runtime → `ofm/_cmd/test` | `Warning: Publish 1 failed: Not authorized.` | nothing |

    The reader may only subscribe, and the runtime may not use the write-back
    branch (`mosquitto/config/acl`). Stop the subscriber with Ctrl+C.
12. **OPC UA simulator** — running and serving:
    ```powershell
    docker compose logs opcplc
    ```
    The log shows the server starting with its endpoint `opc.tcp://opcplc:50000`.
    To browse its nodes yourself, any desktop OPC UA client on this laptop can
    connect to `opc.tcp://localhost:50000` (security: None).
12a. **Node-RED reads the simulator** — log in to Node-RED, then Menu (☰) →
    **Import** → *select a file to import* → `C:\ofm\flows\checks\opcua-simulator-check.json`
    → **Import**, then **Deploy**. Open the **Debug** sidebar (bug icon, top
    right). After about 3 seconds, a line appears every second for each of
    five simulator nodes, e.g.
    `{node: "ns=3;s=SpikeData", value: 12.3, quality: "Good", sourceTimestamp: "…"}`.
    The node *find namespace number* shows which namespace number the
    simulator uses. Delete the tab afterwards (double-click the tab →
    **Delete**, then **Deploy**); it is only a check.
12b. **Live data from the model** — the Node-RED tab **OFM runtime** is OFM's
    generic runtime flow (`flows/ofm-runtime.json`). About 5 seconds after
    start, its node *build model cache* shows "5 properties, 1 source(s)" and
    *OPC UA acquisition* shows "opcplc online". Watch the UNS (Ctrl+C to stop):
    ```powershell
    docker exec -it ofm-mosquitto sh -c 'mosquitto_sub -u ofm_reader -P $OFM_MQTT_READER_PASSWORD -t acme/# -t ofm/_system/# -v'
    ```
    Expect one line per second per property, e.g.
    `acme/melbourne/chocolate/eggline01/depositor01/chocolate_temp {"v":29.4,"ts":1792927982001,"q":"good","tss":"device"}`,
    plus, per property, a retained `…/_meta` line with its unit, limits and
    description (from Phase 2), and the retained status of the runtime, the
    source and the model cache.
    And the historian:
    ```powershell
    docker exec ofm-timescaledb psql -U ofm_admin -d ofm -c "SELECT topic, count(*) AS rows, max(ts) AS latest_utc FROM hist.vw_measurement GROUP BY topic"
    ```
    Row counts grow every second. (`ts` is UTC, ADR-0003; Grafana shows
    Melbourne time.)

12c. **First dashboard** — open Grafana (http://localhost:3000). The home page
    is now **OFM · Live data**: properties reporting, values per minute,
    values not good, a table of the latest value of every property, and one
    chart per property. Times are Melbourne time. Orange points mark values
    that are not `good` (`hopper_level` shows this permanently, because the
    simulator's trend signal climbs past its 0–100 % range); red dashed lines
    are the alarm limits from the model. Try it: in Mathesar change
    `alarm_high` of `chocolate_temp`, and within one refresh the red line in
    Grafana moves — no dashboard edit, no restart. The dashboard file is
    `deploy/grafana/dashboards/ofm-live-data.json`; it cannot be overwritten
    from Grafana (use **Save as** for your own variants).
12d. **Run the tests** — every automated test in one command (details in
    `tests/README.md`):
    ```powershell
    docker compose run --rm test
    ```
    It takes about 20 seconds (15 of them listening to the UNS) and ends with
    `ALL CHECKS PASSED`. Run it after any change and before every commit
    that touches flows, schemas, migrations or dashboards.

## 4. First wiring (do once)

13. **OFM's flows are code** (ADR-0016). Node-RED's flow file is
    `C:\ofm\flows\ofm-runtime.json` in the repository: **Deploy** writes
    there, `git diff` shows what changed, and a change is committed like any
    other. Keep experiments on separate tabs and delete them before
    committing. No passwords are ever stored in flows; they come from `.env`.
    A model change (a new property, a new mapping, new scaling) needs no
    flow change and no restart: the runtime reloads the model within about
    a second of the change being saved (step 2.1). Only PLC connections whose
    endpoint, settings or address list changed are reconnected.
14. **Container-to-container addresses.** Inside flows and datasources, use
    Compose service names, never `localhost`:
    - MQTT broker host: `mosquitto`, port 1883
    - PostgreSQL host: `timescaledb`, port 5432, database `ofm`

    `localhost` works only from Windows itself (your browser, MQTT Explorer).
15. **Node-RED nodes and passwords in flows.** OFM's Node-RED image comes with
    the OPC UA, S7, PostgreSQL and dashboard nodes built in at pinned versions
    (`nodered/Dockerfile`), so nothing is installed from the internet. Do not
    install or update these through *Manage palette*: a palette copy would
    compete with the built-in one. A Modbus node is added when the first
    Modbus device needs it. **Passwords:** Node-RED receives `OFM_RUNTIME_DB_PASSWORD` and
    `OFM_MQTT_RUNTIME_PASSWORD` as environment variables, so flows refer to
    them as `${OFM_RUNTIME_DB_PASSWORD}` instead of storing the password.
    The exact use is set up with the first Phase 1 flow.
16. **Mathesar, first visit** (the model editor, ADR-0013). Open
    http://localhost:8080. Mathesar asks once for an administrator account:
    enter `MATHESAR_ADMIN_USER` and `MATHESAR_ADMIN_PASSWORD` from `.env`. This
    account is local to Mathesar on this machine; nothing is sent anywhere.
17. **Connect Mathesar to the model.** In Mathesar, connect an existing
    database with:
    - host `timescaledb`, port `5432`, database `ofm`
    - role `ofm_mathesar`, password `OFM_MATHESAR_DB_PASSWORD` from `.env`

    On this first connection Mathesar adds its own helper schemas (`msar`,
    `mathesar_types`) to the database; that is expected. Then open the
    `config` schema: these are the model tables shown in
    `docs/generated/erd.md`. `vw_runtime_model` shows every topic.
    Mathesar also lists the `hist` (historian) and `audit` schemas but
    reports "Your role does not have the privileges to view this table",
    even for its administrator: that is by design. The Mathesar
    administrator manages Mathesar; what anyone can see in the database is
    decided by the database login behind them, and the model editor has no
    access to history (ADR-0013). Look at history in Grafana, or with DBeaver
    as `ofm_reader` (below).
18. **A personal login for each person who edits the model** (recommended):
    ```powershell
    docker compose run --rm migrate adduser jarek
    ```
    This prints a password for the new database login `jarek`, which has
    exactly the editing rights of `ofm_config`. In Mathesar, add the person as
    a collaborator on the database with that role. Every change they make is
    then recorded in the audit log under their own name.

### Tools for engineers (optional)

**DBeaver Community** (free desktop database tool for Windows, Apache 2.0)
is useful for SQL queries, browsing history and checking views. It needs
nothing added to the stack: connect to `localhost`, port `5432`, database
`ofm`. Use the read-only login `ofm_reader` (password `OFM_READER_DB_PASSWORD`)
for everyday browsing, so nothing can be changed by accident; it is also the
only login that can read the audit log (`audit.audit_log`). Do not browse as
`ofm_runtime`: it may write to the historian. Structure is never changed by
hand: that is what migrations are for.

## 5. Connecting a real PLC

OFM reads controllers through OPC UA, Siemens S7 communication, or
EtherNet/IP for Rockwell Logix controllers (ADR-0017, ADR-0018). Connecting
one never needs a flow change: you describe the PLC and its tags in the model
with Mathesar, then restart the runtime. OFM only reads; it never writes to a
PLC.

This section walks through three bench PLCs, one per protocol family:
a CompactLogix (5.3), an S7-300 (5.4) and an S7-1200 (5.5). Start with any;
the CompactLogix and the S7-300 need no change to the PLC's configuration.

### 5.1 The rows behind every PLC tag

The model links a PLC tag to a topic through six tables. Fill them **in this
order**: a field with a list (*Pick a Record*) offers only rows that already
exist, so each row must be there before the next one can pick it.

| # | Table | One row per | Says |
|---|---|---|---|
| 1 | `source` | PLC (connection) | how to reach it: protocol, IP address, rack/slot |
| 2 | `area` | plant area — **only if it does not exist yet** | where in the site |
| 3 | `line` | production line — **only if it does not exist yet** | which line, in which area |
| 4 | `machine` | machine (here: one per bench PLC) | where it sits: line, name |
| 5 | `machine_property` | value | what it means: name, data type, unit, limits |
| 6 | `plc_mapping` | value | where it comes from: which source, which address, scaling |

Two examples of the rule: the *line* list in `machine` is empty until the
`line` row (step 3) exists; the *source* list in `plc_mapping` shows only
`opcplc` until the PLC's `source` row (step 1) exists.

In Mathesar (logged in as yourself, schema `config`), add a row with the **+**
below a table's last row. Leave every field not named in this section at its
default.

**Steps 2 and 3 for the bench** — once, with the first PLC; every later bench
PLC reuses them:

| # | Table | Field | Value |
|---|---|---|---|
| 2 | `area` | site | Melbourne plant |
| | | name / display_name | `bench` / `Test bench` |
| 3 | `line` | area | Test bench |
| | | name / display_name | `bench01` / `PLC test bench` |

| Controller | `protocol` | `endpoint` | `settings` |
|---|---|---|---|
| Anything with an OPC UA server | `opcua` | `opc.tcp://192.168.0.10:4840` | `{"securityMode": "None"}` |
| Siemens S7-1200 / S7-1500 | `s7` | `192.168.0.1` | `{"rack": 0, "slot": 1}` |
| Siemens S7-300 / S7-400 (incl. ET 200S IM151-8 CPU) | `s7` | `192.168.0.2` | `{"rack": 0, "slot": 2}` |
| Rockwell CompactLogix / ControlLogix | `ethernetip` | `192.168.0.3` | `{"slot": 0}` |

`settings` may also contain `"pollIntervalMs": 500` to read faster than the
default once per second (minimum 100). A polled value is sent when it
changes, and at least once per `max_publish_interval_ms` (60 s by default)
when it does not. PLCs send no timestamps, so values are stamped with the
time they arrive (`tss: "gateway"`, ADR-0003).

### 5.2 Network (every PLC)

The OFM laptop needs a cable connection to the PLC's network, next to the
engineering laptop. Containers reach the PLC through the laptop, so the
`127.0.0.1` bindings of OFM's own ports do not get in the way.

1. **Find the PLC's IP address** in its engineering tool: Studio 5000 —
   controller organiser → I/O Configuration → the controller's Ethernet port
   → Properties → Internet Protocol; TIA Portal — Device configuration → CPU →
   PROFINET interface → Ethernet addresses; SIMATIC Manager — HW Config → PN-IO
   interface of the CPU → Properties → Parameters.
2. **Connect** the OFM laptop's Ethernet port to the same switch. Wi-Fi can
   stay connected for the internet.
3. **Give the Ethernet adapter a fixed address** in the PLC's subnet that no
   other device uses (not the engineering laptop's): Settings → Network &
   internet → Ethernet → IP assignment → **Edit** → Manual → IPv4 on. Example
   for a PLC at `192.168.0.1`: IP `192.168.0.50`, subnet mask
   `255.255.255.0`, gateway and DNS empty.
4. **Test from Windows** (S7 uses port 102, EtherNet/IP port 44818):
   ```powershell
   Test-NetConnection 192.168.0.1 -Port 102
   ```
   Expect `TcpTestSucceeded : True`.
5. **Test from inside OFM's runtime** (same address and port):
   ```powershell
   docker exec ofm-nodered node -e "require('net').connect(102,'192.168.0.1').on('connect',()=>{console.log('reachable');process.exit()}).on('error',e=>{console.log(e.message);process.exit(1)})"
   ```
   Expect `reachable`.

### 5.3 Walk-through A: CompactLogix (EtherNet/IP)

**In the PLC (Studio 5000 / RSLogix 5000).** No configuration change is
needed: OFM reads tags by name. For the test, create three controller tags
that change on their own:

1. Controller Organizer → **Controller Tags** → Edit Tags; add:

   | Name | Data type |
   |---|---|
   | `OFM_Timer` | TIMER |
   | `OFM_Count` | DINT |
   | `OFM_Run` | BOOL |
   | `OFM_Speed` | REAL |

   Leave *External Access* at Read/Write (Read Only also works; None does not).
2. In MainProgram → MainRoutine, add four rungs. You can type each line into
   the rung's text editor (double-click the rung number):
   ```
   XIO OFM_Timer.DN TON OFM_Timer 1000,0
   XIC OFM_Timer.DN ADD OFM_Count 1 OFM_Count
   XIC OFM_Count.0 OTE OFM_Run
   CPT OFM_Speed "(OFM_Count MOD 100)*0.5"
   ```
   Every second `OFM_Count` goes up by one, `OFM_Run` toggles and
   `OFM_Speed` ramps 0 → 49.5 and back to 0.
3. Download (or accept the edits online) and put the controller in Run.
   *No program change at all?* Create the tags only and change their values by
   hand in Monitor Tags while you watch them arrive in OFM.

Program-scope tags are read as `Program:MainProgram.TagName`. In this step OFM
reads single values of type BOOL, SINT, INT, DINT, LINT and REAL; structures
(UDTs), strings and whole arrays come later.

**In Mathesar** (schema `config`):

| # | Table | Field | Value |
|---|---|---|---|
| 1 | `source` | name / display_name | `bench_clx` / `Bench CompactLogix` |
| | | protocol | `ethernetip` |
| | | endpoint | the PLC's IP address, e.g. `192.168.0.3` |
| | | settings | `{"slot": 0}` |
| 2–3 | `area`, `line` | | first bench PLC only: as in 5.1 |
| 4 | `machine` | line | PLC test bench |
| | | name / display_name | `compactlogix` / `Bench CompactLogix` |
| 5 | `machine_property` ×3 | machine | Bench CompactLogix |
| | | name / display_name / datatype / engineering_unit | `count` / `Count` / `int` / pcs |
| | | | `run` / `Running` / `bool` / *(empty)* |
| | | | `speed` / `Speed` / `float` / m_per_min |
| 6 | `plc_mapping` ×3 | property / source / address | Count / bench_clx / `OFM_Count` |
| | | | Running / bench_clx / `OFM_Run` |
| | | | Speed / bench_clx / `OFM_Speed` |

Leave scale factor 1 and offset 0. Then do the checks in 5.6.

### 5.4 Walk-through B: S7-300 family (SIMATIC Manager)

Example: ET 200S with IM151-8 PN/DP CPU (6ES7151-8FB01-0AB0), which is an
S7-300 CPU: rack 0, slot 2. **No configuration change is needed**: S7-300 and
S7-400 CPUs always allow S7 communication ("PUT/GET"), and their data blocks
always have fixed addresses. For the test:

1. **Clock memory** (a bit that toggles at 1 Hz): HW Config → CPU →
   Properties → *Cycle/Clock Memory* → tick **Clock memory**, memory byte
   `100`. Bit `M100.5` then toggles once per second. (If clock memory is
   already used, keep its byte and change `M100.5` below to that byte's bit 5.)
   Save and compile.
2. **Data block**: Blocks → Insert New Object → Data Block, **DB10**, with:

   | Address | Name | Type |
   |---|---|---|
   | 0.0 | `Speed` | REAL |
   | 4.0 | `Count` | DINT |
   | 8.0 | `Run` | BOOL |
   | 8.1 | `Pulse` | BOOL |

3. **Test logic**: open OB1, *View* → **STL**, and add at the end:
   ```
         A     M    100.5           // 1 Hz clock memory bit
         FP    DB10.DBX    8.1      // rising edge (edge memory: DB10 Pulse)
         JCN   OFM1
         L     DB10.DBD    4        // Count := Count + 1
         L     L#1
         +D
         T     DB10.DBD    4
         AN    DB10.DBX    8.0      // Run := NOT Run
         =     DB10.DBX    8.0
   OFM1: L     DB10.DBD    4        // Speed := (Count MOD 100) * 0.5
         L     L#100
         MOD
         DTR
         L     5.000000e-001
         *R
         T     DB10.DBD    0
   ```
4. Download HW Config, DB10 and OB1; put the CPU in RUN. In *Monitor/Modify
   Variables*, `DB10.DBD4` should count up every second.

**In Mathesar** (schema `config`):

| # | Table | Field | Value |
|---|---|---|---|
| 1 | `source` | name / display_name | `bench_s7300` / `Bench S7-300` |
| | | protocol | `s7` |
| | | endpoint | the CPU's IP address, e.g. `192.168.0.2` |
| | | settings | `{"rack": 0, "slot": 2}` |
| 2–3 | `area`, `line` | | first bench PLC only: as in 5.1 |
| 4 | `machine` | line | PLC test bench |
| | | name / display_name | `s7_300` / `Bench S7-300` |
| 5 | `machine_property` ×3 | machine | Bench S7-300 |
| | | name / display_name / datatype / engineering_unit | `count` / `Count` / `int` / pcs |
| | | | `run` / `Running` / `bool` / *(empty)* |
| | | | `speed` / `Speed` / `float` / m_per_min |
| 6 | `plc_mapping` ×3 | property / source / address | Count / bench_s7300 / `DB10,DINT4` |
| | | | Running / bench_s7300 / `DB10,X8.0` |
| | | | Speed / bench_s7300 / `DB10,REAL0` |

Then do the checks in 5.6.

### 5.5 Walk-through C: S7-1200 (TIA Portal)

Example: CPU 1212C, rack 0, slot 1. The S7-1200 needs **two settings**
before OFM can read it:

1. **Allow S7 communication**: Device configuration → CPU → Properties →
   *Protection & Security* → *Connection mechanisms* → tick **Permit access
   with PUT/GET communication from remote partner**. (If the option is
   missing, the CPU firmware is older than V4.0, where access is always
   permitted.)
2. **Clock memory**: CPU → Properties → *System and clock memory* → tick
   **Enable the use of clock memory byte**, address `100`. `%M100.5` is then
   the 1 Hz bit (TIA names it `Clock_1Hz`).
3. **Data block**: Program blocks → Add new block → Data block, name
   `OFM_Test`, **number 10** (Manual). Add the variables `Speed` (Real),
   `Count` (DInt), `Run` (Bool), `Pulse` (Bool). Then the block's Properties →
   *Attributes* → untick **Optimized block access**, and compile: the
   *Offset* column now shows 0.0, 4.0, 8.0, 8.1. Without this step the data
   block has no fixed addresses and OFM cannot read it.
4. **Test logic**: add an SCL function `OFM_Test_Logic` (Add new block →
   Function → Language SCL) with:
   ```
   IF "Clock_1Hz" AND NOT "OFM_Test".Pulse THEN
       "OFM_Test".Count := "OFM_Test".Count + 1;
       "OFM_Test".Run := NOT "OFM_Test".Run;
   END_IF;
   "OFM_Test".Pulse := "Clock_1Hz";
   "OFM_Test".Speed := DINT_TO_REAL("OFM_Test".Count MOD 100) * 0.5;
   ```
   and call it from OB1 (drag it into a network of Main).
5. Compile and download (hardware and software); put the CPU in RUN. A
   changed data block starts again from its start values.

**Security:** PUT/GET lets any device on the network read *and write* the
CPU's memory, and turning off optimised access gives the data block fixed,
predictable addresses. Do this on a bench or an isolated network only, and
agree it with the PLC's owner before doing it at a plant (STATUS open
question 24).

**In Mathesar** (schema `config`):

| # | Table | Field | Value |
|---|---|---|---|
| 1 | `source` | name / display_name | `bench_s71200` / `Bench S7-1200` |
| | | protocol | `s7` |
| | | endpoint | the CPU's IP address, e.g. `192.168.0.1` |
| | | settings | `{"rack": 0, "slot": 1}` |
| 2–3 | `area`, `line` | | first bench PLC only: as in 5.1 |
| 4 | `machine` | line | PLC test bench |
| | | name / display_name | `s7_1200` / `Bench S7-1200` |
| 5 | `machine_property` ×4 | machine | Bench S7-1200 |
| | | name / display_name / datatype / engineering_unit | `count` / `Count` / `int` / pcs |
| | | | `run` / `Running` / `bool` / *(empty)* |
| | | | `speed` / `Speed` / `float` / m_per_min |
| | | | `analog_in_0` / `Analog input 0` / `float` / pct; low `0`, high `100` |
| 6 | `plc_mapping` ×4 | property / source / address | Count / bench_s71200 / `DB10,DINT4` |
| | | | Running / bench_s71200 / `DB10,X8.0` |
| | | | Speed / bench_s71200 / `DB10,REAL0` |
| | | | Analog input 0 / bench_s71200 / `II64`, scale_factor `0.00361689814814815` |

`II64` is the 1212C's first analog input `%IW64` (0–10 V = raw 0–27648), here
scaled to 0–100 %: engineering value = raw × 100 ÷ 27648. Without anything
wired to it the value sits near 0. Then do the checks in 5.6.

### 5.6 Checks (every PLC)

1. The runtime picks up the new rows by itself within about a second of
   saving them in Mathesar. Read its log:
   ```powershell
   docker compose logs nodered --since 2m
   ```
   A line `… <address>: … - not read` names every address the PLC refused.
   The PLC's other addresses are read anyway. Typical causes are in 5.7.
2. Watch the values (Ctrl+C to stop):
   ```powershell
   docker exec -it ofm-mosquitto sh -c 'mosquitto_sub -u ofm_reader -P $OFM_MQTT_READER_PASSWORD -t acme/+/bench/# -t ofm/_system/sources/# -v'
   ```
   Expect `ofm/_system/sources/<source> {"state":"online",…}` and, about once
   a second, e.g.
   `acme/melbourne/bench/bench01/compactlogix/count {"v":1234,"ts":…,"q":"good","tss":"gateway"}`.
3. Grafana: **OFM · Live data** re-reads its *Property* list on every
   refresh (5 s); if a new property is missing, reload the page (F5). The new
   properties are in the
   *Property* list and have charts.
4. Run the tests: `docker compose run --rm test live`. Every property of
   every PLC in the model is checked end to end.
5. **Drill:** unplug the PLC's network cable. Within a few seconds the source
   shows `"state":"offline"` with the error, and every value of that PLC is
   republished with its last value and `"q":"bad"` (orange in Grafana); plug
   it back in and it is `online` again within about 15 seconds, values
   flowing with `"q":"good"`.

**If Mathesar will not accept the settings**, add the source row from
PowerShell instead (as yourself, so the audit log shows you), e.g.:
```powershell
docker exec -it ofm-timescaledb psql -U jarek -d ofm -c "INSERT INTO config.source (name, display_name, protocol, endpoint, settings) VALUES ('bench_s71200', 'Bench S7-1200', 's7', '192.168.0.1', jsonb_build_object('rack', 0, 'slot', 1))"
```
An S7 source without rack and slot is refused on purpose: the right slot
differs between CPU families.

### 5.7 When something is not read

| Symptom | Likely cause |
|---|---|
| Source `offline`, error mentions timeout or refused | wrong IP address; laptop not in the PLC's subnet; firewall; for S7, wrong rack/slot |
| S7-1200/1500: source `offline` with an access error | PUT/GET not permitted (5.5 step 1), or not downloaded |
| `DB10,…: … Object does not exist - not read` | data block number wrong, not downloaded, or still optimised (S7-1200/1500) |
| `DB10,…: … Invalid address - not read` | offset beyond the end of the data block |
| `<tag>: CIP status 5 - not read` (EtherNet/IP) | tag name misspelt, program-scope tag without `Program:<name>.`, or External Access None |
| Value arrives but is wrong | data type in the address does not match the PLC variable (e.g. `DINT` for a Real), or scaling |

### 5.8 S7 addresses: TIA Portal / SIMATIC Manager → OFM

S7 addresses in the model use the driver's notation: the area, then the data
type, then the byte offset (and bit).

| PLC address | Data type | OFM address | Model datatype |
|---|---|---|---|
| `%I0.0` / `I 0.0`, `%Q0.1`, `%M10.3` | Bool | `I0.0`, `Q0.1`, `M10.3` | `bool` |
| `%IW64` (analog input, raw 0–27648) | Int | `II64` | `float`, with scaling |
| `PIW 256` (S7-300 analog input outside the process image)¹ | Int | `PII256` | `float`, with scaling |
| `%MW20` | Int | `MI20` | `int` |
| `%MW20` | Word | `MW20` | `int` |
| `%MD100` | Real | `MR100` | `float` |
| `%MD104` | DInt | `MDI104` | `int` |
| DB10, offset 0.0 | Real | `DB10,REAL0` | `float` |
| DB10, offset 4.0 | DInt | `DB10,DINT4` | `int` |
| DB10, offset 12.0 | Int | `DB10,INT12` | `int` |
| DB10, offset 8.0 | Bool | `DB10,X8.0` | `bool` |
| DB10, offset 16.0 | String[20] | `DB10,S16.20` | `string` |

¹ Peripheral addresses are read directly from the module; not yet tested on
a real PLC.

Analog scaling, as in the PLC: engineering value = raw × `scale_factor` +
`scale_offset`. For 0–27648 → 0–100 %: factor 100 ÷ 27648 =
`0.00361689814814815`, offset 0. For 0–27648 → 4–20 mA = 0–10 bar: factor
10 ÷ 27648 = `0.000361689814814815`.

## 6. Daily operations

```powershell
docker compose logs -f nodered     # follow one service's logs
docker compose restart nodered     # restart one service
docker compose down                # stop all (volumes/data survive)
docker compose down -v             # stop AND DELETE ALL DATA — careful
```

**When the database is unavailable** (stopped, restarting, being upgraded),
live values keep flowing to the broker and the historian rows wait in a
compressed queue on disk; they are written when the database is back, so the
history has no gap. `ofm/_system/historian/ofm_runtime_01` shows `buffering`
with the number of rows waiting, and `writing` again when the queue is empty.
The queue is limited to 10 GB (about 5 months at 100 values per second); set
`OFM_SF_QUEUE_MAX_GB` in `.env` to change it. If the limit is ever reached,
the oldest rows are dropped and counted in `droppedRows` — anything above 0
needs attention.

**Upgrading OFM** (after `git pull`): back up the model first (below), then
add any new settings to `.env` and restart:
```powershell
docker run --rm -v "${PWD}:/work" -w /work alpine:3.22 sh make-env.sh
docker compose up -d --build
```
`--build` rebuilds OFM's Node-RED image if its Dockerfile changed (otherwise
it takes a second). New migrations are applied automatically before Node-RED starts. There is no
automatic rollback; the backup is the way back.

**Upgrading Node-RED or its nodes:** edit the versions in
`nodered/Dockerfile`, raise the `ofm/node-red` tag in `docker-compose.yml`,
then `docker compose up -d --build`.

**Upgrading an image** is a deliberate change: edit its version in
`docker-compose.yml`, read the release notes (TimescaleDB upgrades also need
`ALTER EXTENSION timescaledb UPDATE;`), commit, then run (two separate
commands — Windows PowerShell 5.1 does not support `&&`):
```powershell
docker compose pull
docker compose up -d
```

Data lives in named Docker volumes (`docker volume ls`), so editing the
compose file or recreating containers never loses the database, flows, or
dashboards.

**Back up the model.** The dump is written inside the container and copied
out, because PowerShell `>` redirection writes UTF-16, which `psql` cannot
restore. Backups go outside the repository so they are never committed:
```powershell
New-Item -ItemType Directory -Force C:\ofm-backups | Out-Null
docker exec ofm-timescaledb pg_dump -U ofm_admin -n config -f /tmp/config-backup.sql ofm
docker cp ofm-timescaledb:/tmp/config-backup.sql "C:\ofm-backups\config-$(Get-Date -Format yyyyMMdd-HHmm).sql"
```
Restoring is rehearsed as part of Phase 3b (Architecture Overview §16).

**Changing a password** after the first start:
- *MQTT, Node-RED and the database roles* (`ofm_runtime`, `ofm_config`,
  `ofm_reader`, `ofm_mathesar`): edit `.env`, then `docker compose up -d`.
  Each start rebuilds the broker's password file and sets the role
  passwords from `.env`. After changing `OFM_MATHESAR_DB_PASSWORD`, update
  the stored password in Mathesar's database settings too.
- *`POSTGRES_PASSWORD`* (the superuser): only applies to a brand-new database
  volume; change it in the database and in `.env` together.
- *Grafana administrator:* `GRAFANA_PASSWORD` only applies to a brand-new
  Grafana volume. To make an existing Grafana match `.env`:
  ```powershell
  docker exec ofm-grafana grafana cli admin reset-admin-password NewPassword
  ```
- *`NODE_RED_CREDENTIAL_SECRET`:* never change it; stored Node-RED
  credentials would become unreadable.

## Installing without internet (plant LAN)

Most plant installations have no internet access. Once its images are on the
machine, OFM needs none: every service runs offline. Only the installation
needs the images brought in — saved with `docker save` on a PC that has
internet, carried over, and loaded with `docker load` (or pulled from an
internal registry). A packaged offline bundle is prepared before the plant
pilot (`docs/STATUS.md`, Stage C).

## Gotchas worth knowing

- **The init script runs once.** `db/init/001-init.sh` executes only when the
  `tsdb-data` volume is empty and creates only the roles and schemas. All
  structure after that is in `db/migrations/`, which must never be edited
  once applied (the runner refuses; see `db/migrations/README.md`).
- **Line endings.** `make-env.sh` and `db/init/001-init.sh` must keep Linux
  (LF) line endings or they fail inside a container. `.gitattributes` enforces this for Git; do not
  re-save it from an editor set to Windows line endings.
- **Operator dashboards are not covered by the editor login.** Node-RED
  Dashboard pages are protected separately when they are built (Phase 3a).
- **Flows folder permissions on Linux.** Node-RED runs as user 1000 and
  writes `flows/` on Deploy; on a Linux host that folder must be writable by
  uid 1000 (`chown -R 1000:1000 flows`). Docker Desktop on Windows needs
  nothing.
- **Access from other devices** is deliberately impossible while ports are
  bound to `127.0.0.1`. Opening a service to the network is a security
  decision (Architecture Overview §13), not a configuration tweak.
- **Port collisions.** If a port is taken on Windows, change only the host
  port in `docker-compose.yml` (e.g. `"127.0.0.1:15432:5432"`).
- **Clock discipline (ADR-0003).** If timestamps drift after sleep/resume,
  `wsl --shutdown` and restart Docker Desktop — and the laptop should not be
  sleeping anyway.
