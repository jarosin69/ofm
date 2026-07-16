# OFM — Open Factory Model

An open-source, model-driven industrial data platform: a Unified Namespace
(MQTT) generated from an Industrial Information Model (PostgreSQL/TimescaleDB),
executed by Node-RED, visualized in Grafana.

**Status: early development (pre-Phase-1). Not yet ready for production use.**

## The idea in three sentences

Every asset, property, unit, limit, and PLC mapping in the factory is a row
in a relational model — the single authoritative description of the plant.
The runtime reads that model and does the rest: acquires values from PLCs,
normalizes and contextualizes them, publishes them to an ISA-95-style MQTT
namespace, and records them in a historian. Adding a sensor means inserting
rows, not editing flows.

## Where everything lives

| Path | Contents |
|---|---|
| `docs/architecture-overview.md` | **Start here.** What OFM is and why it is shaped this way |
| `docs/adr/` | Architecture Decision Records — the *why* behind contested choices |
| `docs/generated/` | Docs generated from the model (topic tree, data dictionary) — do not edit |
| `schemas/` | JSON Schemas for payloads — normative |
| `db/migrations/` | Numbered SQL migrations — the database structure, normative |
| `deploy/` | Docker Compose stack and setup guide (see `deploy/README.md`) |
| `flows/` | Exported Node-RED flows |
| `tools/` | Generators and utilities (e.g. docs from the model) |
| `tests/` | Schema tests, pipeline tests, failure drills |

## Quick start

See [`deploy/README.md`](deploy/README.md) for the full Windows 11 / Docker
setup procedure. Short version: copy `deploy/.env.example` to `deploy/.env`,
create the Mosquitto password file, then `docker compose up -d` from `deploy/`.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
