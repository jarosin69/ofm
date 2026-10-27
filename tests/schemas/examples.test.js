// Payload contracts: every schema in schemas/ is well-formed JSON Schema
// 2020-12; every example in tests/schemas/<schema>/valid/ passes and every
// example in tests/schemas/<schema>/invalid/ is rejected.
"use strict";
const path = require("path");
const fs = require("fs");
const { ROOT, readJson } = require("../lib/harness");
const contracts = require("../lib/contracts");

module.exports.run = async function (t) {
  let schemas;
  try {
    ({ schemas } = contracts.load());
  } catch (e) {
    t.check("schemas load and are valid JSON Schema 2020-12", false, e.message);
    return;
  }
  t.check(Object.keys(schemas).length + " schemas load and are valid JSON Schema 2020-12", true);

  for (const name of Object.keys(schemas)) {
    if (name === "common") continue;                // shared definitions, not a payload
    const folder = path.join(__dirname, name);
    const list = sub => fs.existsSync(path.join(folder, sub))
      ? fs.readdirSync(path.join(folder, sub)).filter(f => f.endsWith(".json")).sort() : [];
    const valid = list("valid");
    const invalid = list("invalid");
    if (valid.length === 0) {
      t.check(name + ": has valid examples", false, "no files in " + path.relative(ROOT, folder) + "/valid");
      continue;
    }
    const problems = [];
    for (const f of valid) {
      const err = contracts.validate(name, readJson(path.join(folder, "valid", f)));
      if (err) problems.push("valid/" + f + " rejected: " + err);
    }
    for (const f of invalid) {
      if (!contracts.validate(name, readJson(path.join(folder, "invalid", f)))) {
        problems.push("invalid/" + f + " accepted, but should be rejected");
      }
    }
    t.check(name + ": " + valid.length + " valid and " + invalid.length + " invalid examples behave",
            problems.length === 0, problems.join("\n             "));
  }
};
