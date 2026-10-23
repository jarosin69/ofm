-- 004 vw_runtime_model: the one view the runtime loads into its cache at
-- startup (ADR-0001). One row per active property, with its topic computed
-- from the names and its acquisition path, if it has one.
--
-- A property is active only if it and all its ancestors are not retired.
-- cache_key is the ingest lookup key (source|address, ADR-0001 amendment);
-- it is NULL for properties without an enabled mapping on an enabled source.

CREATE VIEW config.vw_runtime_model AS
SELECT
  p.id                         AS property_id,
  m.id                         AS machine_id,
  sa.id                        AS sub_asset_id,
  l.id                         AS line_id,
  a.id                         AS area_id,
  s.id                         AS site_id,
  e.id                         AS enterprise_id,
  concat_ws('/', e.name, s.name, a.name, l.name, m.name, sa.name, p.name) AS topic,
  p.name                       AS property_name,
  p.display_name,
  p.description,
  p.datatype,
  u.code                       AS unit,
  p.low,
  p.high,
  p.alarm_low,
  p.alarm_high,
  p.deadband,
  p.max_publish_interval_ms,
  p.is_historised,
  s.time_zone,
  src.id                       AS source_id,
  src.name                     AS source_name,
  src.protocol,
  src.endpoint,
  src.settings                 AS source_settings,
  src.runtime_name,
  pm.address,
  pm.scale_factor,
  pm.scale_offset,
  CASE WHEN pm.id IS NOT NULL THEN src.name || '|' || pm.address END AS cache_key
FROM config.machine_property p
JOIN config.machine     m  ON m.id = p.machine_id     AND m.retired_at IS NULL
JOIN config.line        l  ON l.id = m.line_id        AND l.retired_at IS NULL
JOIN config.area        a  ON a.id = l.area_id        AND a.retired_at IS NULL
JOIN config.site        s  ON s.id = a.site_id        AND s.retired_at IS NULL
JOIN config.enterprise  e  ON e.id = s.enterprise_id  AND e.retired_at IS NULL
LEFT JOIN config.sub_asset        sa ON sa.id = p.sub_asset_id
LEFT JOIN config.engineering_unit u  ON u.id = p.engineering_unit_id
LEFT JOIN config.plc_mapping      pm ON pm.property_id = p.id
                                    AND pm.retired_at IS NULL AND pm.is_enabled
LEFT JOIN config.source           src ON src.id = pm.source_id
                                    AND src.retired_at IS NULL AND src.is_enabled
WHERE p.retired_at IS NULL
  AND (p.sub_asset_id IS NULL OR sa.retired_at IS NULL)
  AND (pm.id IS NULL OR src.id IS NOT NULL);

COMMENT ON VIEW config.vw_runtime_model IS
  'Everything the runtime needs, one row per active property: topic, metadata, and acquisition path (source, address, scaling). Loaded into the Node-RED cache (ADR-0001).';

-- vw_property_path: every property ever defined, retired ones included, with
-- the topic it has (or last had). Used to label history, where retired
-- equipment must still have a name.
CREATE VIEW config.vw_property_path AS
SELECT
  p.id    AS property_id,
  concat_ws('/', e.name, s.name, a.name, l.name, m.name, sa.name, p.name) AS topic,
  p.display_name,
  p.datatype,
  u.code  AS unit,
  s.time_zone,
  COALESCE(p.retired_at, sa.retired_at, m.retired_at, l.retired_at,
           a.retired_at, s.retired_at, e.retired_at) IS NOT NULL AS is_retired
FROM config.machine_property p
JOIN config.machine     m ON m.id = p.machine_id
JOIN config.line        l ON l.id = m.line_id
JOIN config.area        a ON a.id = l.area_id
JOIN config.site        s ON s.id = a.site_id
JOIN config.enterprise  e ON e.id = s.enterprise_id
LEFT JOIN config.sub_asset        sa ON sa.id = p.sub_asset_id
LEFT JOIN config.engineering_unit u  ON u.id = p.engineering_unit_id;

COMMENT ON VIEW config.vw_property_path IS
  'Every property, including retired ones, with its topic. Used to label historian data.';
