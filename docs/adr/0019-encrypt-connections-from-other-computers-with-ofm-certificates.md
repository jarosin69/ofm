# ADR-0019: Encrypt connections from other computers with OFM's own certificates

- **Status:** Accepted
- **Date:** 2026-10-31
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** security, ops

## Context

Until Phase 2 every OFM port was bound to `127.0.0.1`: usable only on the
OFM computer itself, and unencrypted. At a plant, other computers must
connect: engineers' PCs (MQTT Explorer, browsers), SCADA and MES clients.
Plain MQTT and plain HTTP would carry the MQTT, Grafana, Mathesar and
Node-RED logins across the plant network as readable text, and let any
machine pose as the broker. Architecture Overview §13 already promised
"MQTT-over-TLS" for anything that leaves the server.

A plant may or may not have an IT department able to issue certificates,
and OFM must install offline (Overview §14). Traffic between OFM's own
containers never leaves the computer. No client outside the server needs the
database yet.

## Decision

1. **Encrypt every entrance other computers use, and only those.** MQTT over
   TLS on port 8883 (Mosquitto); HTTPS for Grafana (3000), Mathesar (8080)
   and the Node-RED editor (1880) through one front door, **Caddy**
   (`proxy` service), which keeps each page on its familiar port. Plain MQTT
   (1883) and the services' own plain ports stay inside Docker's internal
   network and are not published. The database stays on `127.0.0.1` until a
   remote client needs it (then a new decision).
2. **Who may connect is one setting.** The encrypted ports listen on
   `OFM_LISTEN_ADDRESS` from `.env`: `127.0.0.1` (default, this computer) or
   `0.0.0.0` (the network).
3. **OFM makes its own certificates by default.** A one-shot `certs` service
   (`tools/certs.sh`, using openssl from OFM's Node-RED image, so nothing is
   downloaded) creates a certificate authority (CA; 10 years) and a server
   certificate (825 days) naming `localhost`, the Compose service names and
   `OFM_TLS_NAMES` from `.env`. It runs on every start and reissues the
   server certificate when the names change, when fewer than 30 days remain,
   or when the CA changed. Clients trust `deploy/certs/ofm-ca.crt`.
4. **Certificates from plant IT drop in** (`certs import`), are checked
   (signed by the given CA, key matches), and are never replaced
   automatically; expiry is warned.
5. **Private keys live only in the Docker volume `certs`**, never in the
   repository folder; only the public `ofm-ca.crt` is copied out, and
   `deploy/certs/` is ignored by Git.

## Alternatives considered

1. **TLS in each application** (Grafana and Node-RED can serve HTTPS
   themselves) — Mathesar cannot (its own distribution puts Caddy in front);
   three configurations instead of one, and certificate renewal touching
   three services. Rejected for one front door.
2. **nginx instead of Caddy** — equally capable and better known; needs
   explicit WebSocket and header settings that Caddy does by default.
   Either is defensible; Caddy gives the shorter, safer configuration.
3. **Certificates only from plant IT** — the best end state, but it blocks
   installation and testing until IT is involved, and some sites have no
   such service. Kept as the drop-in option.
4. **Self-signed server certificate without a CA** — every renewal would
   force every client to trust a new file; a CA is trusted once for 10 years.
5. **Encrypt container-to-container traffic too** — no attacker position on
   a single host that TLS would close; more certificates and failure modes.

## Consequences

- Positive: logins and plant data are encrypted on the network; clients can
  verify they talk to the real broker; opening OFM to the network is two
  `.env` lines; works offline; plant IT certificates fit without code changes.
- Negative / cost: each client computer must install `ofm-ca.crt` once
  (browsers warn until then); a renewed or reissued certificate takes effect
  after `docker compose restart mosquitto proxy`; one more pinned image
  (`caddy:2.11.7-alpine`) for the offline bundle; whoever holds the `certs`
  volume can issue certificates clients trust, so it is protected like
  `.env`; deleting the volume creates a new CA that every client must trust
  again.
- Follow-up work: PostgreSQL over TLS when a remote database client is
  needed; client-certificate login for machine clients if the plant asks.

## Notes / references

- Project rule amended with this ADR: secrets live in `deploy/.env`, the
  Mosquitto password file, and the `certs` volume — never in tracked files.
- Mathesar trusts the proxy's `X-Forwarded-Proto` (its production settings),
  so its login works behind Caddy; its `ALLOWED_HOSTS` include `OFM_TLS_NAMES`.
- Related: Overview §13 (security), §14 (deployment); ADR-0013 (Mathesar).

## Amendments

- 2026-11-01: **Explained, with figures, in Architecture Overview §13.1.**
  Clarified: trust in `ofm-ca.crt` belongs to a client *device* (browser or
  MQTT client), not to a user or login, and is installed once per device for
  the life of the CA; renewing the server certificate never involves clients.
  For a plant with many viewing devices (PCs, tablets, operator panels),
  plant IT certificates (decision 4) or distributing `ofm-ca.crt` through
  IT's device management are the practical routes; installing by hand suits
  a few engineering PCs.
