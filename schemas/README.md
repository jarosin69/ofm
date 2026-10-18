# OFM payload contracts

These JSON Schema files (draft 2020-12) are the **normative** definition of every
MQTT payload OFM publishes. A JSON Schema is to a payload what a GSD file is to a
fieldbus device: a machine-checkable description of a valid telegram. When the
Architecture Overview and a schema disagree, the schema wins.

## Topic → schema map

| Topic | Schema | Retained | Phase |
|---|---|---|---|
| `{enterprise}/{site}/{area}/{line}/{machine}/{property}` (and sub-asset properties one level deeper) | `value.schema.json` | yes | 1 |
| `…/{property}/_meta` | `meta.schema.json` | yes | 2 |
| `ofm/_unmapped/{source}/{address}` | `unmapped.schema.json` | no | 1 |
| `ofm/_system/sources/{source}` | `system-source.schema.json` | yes | 1 |
| `ofm/_system/runtime/{runtime}` | `system-runtime.schema.json` | yes | 1 |
| `ofm/_system/cache/{runtime}` | `system-cache.schema.json` | yes | 1 |
| `ofm/_system/historian/{runtime}` | `system-historian.schema.json` | yes | 2 |
| `{enterprise}/{site}/{area}/{line}/workorder` | `workorder.schema.json` | yes | 3a |

`common.schema.json` holds shared definitions (timestamp, quality, timestamp
provenance, IDs) and is referenced by the others; it is not a payload.

Not yet specified, deliberately: machine state (`…/{machine}/state`, Phase 3a),
line KPIs (`…/{line}/kpi/{name}`, Phase 3b), state health
(`ofm/_system/state_health`, Phase 3) and write-back commands (`ofm/_cmd/…`).
Each gets its schema in the phase that builds it.

## Rules every payload follows

- **Timestamps** are integers, epoch milliseconds UTC (ADR-0003). The schemas
  reject values outside 2020–2100, which catches timestamps sent in seconds or
  microseconds by mistake.
- **Key names** in JSON payloads are camelCase (`propertyId`, `maxPublishIntervalMs`).
  The live value uses the terse keys `v`, `ts`, `q`, `tss` because it is the
  highest-volume payload. Database columns stay snake_case (ADR-0005).
- **Strict producers, tolerant consumers.** The schemas forbid unknown keys, so a
  misspelt key is caught when the runtime is tested. Consumers, however, must
  ignore keys they do not recognise, so that adding an optional field never
  breaks them.
- **Empty retained message = deletion.** A zero-byte retained message on a value or
  `_meta` topic is not a payload: it clears a renamed or retired property from
  the broker (ADR-0004). Consumers must treat it as "this topic no longer exists".
- **`v: null` only with `q: "bad"`.** JavaScript turns `NaN` into `null` when
  serialising, so this rule also catches a broken scaling calculation that would
  otherwise publish a "good" null.

## Changing a schema

- **Compatible change** (a new optional field, a looser limit): edit the schema
  in place, add examples, commit.
- **Incompatible change** (renaming or removing a field, changing its meaning or
  type, making a field required): increase the version number at the end of the
  `$id` (`urn:ofm:schema:value:1` → `:2`) and record the change in an ADR,
  because every consumer is affected.

## Testing

Every schema has example payloads in `tests/schemas/<schema>/valid/` (must pass)
and `tests/schemas/<schema>/invalid/` (must fail). Run the check from `C:\ofm`;
it needs no local Python, only Docker:

```powershell
docker run --rm -v ${PWD}:/repo -w /repo python:3.12-slim `
  sh -c "pip install -q jsonschema && python tools/validate_schemas.py"
```

The last line must read `… examples checked, 0 failure(s).` Run it after every
schema change, and add an example for every rule you add.
