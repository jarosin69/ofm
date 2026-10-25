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
   - **Mathesar** — http://localhost:8080; the first visit is described in steps 15–16.
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

## 4. First wiring (do once)

13. **Container-to-container addresses.** Inside flows and datasources, use
    Compose service names, never `localhost`:
    - MQTT broker host: `mosquitto`, port 1883
    - PostgreSQL host: `timescaledb`, port 5432, database `ofm`

    `localhost` works only from Windows itself (your browser, MQTT Explorer).
14. **Node-RED nodes and passwords in flows.** OFM's Node-RED image comes with
    the OPC UA, S7, PostgreSQL and dashboard nodes built in at pinned versions
    (`nodered/Dockerfile`), so nothing is installed from the internet. Do not
    install or update these through *Manage palette*: a palette copy would
    compete with the built-in one. A Modbus node is added when the first
    Modbus device needs it. **Passwords:** Node-RED receives `OFM_RUNTIME_DB_PASSWORD` and
    `OFM_MQTT_RUNTIME_PASSWORD` as environment variables, so flows refer to
    them as `${OFM_RUNTIME_DB_PASSWORD}` instead of storing the password.
    The exact use is set up with the first Phase 1 flow.
15. **Mathesar, first visit** (the model editor, ADR-0013). Open
    http://localhost:8080. Mathesar asks once for an administrator account:
    enter `MATHESAR_ADMIN_USER` and `MATHESAR_ADMIN_PASSWORD` from `.env`. This
    account is local to Mathesar on this machine; nothing is sent anywhere.
16. **Connect Mathesar to the model.** In Mathesar, connect an existing
    database with:
    - host `timescaledb`, port `5432`, database `ofm`
    - role `ofm_mathesar`, password `OFM_MATHESAR_DB_PASSWORD` from `.env`

    On this first connection Mathesar adds its own helper schemas (`msar`,
    `mathesar_types`) to the database; that is expected. Then open the
    `config` schema: these are the model tables shown in
    `docs/generated/erd.md`. `vw_runtime_model` shows every topic.
17. **A personal login for each person who edits the model** (recommended):
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
for everyday browsing, so nothing can be changed by accident. Structure is
never changed by hand: that is what migrations are for.

## 5. Reaching a real PLC later

Containers reach your LAN through outbound NAT, which is exactly what
S7/Modbus/OPC UA polling needs — Node-RED opens outbound TCP to the PLC's IP.
Binding the service ports to `127.0.0.1` does not affect this. When the time
comes, connect the laptop to the OT network by **Ethernet**, give it an
address in the PLC subnet, and test reachability from inside the container:
```powershell
docker exec -it ofm-nodered ping <plc-ip>
```
For a Siemens S7-1200/1500, enable PUT/GET communication in the CPU
properties and disable optimised block access on the data blocks to be read.
S7 polling provides no device timestamp, so S7 values are always stamped
`tss: "gateway"` (ADR-0003). OPC UA subscriptions provide device time.

Until then, develop against the OPC UA simulator in the stack: it exercises
the entire pipeline identically, and the real PLC is simply a second `source`
row in the model.

## 6. Daily operations

```powershell
docker compose logs -f nodered     # follow one service's logs
docker compose restart nodered     # restart one service
docker compose down                # stop all (volumes/data survive)
docker compose down -v             # stop AND DELETE ALL DATA — careful
```

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
- **Access from other devices** is deliberately impossible while ports are
  bound to `127.0.0.1`. Opening a service to the network is a security
  decision (Architecture Overview §13), not a configuration tweak.
- **Port collisions.** If a port is taken on Windows, change only the host
  port in `docker-compose.yml` (e.g. `"127.0.0.1:15432:5432"`).
- **Clock discipline (ADR-0003).** If timestamps drift after sleep/resume,
  `wsl --shutdown` and restart Docker Desktop — and the laptop should not be
  sleeping anyway.
