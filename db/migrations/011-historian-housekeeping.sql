-- 011 Historian housekeeping (Overview §8, step 2.5).
-- 1. Columnstore (compression): chunks older than 7 days are converted to
--    TimescaleDB's compressed column format, segmented by property, so a
--    property's history is stored together. Typically about 10x smaller;
--    queries and late inserts (store-and-forward) keep working.
-- 2. Continuous aggregates: per property, 1-minute and 1-hour average,
--    minimum, maximum, number of values and worst quality, kept up to date
--    by refresh policies. Long-range charts read these instead of raw rows.
--    Real-time aggregation is on, so the newest, not yet refreshed buckets
--    are computed from raw data at query time.
-- 3. Retention is NOT set here: the migration runner sets it after every run
--    from deploy/.env (OFM_RAW_RETENTION_DAYS, OFM_AGG_RETENTION_YEARS;
--    tools/migrate.sh), so a site changes it without a new migration.

ALTER TABLE hist.measurement SET (
  timescaledb.enable_columnstore = true,
  timescaledb.segmentby = 'property_id',
  timescaledb.orderby = 'ts DESC'
);
CALL add_columnstore_policy('hist.measurement', after => INTERVAL '7 days');

ALTER TABLE hist.measurement_text SET (
  timescaledb.enable_columnstore = true,
  timescaledb.segmentby = 'property_id',
  timescaledb.orderby = 'ts DESC'
);
CALL add_columnstore_policy('hist.measurement_text', after => INTERVAL '7 days');

-- Averages count only rows with a value; worst_quality: 0 good, 1 uncertain, 2 bad.
CREATE MATERIALIZED VIEW hist.measurement_1m
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket(INTERVAL '1 minute', ts) AS bucket,
       property_id,
       avg(value)   AS avg_value,
       min(value)   AS min_value,
       max(value)   AS max_value,
       count(value) AS samples,
       max(quality) AS worst_quality
FROM hist.measurement
GROUP BY 1, 2
WITH NO DATA;

CREATE MATERIALIZED VIEW hist.measurement_1h
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket(INTERVAL '1 hour', ts) AS bucket,
       property_id,
       avg(value)   AS avg_value,
       min(value)   AS min_value,
       max(value)   AS max_value,
       count(value) AS samples,
       max(quality) AS worst_quality
FROM hist.measurement
GROUP BY 1, 2
WITH NO DATA;

-- Refresh: recent buckets every minute / every 30 minutes. The window
-- reaches back 30 days so that rows written late by store-and-forward are
-- included; only buckets whose raw data changed are recalculated.
DO $$
BEGIN
  PERFORM add_continuous_aggregate_policy('hist.measurement_1m',
    start_offset => INTERVAL '30 days', end_offset => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute');
  PERFORM add_continuous_aggregate_policy('hist.measurement_1h',
    start_offset => INTERVAL '30 days', end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '30 minutes');
END $$;

GRANT SELECT ON hist.measurement_1m, hist.measurement_1h TO ofm_reader;
REVOKE ALL ON hist.measurement_1m, hist.measurement_1h FROM ofm_runtime;

COMMENT ON VIEW hist.measurement_1m IS 'Per property and minute: avg/min/max of value, number of values, worst quality (0 good, 1 uncertain, 2 bad). Continuous aggregate of hist.measurement.';
COMMENT ON VIEW hist.measurement_1h IS 'Per property and hour: avg/min/max of value, number of values, worst quality. Continuous aggregate of hist.measurement.';
