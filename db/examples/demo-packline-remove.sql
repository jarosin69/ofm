-- Removes the simulated packing line (db/examples/demo-packline.sql)
-- completely: its history (values, state events and their reasons, counts,
-- work orders and their events), the demo people, state rules, reasons, fault codes, mappings,
-- properties, KPI rules, rates, schedule, shifts,
-- flow order, machines, line, its sources linesim_m1 ... linesim_m6, the
-- area "packing" if nothing else is in it, and the demo products if no other
-- line uses them. Run with
--   docker compose run --rm migrate demo-remove
-- History is append-only everywhere else (ADR-0006); the demo's data is an
-- exception, so a demo leaves nothing behind. The audit log keeps the record
-- of the removal. The example line eggline01 is not touched.

SET LOCAL ofm.removing = 'on';      -- lets rates and KPI rules in force be deleted (migration 012)

-- Values still arriving for the demo (a runtime still reading it, or a disk
-- queue being replayed) would block the deletion of its properties: the
-- history tables take no new rows until this removal is done. The runtime
-- waits a few seconds and then writes what it has; nothing is lost.
LOCK TABLE hist.measurement, hist.measurement_text, hist.production_count, hist.machine_state_event,
           hist.work_order_event, hist.state_reason IN SHARE MODE;

CREATE TEMP TABLE rm_line AS
SELECT l.id
FROM config.line l JOIN config.area a ON a.id = l.area_id
JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'acme' AND s.name = 'melbourne' AND a.name = 'packing' AND l.name = 'packline01';

CREATE TEMP TABLE rm_machines AS
SELECT id FROM config.machine WHERE line_id IN (SELECT id FROM rm_line);

CREATE TEMP TABLE rm_props AS
SELECT id FROM config.machine_property WHERE machine_id IN (SELECT id FROM rm_machines);

-- History older than 7 days is stored compressed (migration 011). The IDs
-- go into the DELETE as a fixed list, so TimescaleDB unpacks only these
-- properties' compressed rows, not every property's; and the limit on rows
-- unpacked per transaction is lifted for this one removal.
SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
DO $$
DECLARE ids int[] := ARRAY(SELECT id FROM rm_props);
BEGIN
  EXECUTE format('DELETE FROM hist.measurement WHERE property_id = ANY (%L::int[])', ids);
  EXECUTE format('DELETE FROM hist.measurement_text WHERE property_id = ANY (%L::int[])', ids);
  EXECUTE format('DELETE FROM hist.production_count WHERE property_id = ANY (%L::int[])', ids);
END $$;
DELETE FROM hist.state_reason WHERE machine_id IN (SELECT id FROM rm_machines);
DELETE FROM hist.machine_state_event WHERE machine_id IN (SELECT id FROM rm_machines);
DELETE FROM hist.work_order_event WHERE work_order_id IN (SELECT id FROM config.work_order WHERE line_id IN (SELECT id FROM rm_line));
DELETE FROM config.work_order WHERE line_id IN (SELECT id FROM rm_line);
DELETE FROM config.machine_state_rule WHERE machine_id IN (SELECT id FROM rm_machines);
DELETE FROM config.fault_code_reason WHERE machine_id IN (SELECT id FROM rm_machines);
DELETE FROM config.reason WHERE machine_id IN (SELECT id FROM rm_machines);
DELETE FROM config.reason r
WHERE r.code IN ('breakdown_other', 'minor_stop_other', 'material_quality', 'meal_break', 'planned_maintenance', 'extra_cleaning')
  AND r.machine_id IS NULL AND r.description LIKE 'Demo:%'
  AND NOT EXISTS (SELECT 1 FROM hist.state_reason s WHERE s.reason_id = r.id)
  AND NOT EXISTS (SELECT 1 FROM config.fault_code_reason f WHERE f.reason_id = r.id);
DELETE FROM config.plc_mapping WHERE property_id IN (SELECT id FROM rm_props)
   OR source_id IN (SELECT id FROM config.source WHERE name ~ '^linesim_m[0-9]+$');
DELETE FROM config.machine_property WHERE id IN (SELECT id FROM rm_props);
DELETE FROM config.asset_relationship WHERE from_machine_id IN (SELECT id FROM rm_machines)
   OR to_machine_id IN (SELECT id FROM rm_machines);
DELETE FROM config.line_kpi_rule WHERE line_id IN (SELECT id FROM rm_line);
DELETE FROM config.material_line_rate WHERE line_id IN (SELECT id FROM rm_line);
DELETE FROM config.line_schedule WHERE line_id IN (SELECT id FROM rm_line);
DELETE FROM config.line_shift WHERE line_id IN (SELECT id FROM rm_line);
DELETE FROM config.machine WHERE id IN (SELECT id FROM rm_machines);
DELETE FROM config.line WHERE id IN (SELECT id FROM rm_line);
DELETE FROM config.area a USING config.site s, config.enterprise e
WHERE s.id = a.site_id AND e.id = s.enterprise_id
  AND e.name = 'acme' AND s.name = 'melbourne' AND a.name = 'packing'
  AND NOT EXISTS (SELECT 1 FROM config.line l WHERE l.area_id = a.id);
DELETE FROM config.source WHERE name ~ '^linesim_m[0-9]+$';
DELETE FROM config.material m
WHERE m.code IN ('mix150', 'mix250', 'mix500')
  AND NOT EXISTS (SELECT 1 FROM config.material_line_rate r WHERE r.material_id = m.id);

-- The demo people (step 3a.8) and their sign-ins; one who also recorded
-- something on another line is retired instead, as history refers to them.
CREATE TEMP TABLE rm_people AS SELECT id FROM config.person WHERE note = 'demo (db/examples/demo-packline.sql)';
DELETE FROM hist.person_sign_in WHERE person_id IN (SELECT id FROM rm_people)
  AND person_id NOT IN (SELECT person_id FROM hist.work_order_event WHERE person_id IS NOT NULL
                        UNION SELECT person_id FROM hist.state_reason WHERE person_id IS NOT NULL);
DELETE FROM config.person p WHERE p.id IN (SELECT id FROM rm_people)
  AND NOT EXISTS (SELECT 1 FROM hist.person_sign_in s WHERE s.person_id = p.id);
UPDATE config.person SET retired_at = now() WHERE id IN (SELECT id FROM rm_people) AND retired_at IS NULL;
DROP TABLE rm_people;

-- The simulator's database door (schema demo, role ofm_demo).
DROP SCHEMA IF EXISTS demo CASCADE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ofm_demo') THEN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM ofm_demo', current_database());
    DROP ROLE ofm_demo;
  END IF;
END $$;

DROP TABLE rm_line, rm_machines, rm_props;
