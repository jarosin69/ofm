// Payload contracts: loads schemas/*.schema.json once and checks payloads
// against the schema that belongs to their topic (schemas/README.md).
"use strict";
const path = require("path");
const fs = require("fs");
const { ROOT, fromNodeRed, readJson } = require("./harness");

const SCHEMA_DIR = path.join(ROOT, "schemas");

let cache = null;

function load() {
  if (cache) return cache;
  const Ajv2020 = fromNodeRed("ajv/dist/2020");
  // strict: false - the schemas use keywords such as maxLength next to a
  // list of types, which is valid JSON Schema but which Ajv's extra
  // "strict mode" style rules would complain about.
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  const schemas = {};
  for (const file of fs.readdirSync(SCHEMA_DIR).filter(f => f.endsWith(".schema.json")).sort()) {
    const name = file.replace(/\.schema\.json$/, "");
    schemas[name] = readJson(path.join(SCHEMA_DIR, file));
    ajv.addSchema(schemas[name]);              // also checks it against the 2020-12 meta-schema
  }
  cache = { ajv, schemas };
  return cache;
}

// Which schema governs a topic (the topic -> schema map in schemas/README.md).
// Returns null for topics that have no schema yet.
function schemaNameForTopic(topic) {
  if (topic.startsWith("ofm/_system/sources/")) return "system-source";
  if (topic.startsWith("ofm/_system/runtime/")) return "system-runtime";
  if (topic.startsWith("ofm/_system/cache/")) return "system-cache";
  if (topic.startsWith("ofm/_system/historian/")) return "system-historian";
  if (topic.startsWith("ofm/_unmapped/")) return "unmapped";
  if (topic.startsWith("ofm/") || topic.startsWith("$SYS/")) return null;
  if (topic.endsWith("/_meta")) return "meta";
  const levels = topic.split("/");
  if (levels.length === 5 && levels[4] === "workorder") return "workorder";
  if (levels.length >= 6) return "value";
  return null;
}

// The topic standard: {enterprise}/{site}/{area}/{line}/{machine}/{property},
// optionally one sub-asset level deeper; lowercase a-z, 0-9 and _.
const VALUE_TOPIC = /^[a-z][a-z0-9_]*(\/[a-z][a-z0-9_]*){5,6}$/;

// Check one payload against a named schema. Returns null if valid, or a
// short description of the first problems.
function validate(schemaName, payload) {
  const { ajv, schemas } = load();
  const schema = schemas[schemaName];
  if (!schema) return "no schema named " + schemaName;
  const check = ajv.getSchema(schema.$id);
  if (check(payload)) return null;
  return check.errors.slice(0, 3)
    .map(e => (e.instancePath || "(payload)") + " " + e.message)
    .join("; ");
}

module.exports = { load, schemaNameForTopic, validate, VALUE_TOPIC };
