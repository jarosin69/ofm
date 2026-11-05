-- Removes the load-test line (db/examples/loadtest.sql) completely: its
-- history, mappings, properties, machines, line, area, site, enterprise and
-- source. Run with
--   docker compose run --rm migrate loadtest-remove
-- Only rows of enterprise "ofmload" and source "opcplc_load" are touched.
-- History is append-only everywhere else (ADR-0006); this synthetic data is
-- the one exception, so a test leaves nothing behind. The audit log keeps
-- the record of the removal.

CREATE TEMP TABLE load_props AS
SELECT p.id
FROM config.machine_property p
JOIN config.machine m ON m.id = p.machine_id
JOIN config.line l ON l.id = m.line_id
JOIN config.area a ON a.id = l.area_id
JOIN config.site s ON s.id = a.site_id
JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'ofmload';

-- History older than 7 days is stored compressed (migration 011). The IDs
-- go into the DELETE as a fixed list, so TimescaleDB unpacks only these
-- properties' compressed rows, not every property's; and the limit on rows
-- unpacked per transaction is lifted for this one removal.
SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
DO $$
DECLARE ids int[] := ARRAY(SELECT id FROM load_props);
BEGIN
  EXECUTE format('DELETE FROM hist.measurement WHERE property_id = ANY (%L::int[])', ids);
  EXECUTE format('DELETE FROM hist.measurement_text WHERE property_id = ANY (%L::int[])', ids);
END $$;
DELETE FROM config.plc_mapping WHERE property_id IN (SELECT id FROM load_props)
   OR source_id IN (SELECT id FROM config.source WHERE name = 'opcplc_load');
DELETE FROM config.machine_property WHERE id IN (SELECT id FROM load_props);
DELETE FROM config.machine WHERE line_id IN (
  SELECT l.id FROM config.line l JOIN config.area a ON a.id = l.area_id
  JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
  WHERE e.name = 'ofmload');
DELETE FROM config.line WHERE area_id IN (
  SELECT a.id FROM config.area a JOIN config.site s ON s.id = a.site_id
  JOIN config.enterprise e ON e.id = s.enterprise_id WHERE e.name = 'ofmload');
DELETE FROM config.area WHERE site_id IN (
  SELECT s.id FROM config.site s JOIN config.enterprise e ON e.id = s.enterprise_id WHERE e.name = 'ofmload');
DELETE FROM config.site WHERE enterprise_id IN (SELECT id FROM config.enterprise WHERE name = 'ofmload');
DELETE FROM config.enterprise WHERE name = 'ofmload';
DELETE FROM config.source WHERE name = 'opcplc_load';
