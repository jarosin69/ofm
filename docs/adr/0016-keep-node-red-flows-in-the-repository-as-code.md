# ADR-0016: Keep OFM's Node-RED flows in the repository as code

- **Status:** Accepted
- **Date:** 2026-10-25
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** runtime, ops

## Context

Node-RED keeps its flows in a file inside its data volume and offers no
version history. If OFM's flows lived only there, the repository and the
running system would drift apart, and a plant could end up with an
undocumented one-off version — the PLC equivalent of a program edited online
with no master copy. Because OFM is model-driven, its flows are generic: all
plant-specific detail is in the model, so the flows should change rarely and
every change should be traceable.

Credentials are the obstacle. Node-RED stores credentials in a separate file
encrypted with a key unique to each installation, so that file cannot travel
through Git.

## Decision

1. **The flow file is in the repository.** `flows/ofm-runtime.json` is
   Node-RED's flow file: the repository's `flows/` folder is mounted into the
   container and `settings.js` points `flowFile` at it, so **Deploy** in the
   editor writes straight into the working copy. A change is reviewed with
   `git diff` and committed like a migration.
2. **No secrets in flows.** Flows never store passwords. They read them from
   environment variables at run time: the MQTT connection is opened by the
   flow with the password from `env.get(...)`; database nodes take user and
   password from environment variables. The credentials file, if Node-RED
   creates one, is ignored by Git.
3. **OFM flows contain only generic logic.** Experiments go on separate tabs
   and are deleted before committing; `git status` shows any that slip in.
4. **Checks are separate files.** Importable diagnostic flows live in
   `flows/checks/` and are never part of the runtime flow.
5. **Plants run what is committed.** At a plant (Stage C) the flows folder
   will be mounted read-only and the editor opened read-only, so the running
   flows are always a released version.

## Alternatives considered

1. **Flows live in Node-RED, exported to Git now and then** — simpler day to
   day, but drift is certain and invisible. Rejected.
2. **Node-RED Projects** (built-in Git support in the editor) — capable, but
   puts Git operations and SSH keys inside the runtime container and adds a
   second way of working next to the rest of the repository. Rejected for v1.
3. **Generate flows from code at build time** — maximum control, but OT
   engineers could no longer edit and read flows naturally in the editor.
   Rejected.

## Consequences

- Positive: one master copy; every installation runs the same flows; changes
  are reviewed and reversible; nothing secret is ever in a file.
- Negative / cost: the first Deploy from the editor may reformat the file
  (one noisy diff); editor experiments must be kept out of commits; on Linux
  hosts the flows folder must be writable by the container user (uid 1000).
- Follow-up work: read-only mounting and a read-only editor role for plants
  (Stage C).

## Notes / references

- Related: ADR-0012 (migrations follow the same "code in Git" rule),
  ADR-0017 (the acquisition code inside the flow).

## Amendments

- 2026-10-26: **Dashboards follow the same rule.** OFM's Grafana dashboards
  are JSON files in `deploy/grafana/dashboards/`, provisioned read-only into
  the Grafana folder "OFM" at start-up. Users experiment with copies
  ("Save as"); a change to an OFM dashboard is a change to its file, committed.
- 2026-10-26: **`FLOWS`, not `flowFile`.** The official Node-RED image passes
  its `FLOWS` environment variable on the command line, which overrides
  `flowFile` in `settings.js`; OFM therefore sets `FLOWS`.
