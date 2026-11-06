-- 014 Production counts (Phase 3a, step 3a.4; ADR-0026, ADR-0008 amendment).
--
-- 1. hist.production_count       units made per counter per minute, from the
--                                PLC counters with a count role (migration 013)
--    hist.vw_production_count    the same with machine and role, for people
-- 2. line_kpi_rule.output_machine_id   where the line's good product is counted
-- 3. config.fn_line_count_properties   which counters make a line's good and
--                                reject counts under a KPI rule
--    hist.vw_line_count          line good and reject per minute
--
-- How the runtime fills hist.production_count (flows/ofm-runtime.json, node
-- "counts"): each good reading of a counter minus its previous good reading
-- is the number of units made in between; a reading lower than the previous
-- one means the counter was reset to 0, so the reading itself is what was
-- made since. The increments are added up per minute (the minute of the
-- reading's own time) and written once the minute is over: one row per
-- counter and minute in which anything happened. last_value, the counter's
-- reading at the end of the minute, is where the runtime starts again after
-- a restart, so units made while it was not running are counted when it
-- reads again, never lost or counted twice.

-- ---------------------------------------------------------------------------
-- 1. Units made per counter and minute. Append-only (ADR-0006): the runtime
-- inserts, nobody updates. Kept without a time limit: about 1 440 rows per
-- counter a day at most, compressed after 7 days like the measurements.
-- ---------------------------------------------------------------------------
CREATE TABLE hist.production_count (
  ts           timestamptz      NOT NULL,   -- start of the minute, UTC
  property_id  integer          NOT NULL REFERENCES config.machine_property (id) ON DELETE RESTRICT,
  increment    double precision NOT NULL CHECK (increment >= 0),   -- units made in the minute
  last_value   double precision NOT NULL,   -- the counter's reading at the end of the minute
  resets       smallint         NOT NULL DEFAULT 0 CHECK (resets >= 0),   -- counter resets seen in the minute
  PRIMARY KEY (property_id, ts),
  CONSTRAINT production_count_whole_minute CHECK (ts = date_trunc('minute', ts)),
  CONSTRAINT production_count_not_empty CHECK (increment > 0 OR resets > 0)
) WITH (
  tsdb.hypertable,
  tsdb.partition_column = 'ts',
  tsdb.chunk_interval = '7 days',
  tsdb.columnstore = false
);
ALTER TABLE hist.production_count SET (
  timescaledb.enable_columnstore = true,
  timescaledb.segmentby = 'property_id',
  timescaledb.orderby = 'ts DESC'
);
CALL add_columnstore_policy('hist.production_count', after => INTERVAL '7 days');
COMMENT ON TABLE hist.production_count IS
  'Units made per PLC counter (properties with a count role) and minute (ADR-0026); one row per minute with production or a counter reset. last_value = counter reading at the end of the minute.';

-- For people and Grafana: with machine, property and role, joined at read
-- time (history stays keyed by ID, ADR-0004).
CREATE VIEW hist.vw_production_count AS
SELECT
  c.ts,
  p.machine_id,
  m.line_id,
  m.name       AS machine_name,
  c.property_id,
  p.name       AS property_name,
  p.role,
  c.increment,
  c.last_value,
  c.resets
FROM hist.production_count c
JOIN config.machine_property p ON p.id = c.property_id
JOIN config.machine m          ON m.id = p.machine_id;
COMMENT ON VIEW hist.vw_production_count IS
  'hist.production_count with machine, property name and role, for people and Grafana.';

-- ---------------------------------------------------------------------------
-- 2. The line's output machine: its count_good is the line's good count.
-- Empty = the constraint machine. Part of the KPI rule, so dated with it
-- (ADR-0008 amendment): a rule in force is never changed.
-- ---------------------------------------------------------------------------
ALTER TABLE config.line_kpi_rule
  ADD COLUMN output_machine_id integer,
  ADD CONSTRAINT line_kpi_rule_output_machine_fk FOREIGN KEY (line_id, output_machine_id)
    REFERENCES config.machine (line_id, id) ON DELETE RESTRICT;
COMMENT ON COLUMN config.line_kpi_rule.output_machine_id IS
  'Where the line''s good product is counted: this machine''s count_good. Empty = the constraint machine. Rejects count from the constraint to this machine (ADR-0008 amendment).';

-- ---------------------------------------------------------------------------
-- 3. Which counters make a line's counts under a KPI rule:
--   good    count_good of the output machine;
--   reject  count_reject of every machine from the constraint to the output
--           machine, following the flow order (feeds, ADR-0024), both
--           included: units rejected after they used constraint time.
-- Retired properties are included: each has counts only from its own time.
-- If the output machine cannot be reached from the constraint by feeds,
-- only those two machines' rejects count.
-- ---------------------------------------------------------------------------
CREATE FUNCTION config.fn_line_count_properties(p_kpi_rule_id integer)
RETURNS TABLE (property_id integer, kind text)
LANGUAGE sql STABLE
AS $$
  WITH RECURSIVE rule AS (
    SELECT constraint_machine_id AS first_id, coalesce(output_machine_id, constraint_machine_id) AS last_id
    FROM config.line_kpi_rule WHERE id = p_kpi_rule_id
  ),
  walk (machine_id, trail) AS (               -- every way forward from the constraint
    SELECT first_id, ARRAY[first_id] FROM rule
    UNION ALL
    SELECT r.to_machine_id, w.trail || r.to_machine_id
    FROM walk w
    JOIN config.asset_relationship r ON r.from_machine_id = w.machine_id AND r.relation_type = 'feeds'
    CROSS JOIN rule
    WHERE w.machine_id <> rule.last_id AND NOT r.to_machine_id = ANY (w.trail)
  ),
  between_machines AS (                      -- on a way that reaches the output machine
    SELECT DISTINCT unnest(w.trail) AS machine_id FROM walk w, rule WHERE w.machine_id = rule.last_id
    UNION
    SELECT first_id FROM rule
    UNION
    SELECT last_id FROM rule
  )
  SELECT p.id, 'good'::text
  FROM config.machine_property p, rule
  WHERE p.machine_id = rule.last_id AND p.role = 'count_good'
  UNION ALL
  SELECT p.id, 'reject'::text
  FROM config.machine_property p JOIN between_machines b ON b.machine_id = p.machine_id
  WHERE p.role = 'count_reject'
$$;
COMMENT ON FUNCTION config.fn_line_count_properties(integer) IS
  'Counters of a line''s good (count_good of the output machine) and reject count (count_reject from the constraint to the output machine) under a KPI rule.';

-- Line good and reject per minute, each minute counted under the KPI rule in
-- force then (kpi_rule_id = KPI definition version, ADR-0008). Filter by
-- line_id and ts.
CREATE VIEW hist.vw_line_count AS
WITH rule AS (
  SELECT r.id, r.line_id, r.valid_from,
         lead(r.valid_from) OVER (PARTITION BY r.line_id ORDER BY r.valid_from) AS valid_to
  FROM config.line_kpi_rule r
),
counter AS (
  SELECT rule.id AS kpi_rule_id, rule.line_id, rule.valid_from, rule.valid_to, c.property_id, c.kind
  FROM rule CROSS JOIN LATERAL config.fn_line_count_properties(rule.id) c
)
SELECT
  counter.line_id,
  pc.ts,
  counter.kpi_rule_id,
  coalesce(sum(pc.increment) FILTER (WHERE counter.kind = 'good'), 0)   AS good,
  coalesce(sum(pc.increment) FILTER (WHERE counter.kind = 'reject'), 0) AS reject
FROM hist.production_count pc
JOIN counter ON counter.property_id = pc.property_id
            AND pc.ts >= counter.valid_from
            AND (counter.valid_to IS NULL OR pc.ts < counter.valid_to)
GROUP BY counter.line_id, pc.ts, counter.kpi_rule_id;
COMMENT ON VIEW hist.vw_line_count IS
  'Line good and reject count per minute (ADR-0008 amendment), under the KPI rule in force at each minute.';

-- The runtime appends and reads its own table; the views are for readers.
REVOKE ALL ON hist.vw_production_count, hist.vw_line_count FROM ofm_runtime;
