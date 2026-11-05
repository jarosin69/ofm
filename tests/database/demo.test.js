// The demo line's model (db/examples/demo-packline.sql, step 3a.2): it loads,
// loading it again changes nothing, and demo-remove takes away exactly what
// it added. Runs as the administrator, as "migrate demo" does, inside one
// transaction that is rolled back: a demo line you have loaded is untouched.
"use strict";
const fs = require("fs");
const path = require("path");
const { ROOT, connectDb } = require("../lib/harness");

const read = f => fs.readFileSync(path.join(ROOT, "db", "examples", f), "utf8");
const COUNTS = `
  WITH line AS (SELECT l.id FROM config.line l JOIN config.area a ON a.id = l.area_id
                JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
                WHERE e.name = 'acme' AND s.name = 'melbourne' AND a.name = 'packing' AND l.name = 'packline01')
  SELECT (SELECT count(*) FROM line)::int AS lines,
         (SELECT count(*) FROM config.machine WHERE line_id IN (SELECT id FROM line))::int AS machines,
         (SELECT count(*) FROM config.vw_runtime_model WHERE topic LIKE 'acme/melbourne/packing/packline01/%' AND cache_key IS NOT NULL)::int AS mapped,
         (SELECT count(*) FROM config.source WHERE name ~ '^linesim_m[0-9]+$')::int AS sources,
         (SELECT count(*) FROM config.material_line_rate WHERE line_id IN (SELECT id FROM line))::int AS rates,
         (SELECT count(*) FROM config.line_kpi_rule WHERE line_id IN (SELECT id FROM line))::int AS rules,
         (SELECT count(*) FROM config.line_schedule WHERE line_id IN (SELECT id FROM line))::int AS windows,
         (SELECT count(*) FROM config.asset_relationship r JOIN config.machine m ON m.id = r.from_machine_id
          WHERE m.line_id IN (SELECT id FROM line) AND r.relation_type = 'feeds')::int AS feeds,
         (SELECT count(*) FROM config.material WHERE code IN ('mix150', 'mix250', 'mix500'))::int AS products,
         (SELECT name FROM config.machine WHERE id = (SELECT constraint_machine_id FROM config.line_kpi_rule
           WHERE line_id IN (SELECT id FROM line) LIMIT 1)) AS constraint_machine`;

module.exports.run = async function (t) {
  let db;
  try {
    db = await connectDb();
  } catch (e) {
    t.check("database reachable", false, e.message);
    return;
  }
  try {
    await db.query("BEGIN");
    await db.query(read("demo-packline.sql"));
    const once = (await db.query(COUNTS)).rows[0];
    t.check("demo line: 6 machines, 50 mapped properties from 6 simulated PLCs",
            once.lines === 1 && once.machines === 6 && once.mapped === 50 && once.sources === 6, JSON.stringify(once));
    t.check("demo line: 3 products with rates, filler as constraint, 2 schedule windows, 5 feeds links",
            once.rates === 3 && once.rules === 1 && once.constraint_machine === "filler" && once.windows === 2 &&
            once.feeds === 5 && once.products === 3, JSON.stringify(once));
    await db.query(read("demo-packline.sql"));
    const twice = (await db.query(COUNTS)).rows[0];
    t.check("demo line loaded again: nothing added or changed", JSON.stringify(twice) === JSON.stringify(once), JSON.stringify(twice));
    // Found on the laptop 2026-11-05: history older than 7 days is compressed,
    // and removing the demo unpacked every property's compressed rows until
    // TimescaleDB's limit (100,000 per transaction) stopped it. Here another
    // line has 120,000 compressed rows, in chunks made inside this transaction.
    await db.query(`
      WITH e AS (INSERT INTO config.enterprise (name, display_name) VALUES ('zz_other', 'Other') RETURNING id),
           s AS (INSERT INTO config.site (enterprise_id, name, display_name) SELECT id, 'site1', 'x' FROM e RETURNING id),
           a AS (INSERT INTO config.area (site_id, name, display_name) SELECT id, 'area1', 'x' FROM s RETURNING id),
           l AS (INSERT INTO config.line (area_id, name, display_name) SELECT id, 'line1', 'x' FROM a RETURNING id),
           m AS (INSERT INTO config.machine (line_id, name, display_name) SELECT id, 'mach1', 'x' FROM l RETURNING id)
      INSERT INTO config.machine_property (machine_id, name, display_name, datatype, engineering_unit_id)
      SELECT m.id, 'temp', 'x', 'float', u.id FROM m, config.engineering_unit u WHERE u.code = 'degC'`);
    await db.query(`INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source)
      SELECT now() - interval '300 days' + g * interval '500 milliseconds', p.id, g, 0, 0
      FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id JOIN config.line l ON l.id = m.line_id
      JOIN config.area a ON a.id = l.area_id JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id,
      generate_series(1, 120000) g WHERE e.name = 'zz_other'`);
    await db.query(`SELECT compress_chunk(c, true)
      FROM show_chunks('hist.measurement', older_than => now() - interval '299 days', newer_than => now() - interval '301 days') c`);
    await db.query("SAVEPOINT before_remove");
    await db.query(read("demo-packline-remove.sql"));
    const gone = (await db.query(COUNTS)).rows[0];
    const eggline = (await db.query("SELECT count(*)::int AS n FROM config.line WHERE name = 'eggline01'")).rows[0].n;
    const other = (await db.query(`SELECT count(*)::int AS n FROM hist.measurement m JOIN config.machine_property p ON p.id = m.property_id
      JOIN config.machine mm ON mm.id = p.machine_id JOIN config.line l ON l.id = mm.line_id JOIN config.area a ON a.id = l.area_id
      JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id WHERE e.name = 'zz_other'`)).rows[0].n;
    t.check("demo-remove works beside 120,000 compressed rows of another line, and leaves them all", other === 120000, other);
    t.check("demo-remove takes away the demo line, its sources, rates, rules, schedule and products",
            gone.lines === 0 && gone.machines === 0 && gone.mapped === 0 && gone.sources === 0 && gone.products === 0, JSON.stringify(gone));
    t.check("demo-remove leaves the rest of the model alone (eggline01, if loaded, is still there)",
            eggline === (await (async () => { await db.query("ROLLBACK TO SAVEPOINT before_remove");
              return (await db.query("SELECT count(*)::int AS n FROM config.line WHERE name = 'eggline01'")).rows[0].n; })()), eggline);
  } catch (e) {
    t.check("demo line scripts run", false, (e.code ? e.code + " " : "") + e.message);
  } finally {
    await db.query("ROLLBACK").catch(() => {});
    await db.end();
  }
};
