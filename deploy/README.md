# OFM Proof of Concept — Windows 11 setup

This folder is the complete PoC environment: TimescaleDB, Mosquitto,
Node-RED, Grafana and NocoDB as separate containers under Docker Compose.
The same file, with different `.env` values, is the plant deployment.

## 1. Prepare Windows

1. **Check virtualization is enabled.** Task Manager → Performance → CPU →
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
   Start Docker Desktop once and let it finish initializing.
   In Docker Desktop → Settings → General, enable **"Start Docker Desktop
   when you sign in"** — a historian that starts on demand records nothing.
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

6. Clone the repository to `C:\ofm`; this deploy guide assumes you work from `C:\ofm\deploy` (any path without spaces works).
7. In `C:\ofm\deploy`, copy `.env.example` to `.env` and set real passwords.
8. Create the MQTT user (Mosquitto refuses anonymous connections).
   In PowerShell, from `C:\ofm\deploy`:
   ```powershell
   docker run --rm -v ${PWD}\mosquitto\config:/mosquitto/config eclipse-mosquitto:2 `
     mosquitto_passwd -c -b /mosquitto/config/passwd ofm_runtime YourMqttPassword
   ```
   Add a second, subscribe-side user (Grafana/Python/debug clients):
   ```powershell
   docker run --rm -v ${PWD}\mosquitto\config:/mosquitto/config eclipse-mosquitto:2 `
     mosquitto_passwd -b /mosquitto/config/passwd ofm_reader AnotherPassword
   ```
   (Note: `-c` only on the first command — it creates the file; the second
   appends.)

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
    host `timescaledb:5432`, database `ofm`, user `ofm_reader`,
    TLS disabled (PoC), and enable the TimescaleDB option.
14. **NocoDB connection.** Create a Base → external PostgreSQL:
    host `timescaledb`, port 5432, database `ofm`, user `ofm_config`,
    schema `config`. (Empty until the Phase 1 DDL lands.)

## 5. Reaching a real PLC later

Containers reach your LAN through outbound NAT, which is exactly what
S7/Modbus/OPC UA polling needs — Node-RED simply opens outbound TCP to the
PLC's IP. When the time comes: connect the laptop to the OT network by
**Ethernet**, give it an address in the PLC subnet, and test reachability
from inside the container first:
```powershell
docker exec -it ofm-nodered ping <plc-ip>
```
Until then, develop against simulation: an `inject` node producing raw
values, or a public/local OPC UA test server, exercises the entire
pipeline identically.

## 6. Daily operations

```powershell
docker compose logs -f nodered     # follow one service's logs
docker compose restart nodered     # restart one service
docker compose down                # stop all (volumes/data survive)
docker compose down -v             # stop AND DELETE ALL DATA — careful
docker compose pull && docker compose up -d   # upgrade images
```

Data lives in named Docker volumes (`docker volume ls`), so editing the
compose file or recreating containers never loses the database, flows, or
dashboards. Back up the model with:
```powershell
docker exec ofm-timescaledb pg_dump -U ofm_admin -n config ofm > config-backup.sql
```

## Gotchas worth knowing

- **Port collisions.** If 5432/3000/1880/8080 are taken on Windows, change
  only the left side of the mapping in `docker-compose.yml`
  (e.g. `"15432:5432"`).
- **The init script runs once.** `db/init/*.sql` executes only when the
  `tsdb-data` volume is empty. To re-run it, `docker compose down -v` (data
  loss) — after Phase 1, schema changes travel as migrations instead.
- **Windows Firewall.** Accessing Grafana/MQTT from *other* devices on your
  network requires allowing those inbound ports on Windows; from the laptop
  itself, nothing is needed.
- **Clock discipline (ADR-0003).** Windows NTP keeps the WSL VM in sync
  after sleep/resume on current builds, but if you ever see timestamps
  drift after resume, `wsl --shutdown` and restart Docker Desktop — and
  remember the laptop shouldn't be sleeping anyway.
