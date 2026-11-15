-- Removes all made-up history (db/examples/demo-test-history.sql): the
-- values in every period listed in hist.test_data_range, and the list.
-- Measured values outside those periods are not touched. Run with
--   docker compose run --rm migrate test-history-remove
-- History is append-only everywhere else (ADR-0006); made-up values are the
-- exception, because they were never measured.

-- Older periods are stored compressed (migration 011); the limit on rows
-- unpacked per transaction is lifted for this removal.
SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT property_id, from_ts, to_ts FROM hist.test_data_range ORDER BY property_id, from_ts LOOP
    EXECUTE format('DELETE FROM hist.measurement WHERE property_id = %s AND ts >= %L AND ts < %L', r.property_id, r.from_ts, r.to_ts);
  END LOOP;
END $$;
DELETE FROM hist.test_data_range;
