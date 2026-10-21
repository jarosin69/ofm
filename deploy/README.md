# OFM Proof of Concept — Windows 11 setup

This folder is the complete PoC environment: TimescaleDB, Mosquitto,
Node-RED, Grafana and NocoDB as separate containers under Docker Compose.
The same file, with different `.env` values, is the plant deployment
(Architecture Overview §14).

The kit is hardened for a single laptop (Architecture Overview §13):

- every service port is bound to `127.0.0.1`, so it is reachable from this
  laptop only;
- all passwords live in one generated file, `.env` (never committed); the
  database roles, MQTT users and Grafana datasource are created from it;
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
   every service and prints the two logins you need. It runs inside a small
   throw-away container, so nothing needs installing, and the same command
   works in a Linux shell:
   ```powershell
   docker run --rm -v "${PWD}:/work" -w /work alpine:3.22 sh make-env.sh
   ```
   Save a copy of `.env` in a password manager: it is the only place these
   passwords exist, and it is never committed to Git. The script refuses to
   overwrite an existing `.env`.
8. **Start the stack:**
   ```powershell
   docker compose up -d
   docker compose ps
   ```
   The first start downloads the images (a few minutes). All five services
   should then be "running", TimescaleDB "healthy" after about 15 s.

That is the whole installation. On first start the stack creates the database
roles, the MQTT users and the Grafana datasource from `.env` by itself.

## 3. Check it works

9. **Logins** (users and passwords were printed by step 7; they are also in
   `.env`):
   - **Node-RED** — http://localhost:1880 must ask for a login.
   - **Grafana** — http://localhost:3000. Then Connections → Data sources →
     **OFM historian** → **Test** must report success.
   - **NocoDB** — http://localhost:8080 (create the local account on first
     visit).
10. **Database** — schemas and roles exist:
    ```powershell
    docker exec ofm-timescaledb psql -U ofm_admin -d ofm -c "\dn" -c "\du"
    ```
    Expect schemas `config` and `hist`, and roles `ofm_runtime`,
    `ofm_config`, `ofm_reader`.
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

## 4. First wiring (do once)

12. **Node-RED palettes.** Menu → Manage palette → Install:
    `node-red-contrib-opcua`, `node-red-contrib-s7`, `node-red-contrib-modbus`,
    `node-red-contrib-postgresql`, `@flowfuse/node-red-dashboard`.
    (The OPC UA package compiles native modules — allow several minutes.)
13. **Container-to-container addresses.** Inside flows and datasources, use
    Compose service names, never `localhost`:
    - MQTT broker host: `mosquitto`, port 1883
    - PostgreSQL host: `timescaledb`, port 5432, database `ofm`

    `localhost` works only from Windows itself (your browser, MQTT Explorer).
14. **Passwords in flows.** Node-RED receives `OFM_RUNTIME_DB_PASSWORD` and
    `OFM_MQTT_RUNTIME_PASSWORD` as environment variables, so flows refer to
    them as `${OFM_RUNTIME_DB_PASSWORD}` instead of storing the password.
    The exact use is set up with the first Phase 1 flow.
15. **NocoDB connection.** Create a Base → external PostgreSQL:
    host `timescaledb`, port 5432, database `ofm`, user `ofm_config`,
    password `OFM_CONFIG_DB_PASSWORD` from `.env`, schema `config`. (Empty
    until the Phase 1 migrations land.) NocoDB connects with this one role for
    every user, so per-person change history comes from NocoDB's own audit log
    (Architecture Overview §11).

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

Until then, develop against simulation: an `inject` node producing raw
values, or a local OPC UA test server, exercises the entire pipeline
identically.

## 6. Daily operations

```powershell
docker compose logs -f nodered     # follow one service's logs
docker compose restart nodered     # restart one service
docker compose down                # stop all (volumes/data survive)
docker compose down -v             # stop AND DELETE ALL DATA — careful
```

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
- *MQTT and Node-RED:* edit `.env`, then `docker compose up -d` (the broker
  rebuilds its password file at every start; Node-RED reads its login at
  start).
- *Database roles:* the init script does not run again, so change the role
  in the database as well as in `.env`, then `docker compose up -d`:
  ```powershell
  docker exec ofm-timescaledb psql -U ofm_admin -d ofm -c "ALTER ROLE ofm_reader PASSWORD 'NewPassword'"
  ```
- *Grafana administrator:* `GRAFANA_PASSWORD` only applies to a brand-new
  Grafana volume. To make an existing Grafana match `.env`:
  ```powershell
  docker exec ofm-grafana grafana cli admin reset-admin-password NewPassword
  ```
- *`NODE_RED_CREDENTIAL_SECRET`:* never change it; stored Node-RED
  credentials would become unreadable.

## Gotchas worth knowing

- **The init script runs once.** `db/init/001-init.sh` executes only when the
  `tsdb-data` volume is empty. From Phase 1, schema changes travel as
  migrations in `db/migrations/`.
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
