-- 005 Historian: the permanent record of measured values (ADR-0002, ADR-0003).
--
-- Narrow and ID-keyed: no names or topics, so renames never touch history.
-- Codes are stored as small integers to keep billions of rows compact:
--   quality    0 = good, 1 = uncertain, 2 = bad
--   ts_source  0 = device, 1 = gateway
-- The primary key (property_id, ts) makes inserts idempotent: replaying the
-- store-and-forward queue twice cannot create duplicates (ADR-0006).
--
-- Hypertables: TimescaleDB splits each table into one chunk per day.
-- Columnstore (compression) and retention are deliberately off in Phase 1;
-- they are decided with the batched writer in Phase 2.

CREATE TABLE hist.measurement (
  ts           timestamptz      NOT NULL,
  property_id  integer          NOT NULL REFERENCES config.machine_property (id) ON DELETE RESTRICT,
  value        double precision NOT NULL,   -- bool stored as 0/1
  quality      smallint         NOT NULL CHECK (quality IN (0, 1, 2)),
  ts_source    smallint         NOT NULL CHECK (ts_source IN (0, 1)),
  PRIMARY KEY (property_id, ts)
) WITH (
  tsdb.hypertable,
  tsdb.partition_column = 'ts',
  tsdb.chunk_interval = '1 day',
  tsdb.columnstore = false
);

-- Text-valued properties (datatype 'string') go to a sibling table rather than
-- adding a mostly-empty column to measurement (Architecture Overview §8).
CREATE TABLE hist.measurement_text (
  ts           timestamptz NOT NULL,
  property_id  integer     NOT NULL REFERENCES config.machine_property (id) ON DELETE RESTRICT,
  value        text        NOT NULL CHECK (length(value) <= 1024),
  quality      smallint    NOT NULL CHECK (quality IN (0, 1, 2)),
  ts_source    smallint    NOT NULL CHECK (ts_source IN (0, 1)),
  PRIMARY KEY (property_id, ts)
) WITH (
  tsdb.hypertable,
  tsdb.partition_column = 'ts',
  tsdb.chunk_interval = '7 days',
  tsdb.columnstore = false
);

-- Readable view for people and Grafana: names, units and text codes joined in
-- at read time (Architecture Overview §8).
CREATE VIEW hist.vw_measurement AS
SELECT
  h.ts,
  h.property_id,
  pp.topic,
  pp.display_name,
  h.value,
  pp.unit,
  (ARRAY['good', 'uncertain', 'bad'])[h.quality + 1]  AS quality,
  (ARRAY['device', 'gateway'])[h.ts_source + 1]       AS ts_source
FROM hist.measurement h
JOIN config.vw_property_path pp ON pp.property_id = h.property_id;

COMMENT ON TABLE hist.measurement      IS 'Numeric and boolean property values. quality: 0 good, 1 uncertain, 2 bad. ts_source: 0 device, 1 gateway.';
COMMENT ON TABLE hist.measurement_text IS 'Text property values. Same codes as hist.measurement.';
COMMENT ON VIEW  hist.vw_measurement   IS 'hist.measurement with topic, display name, unit and readable codes.';
