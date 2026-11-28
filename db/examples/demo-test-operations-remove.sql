-- Removes the made-up operations history of the demo line
-- (db/examples/demo-test-operations.sql): inside each period recorded in
-- hist.test_operation_range, the demo machines' state events and reasons,
-- the counts of its properties, the made-up work orders with their events
-- and the made-up annotation. Real history lies after these periods and is
-- untouched. Run with
--   docker compose run --rm migrate test-operations-remove
-- Counts older than 7 days are stored compressed: the property IDs go into
-- the DELETE as a fixed list, so TimescaleDB unpacks only these, and the
-- unpacking limit is lifted for this one transaction (as in demo-remove).

SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0;

DROP TABLE IF EXISTS pg_temp.tr_range;
CREATE TEMP TABLE tr_range ON COMMIT DROP AS
SELECT r.line_id, r.from_ts, r.to_ts FROM hist.test_operation_range r
JOIN config.line l ON l.id = r.line_id AND l.name = 'packline01';

DO $$
DECLARE
  rg record; props integer[]; machines integer[];
BEGIN
  FOR rg IN SELECT * FROM tr_range LOOP
    SELECT array_agg(m.id) INTO machines FROM config.machine m WHERE m.line_id = rg.line_id;
    SELECT array_agg(p.id) INTO props FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id WHERE m.line_id = rg.line_id;
    EXECUTE format('DELETE FROM hist.production_count WHERE property_id = ANY (%L::int[]) AND ts >= %L AND ts < %L', props, rg.from_ts, rg.to_ts);
    DELETE FROM hist.state_reason WHERE machine_id = ANY (machines) AND event_ts >= rg.from_ts AND event_ts < rg.to_ts;
    DELETE FROM hist.machine_state_event WHERE machine_id = ANY (machines) AND ts >= rg.from_ts AND ts < rg.to_ts;
    DELETE FROM hist.annotation_removal WHERE annotation_id IN (
      SELECT id FROM hist.annotation WHERE line_id = rg.line_id AND text LIKE '%(made-up test operations)');
    DELETE FROM hist.annotation WHERE line_id = rg.line_id AND text LIKE '%(made-up test operations)';
    DELETE FROM hist.work_order_event WHERE work_order_id IN (
      SELECT id FROM config.work_order WHERE line_id = rg.line_id AND note = 'made-up (migrate test-operations)');
    DELETE FROM config.work_order WHERE line_id = rg.line_id AND note = 'made-up (migrate test-operations)';
    DELETE FROM hist.test_operation_range WHERE line_id = rg.line_id AND from_ts = rg.from_ts;
    RAISE NOTICE 'Made-up operations removed: % to %', rg.from_ts, rg.to_ts;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM tr_range) THEN
    RAISE NOTICE 'There are no made-up operations.';
  END IF;
END $$;
