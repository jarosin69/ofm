// OFM test runner: every automated test behind one command (tests/README.md).
//
//   docker compose run --rm test              all suites
//   docker compose run --rm test offline      schemas and flows only (no stack needed)
//   docker compose run --rm test live         one suite (schemas, flows, database, live)
//
// Exit code 0 = every check passed. Output is plain text, so it can be
// pasted into an issue or a release note.
"use strict";
const path = require("path");
const fs = require("fs");
const { Results } = require("./lib/harness");

const SUITES = [
  { name: "schemas",  title: "Payload contracts (schemas/ and their examples)", dir: "schemas" },
  { name: "flows",    title: "Runtime flow, unit tests (flows/ofm-runtime.json)", dir: "flows" },
  { name: "database", title: "Database: model rules, runtime view, permissions, audit", dir: "database" },
  { name: "live",     title: "Live stack: Phase 1 exit check", dir: "live" }
];
const GROUPS = { all: SUITES.map(s => s.name), offline: ["schemas", "flows"] };

async function main() {
  const args = process.argv.slice(2);
  const wanted = new Set();
  for (const a of (args.length ? args : ["all"])) {
    if (GROUPS[a]) GROUPS[a].forEach(n => wanted.add(n));
    else if (SUITES.some(s => s.name === a)) wanted.add(a);
    else {
      console.error("Unknown suite '" + a + "'. Use: all, offline, " + SUITES.map(s => s.name).join(", "));
      process.exit(2);
    }
  }

  const t = new Results();
  const started = new Date();
  console.log("OFM tests, " + started.toISOString().replace(/\.\d+Z$/, "Z") + " (UTC)");

  for (const suite of SUITES.filter(s => wanted.has(s.name))) {
    console.log("\n== " + suite.title);
    const dir = path.join(__dirname, suite.dir);
    const files = fs.readdirSync(dir).filter(f => f.endsWith(".test.js")).sort();
    for (const file of files) {
      if (files.length > 1) console.log("  -- " + file.replace(/\.test\.js$/, ""));
      try {
        await require(path.join(dir, file)).run(t);
      } catch (e) {
        t.check(file + " ran to the end", false, e.stack || String(e));
      }
    }
  }

  const seconds = ((Date.now() - started.getTime()) / 1000).toFixed(1);
  console.log("\n" + "=".repeat(60));
  console.log("Result: " + t.passed + " passed, " + t.failed + " failed" +
              (t.skipped ? ", " + t.skipped + " skipped" : "") + "  (" + seconds + " s)");
  console.log(t.failed === 0 ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED - see FAIL lines above");
  process.exitCode = t.failed === 0 ? 0 : 1;
}

main().catch(e => {
  console.error(e.stack || e);
  process.exitCode = 1;
}).finally(() => setTimeout(() => process.exit(), 100));
