// The demo line's model (db/examples/demo-packline.sql, steps 3a.2 and 3a.3): it loads,
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
         (SELECT count(*) FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id
          WHERE m.line_id IN (SELECT id FROM line) AND p.role IS NOT NULL)::int AS roles,
         (SELECT count(*) FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id
          WHERE m.line_id IN (SELECT id FROM line) AND p.role = 'heartbeat' AND p.heartbeat_timeout_ms = 5000)::int AS heartbeats,
         (SELECT count(*) FROM config.machine_state_rule r JOIN config.machine m ON m.id = r.machine_id
          WHERE m.line_id IN (SELECT id FROM line))::int AS state_rules,
         (SELECT count(*) FROM hist.machine_state_event e JOIN config.machine m ON m.id = e.machine_id
          WHERE m.line_id IN (SELECT id FROM line))::int AS state_events,
         (SELECT count(*) FROM hist.vw_production_count WHERE line_id IN (SELECT id FROM line))::int AS counts,
         (SELECT count(*) FROM config.work_order WHERE line_id IN (SELECT id FROM line))::int AS orders,
         (SELECT count(*) FROM config.fault_code_reason f JOIN config.machine m ON m.id = f.machine_id WHERE m.line_id IN (SELECT id FROM line))::int AS fault_codes,
         (SELECT count(*) FROM config.reason r JOIN config.machine m ON m.id = r.machine_id WHERE m.line_id IN (SELECT id FROM line))::int AS machine_reasons,
         (SELECT count(*) FROM config.reason WHERE code IN ('breakdown_other', 'meal_break') AND description LIKE 'Demo:%')::int AS general_reasons,
         (SELECT bool_and(order_required) FROM config.line_kpi_rule WHERE line_id IN (SELECT id FROM line)) AS order_required,
         (SELECT count(*) FROM pg_namespace WHERE nspname = 'demo')::int AS demo_schema,
         (SELECT count(*) FROM pg_roles WHERE rolname = 'ofm_demo')::int AS demo_role,
         (SELECT count(*) FROM config.person WHERE note = 'demo (db/examples/demo-packline.sql)' AND retired_at IS NULL)::int AS people,
         (SELECT count(*) FROM config.line_shift WHERE line_id IN (SELECT id FROM line))::int AS shifts,
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
    const lc = (await db.query(`SELECT string_agg(m.name || ':' || c.kind, ',' ORDER BY c.kind, m.name) AS counters
      FROM config.line_kpi_rule r JOIN config.line l ON l.id = r.line_id AND l.name = 'packline01' AND l.retired_at IS NULL,
           config.fn_line_count_properties(r.id) c
      JOIN config.machine_property p ON p.id = c.property_id JOIN config.machine m ON m.id = p.machine_id`)).rows[0];
    t.check("demo line: good counted at the closer, rejects from the filler to the closer (step 3a.4)",
            lc.counters === "closer:good,checkweigher:reject,closer:reject,filler:reject",
            lc.counters + (/^filler:good/.test(lc.counters || "") ? " - the demo was loaded before step 3a.4: run migrate demo-remove, then migrate demo" : ""));
    const door = (await db.query(`SELECT has_function_privilege('ofm_demo', 'demo.start_order(text, integer, text)', 'EXECUTE') AS start,
        has_function_privilege('ofm_demo', 'demo.complete_order(text)', 'EXECUTE') AS complete,
        has_table_privilege('ofm_demo', 'config.work_order', 'SELECT') AS read_orders,
        has_function_privilege('ofm_demo', 'config.fn_work_order_start(integer, text)', 'EXECUTE') AS start_any,
        has_table_privilege('ofm_demo', 'config.plc_mapping', 'SELECT') AS read_model`)).rows[0];
    t.check("demo: the simulator's role ofm_demo may start and complete the demo line's orders, nothing else (step 3a.5)",
            door.start && door.complete && !door.read_orders && !door.start_any && !door.read_model, JSON.stringify(door));
    t.check("demo line: 18 fault codes mapped to their machines' reasons, general reasons, orders required (step 3a.6)",
            once.fault_codes === 18 && once.machine_reasons === 18 && once.general_reasons === 2 && once.order_required === true,
            JSON.stringify(once) + (once.order_required === false ? " - the demo was loaded before step 3a.6: run migrate demo-remove, then migrate demo" : ""));
    t.check("demo line: shifts A, B and C (step 3a.8b)", once.shifts === 3,
            JSON.stringify(once) + (once.shifts === 0 ? " - the demo was loaded before step 3a.8b: run migrate demo" : ""));
    t.check("demo line: three demo people for the line view, 1001-1003 (step 3a.8)", once.people === 3,
            JSON.stringify(once) + (once.people === 0 ? " - the demo was loaded before step 3a.8: run migrate demo" : ""));
    t.check("demo line: 6 roles per machine, a 5 s heartbeat, 8 state rules per machine (step 3a.3)",
            once.roles === 36 && once.heartbeats === 6 && once.state_rules === 48, JSON.stringify(once));
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
    await db.query(`INSERT INTO hist.machine_state_event (machine_id, ts, state_id, cause)
      SELECT m.id, now() - interval '1 hour', 1, 'rule' FROM config.machine m JOIN config.line l ON l.id = m.line_id
      WHERE l.name = 'packline01' ON CONFLICT DO NOTHING`);
    await db.query(`INSERT INTO hist.production_count (ts, property_id, increment, last_value)
      SELECT date_trunc('minute', now()) - interval '10 days', p.id, 5, 5 FROM config.machine_property p
      JOIN config.machine m ON m.id = p.machine_id JOIN config.line l ON l.id = m.line_id
      WHERE l.name = 'packline01' AND p.role = 'count_good' ON CONFLICT DO NOTHING`);
    const started = (await db.query("SELECT demo.start_order('mix500', 100, 'test') AS id")).rows[0].id;
    await db.query("SELECT demo.start_order('mix250', 100, 'test')");
    const orders = (await db.query(`SELECT line_topic, sku, active FROM hist.vw_line_work_order w
      JOIN config.line l ON l.id = w.line_id WHERE l.name = 'packline01' AND l.retired_at IS NULL`)).rows;
    t.check("demo.start_order starts an order on the demo line, completing the running one",
            started > 0 && orders.length === 1 && orders[0].sku === "mix250" && orders[0].active && orders[0].line_topic === "acme/melbourne/packing/packline01",
            JSON.stringify(orders));
    await db.query("SAVEPOINT before_remove");
    await db.query(read("demo-packline-remove.sql"));
    // While the removal is open, a value written by anyone else must wait
    // (it would otherwise make the deletion of the properties fail, 23503).
    // Property -1 does not exist: without the lock the insert fails at once
    // with 23503; with it, it waits and gives up after 0.5 s (55P03).
    const other2 = await connectDb();
    let blocked;
    try {
      await other2.query("SET lock_timeout = '500ms'");
      await other2.query("INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source) VALUES (now(), -1, 0, 0, 1)");
      blocked = "inserted";
    } catch (e) { blocked = e.code; } finally { await other2.end().catch(() => {}); }
    t.check("demo-remove holds new history rows back until it is done (no race with a runtime still writing)", blocked === "55P03", blocked);
    const gone = (await db.query(COUNTS)).rows[0];
    const eggline = (await db.query("SELECT count(*)::int AS n FROM config.line WHERE name = 'eggline01'")).rows[0].n;
    const other = (await db.query(`SELECT count(*)::int AS n FROM hist.measurement m JOIN config.machine_property p ON p.id = m.property_id
      JOIN config.machine mm ON mm.id = p.machine_id JOIN config.line l ON l.id = mm.line_id JOIN config.area a ON a.id = l.area_id
      JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id WHERE e.name = 'zz_other'`)).rows[0].n;
    t.check("demo-remove works beside 120,000 compressed rows of another line, and leaves them all", other === 120000, other);
    t.check("demo-remove takes away the demo line, its sources, rates, rules, schedule and products",
            gone.lines === 0 && gone.machines === 0 && gone.mapped === 0 && gone.sources === 0 && gone.products === 0, JSON.stringify(gone));
    t.check("demo-remove takes away its state rules, state events and counts too",
            gone.state_rules === 0 && gone.state_events === 0 && gone.counts === 0, JSON.stringify(gone));
    t.check("demo-remove takes away its reasons and fault codes",
            gone.fault_codes === 0 && gone.machine_reasons === 0 && gone.general_reasons === 0, JSON.stringify(gone));
    t.check("demo-remove takes away its work orders, schema demo, role ofm_demo and the demo people",
            gone.orders === 0 && gone.demo_schema === 0 && gone.demo_role === 0 && gone.people === 0 && gone.shifts === 0, JSON.stringify(gone));
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
