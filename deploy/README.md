# OFM Proof of Concept — Windows 11 setup

This folder is the complete PoC environment: TimescaleDB, Mosquitto,
Node-RED, Grafana and NocoDB as separate containers under Docker Compose.
The same file, with different `.env` values, is the plant deployment
(Architecture Overview §14).

> **Before connecting this laptop to any OT network**, complete the deploy-kit
> hardening listed in `docs/STATUS.md`: Node-RED editor login (`adminAuth`),
> service ports bound to the laptop only, Mosquitto ACLs, and database role
> passwords taken from `.env`. An unprotected Node-RED editor lets anyone who
> can reach it deploy code that runs next to your PLCs.

## 1. Prepare Windows

1. **Check virtualisation is enabled.** Task Manager → Performance → CPU →
   "Virtualization: Enabled". If it says Disabled, enable Intel VT-x / AMD-V
   in the BIOS/UEFI first.
2. **Install WSL2.** Open PowerShell *as Administrator*:
   ```powershell
   wsl --install
   ```
   Reboot when prompted. (On up-to-date Windows 11 this one command installs
   the WSL2 kernel and an Ubuntu distribution. If WSL was already present,
   run `wsl --update` instead.)
3. **Install Docker Desktop** from https://www.docker.com/products/docker-desktop/.
   During setup, keep **"Use WSL 2 based engine"** checked (it is the default).
   Start Docker Desktop once and let it finish initialising.
   In Docker Desktop → Settings → General, enable **"Start Docker Desktop
   when you sign in"** — a historian that starts on demand records nothing.

   *Licensing:* Docker Desktop is free for personal use, education and small
   businesses only. For use within a larger organisation, either obtain a
   subscription or install the free Docker Engine directly inside the WSL2
   Ubuntu distribution instead; the Compose file is identical either way.
4. **Stop the laptop from sleeping.** Settings → System → Power → Screen and
   sleep → set "When plugged in, put my device to sleep" to **Never**. Also
   disable Fast Startup (Control Panel → Power Options → Choose what the
   power buttons do → untick "Turn on fast startup") — it can leave the WSL
   VM in a stale state across reboots.
5. *(Optional but recommended)* Cap the WSL VM so it never starves Windows.
   Create `C:\Users\<you>\.wslconfig`:
   ```ini
   [wsl2]
   memory=6GB
   processors=4
   ```
   Then `wsl --shutdown` once; Docker Desktop will restart the VM.

## 2. Prepare the project

6. Clone the repository to `C:\ofm`; this guide assumes you work from
   `C:\ofm\deploy` (any path without spaces works).
7. In `C:\ofm\deploy`, copy `.env.example` to `.env` and set real passwords.
   Secrets live only in `.env` and the Mosquitto `passwd` file; both are
   excluded from Git by `.gitignore`, and nothing else in the repository may
   contain a password.
8. Create the MQTT users (Mosquitto refuses anonymous connections).
   In PowerShell, from `C:\ofm\deploy`:
   ```powershell
   docker run --rm -v ${PWD}\mosquitto\config:/mosquitto/config eclipse-mosquitto:2 `
     mosquitto_passwd -c -b /mosquitto/config/passwd ofm_runtime YourMqttPassword
   ```
   Add a second user for consumers (Grafana, Python, debug clients):
   ```powershell
   docker run --rm -v ${PWD}\mosquitto\config:/mosquitto/config eclipse-mosquitto:2 `
     mosquitto_passwd -b /mosquitto/config/passwd ofm_reader AnotherPassword
   ```
   (Use `-c` only on the first command — it creates the file; the second
   appends.) The intent is that `ofm_reader` may only subscribe; this is
   enforced once the Mosquitto ACL file is added (Architecture Overview §13).
   Passwords typed this way remain in PowerShell's command history; clear it
   with `Clear-History` and by deleting
   `(Get-PSReadLineOption).HistorySavePath` if that matters to you.

## 3. Start and verify

9. From `C:\ofm\deploy` in PowerShell:
   ```powershell
   docker compose up -d
   docker compose ps
   ```
   All five services should reach "running" (TimescaleDB shows "healthy"
   after ~15 s).
10. Verify each component:
    - **TimescaleDB** — `docker exec -it ofm-timescaledb psql -U ofm_admin -d ofm -c "\dn"`
      should list the `config` and `hist` schemas (proves the init script ran).
    - **Mosquitto** — open two PowerShell windows:
      ```powershell
      docker exec -it ofm-mosquitto mosquitto_sub -u ofm_reader -P AnotherPassword -t "test/#" -v
      docker exec -it ofm-mosquitto mosquitto_pub -u ofm_runtime -P YourMqttPassword -t test/hello -m "ofm"
      ```
      The subscriber window should print `test/hello ofm`.
    - **Node-RED** — http://localhost:1880
    - **Grafana** — http://localhost:3000 (login from `.env`)
    - **NocoDB** — http://localhost:8080 (create the local account on first visit)

## 4. First wiring (do once)

11. **Node-RED palettes.** Menu → Manage palette → Install:
    `node-red-contrib-opcua`, `node-red-contrib-s7`, `node-red-contrib-modbus`,
    `node-red-contrib-postgresql`, `@flowfuse/node-red-dashboard`.
    (The OPC UA package compiles native modules — allow several minutes.)
12. **Container-to-container addresses.** Inside flows and datasources, use
    Compose service names, never `localhost`:
    - MQTT broker host: `mosquitto`, port 1883
    - PostgreSQL host: `timescaledb`, port 5432, database `ofm`

    `localhost` works only from Windows itself (your browser, MQTT Explorer).
13. **Grafana datasource.** Connections → Data sources → PostgreSQL:
    host `timescaledb:5432`, database `ofm`, user `ofm_reader` with the
    password set for that role by the database init script, TLS disabled
    (PoC), and enable the TimescaleDB option.
14. **NocoDB connection.** Create a Base → external PostgreSQL:
    host `timescaledb`, port 5432, database `ofm`, user `ofm_config`,
    schema `config`. (Empty until the Phase 1 DDL lands.) NocoDB connects
    with this one role for every user, so per-person change history comes
    from NocoDB's own audit log (Architecture Overview §11).

## 5. Reaching a real PLC later

Containers reach your LAN through outbound NAT, which is exactly what
S7/Modbus/OPC UA polling needs — Node-RED simply opens outbound TCP to the
PLC's IP. When the time comes (and after the hardening note at the top):
connect the laptop to the OT network by **Ethernet**, give it an address in
the PLC subnet, and test reachability from inside the container first:
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

**Upgrading images** is deliberate, never routine: change the image version
in `docker-compose.yml`, commit the change, then run (two separate commands —
Windows PowerShell 5.1 does not support `&&`):
```powershell
docker compose pull
docker compose up -d
```

Data lives in named Docker volumes (`docker volume ls`), so editing the
compose file or recreating containers never loses the database, flows, or
dashboards.

**Back up the model.** The dump is written inside the container and copied
out, because PowerShell `>` redirection writes UTF-16, which `psql` cannot
restore. Backups go to a folder outside the repository so they can never be
committed by accident:
```powershell
New-Item -ItemType Directory -Force C:\ofm-backups | Out-Null
docker exec ofm-timescaledb pg_dump -U ofm_admin -n config -f /tmp/config-backup.sql ofm
docker cp ofm-timescaledb:/tmp/config-backup.sql "C:\ofm-backups\config-$(Get-Date -Format yyyyMMdd-HHmm).sql"
```
Restoring is rehearsed as part of Phase 3 (Architecture Overview §16).

## Gotchas worth knowing

- **Port collisions.** If 5432/3000/1880/8080 are taken on Windows, change
  only the left (host) side of the mapping in `docker-compose.yml`
  (e.g. `"15432:5432"`).
- **The init script runs once.** `db/init/*` executes only when the
  `tsdb-data` volume is empty. To re-run it, `docker compose down -v` (data
  loss). From Phase 1, schema changes travel as migrations in
  `db/migrations/` instead.
- **Access from other devices.** The PoC is meant to be used from the laptop
  itself. Making Grafana, MQTT or anything else reachable from other devices
  is a deliberate security decision (Architecture Overview §13), not a
  firewall tweak.
- **Clock discipline (ADR-0003).** Windows NTP keeps the WSL VM in sync
  after sleep/resume on current builds, but if you ever see timestamps
  drift after resume, `wsl --shutdown` and restart Docker Desktop — and
  remember the laptop shouldn't be sleeping anyway.
