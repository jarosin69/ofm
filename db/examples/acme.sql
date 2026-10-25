-- Example plant "acme" (a placeholder company), for development and demos.
-- Not a migration: load or refresh it with
--   docker compose run --rm migrate example
-- It can be run any number of times: missing rows are added and the
-- addresses and scaling of the example mappings are brought up to date.
-- Rows you added yourself are never touched.
--
-- Data source: the OPC PLC simulator (service "opcplc", ADR-0013 step 1.2).
-- Addresses use the namespace URI (nsu=...), which stays the same across
-- simulator versions; the namespace index (ns=2, ns=3) does not.
-- Scaling is PROVISIONAL until values are seen flowing in step 1.3.

INSERT INTO config.enterprise (name, display_name, description)
VALUES ('acme', 'Acme Confectionery', 'Example enterprise for OFM development')
ON CONFLICT (name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.site (enterprise_id, name, display_name, time_zone)
SELECT id, 'melbourne', 'Melbourne plant', 'Australia/Melbourne'
FROM config.enterprise WHERE name = 'acme' AND retired_at IS NULL
ON CONFLICT (enterprise_id, name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.area (site_id, name, display_name)
SELECT s.id, 'chocolate', 'Chocolate moulding'
FROM config.site s JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'acme' AND s.name = 'melbourne' AND s.retired_at IS NULL
ON CONFLICT (site_id, name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.line (area_id, name, display_name)
SELECT a.id, 'eggline01', 'Egg line 1'
FROM config.area a JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'acme' AND s.name = 'melbourne' AND a.name = 'chocolate' AND a.retired_at IS NULL
ON CONFLICT (area_id, name) WHERE retired_at IS NULL DO NOTHING;

CREATE TEMP VIEW acme_line AS
SELECT l.id
FROM config.line l JOIN config.area a ON a.id = l.area_id
JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'acme' AND s.name = 'melbourne' AND a.name = 'chocolate'
  AND l.name = 'eggline01' AND l.retired_at IS NULL;

INSERT INTO config.machine (line_id, name, display_name, description)
SELECT acme_line.id, v.name, v.display_name, v.description
FROM acme_line, (VALUES
  ('depositor01',     'Depositor 1',      'Deposits tempered chocolate into moulds'),
  ('coolingtunnel01', 'Cooling tunnel 1', 'Cools and sets the moulded shells')
) AS v (name, display_name, description)
ON CONFLICT (line_id, name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.source (name, display_name, description, protocol, endpoint, settings)
VALUES ('opcplc', 'OPC PLC simulator', 'Microsoft OPC PLC simulator container (Phase 1 data source)',
        'opcua', 'opc.tcp://opcplc:50000',
        '{"securityMode": "None", "publishingIntervalMs": 1000}')
ON CONFLICT (name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.machine_property
  (machine_id, name, display_name, description, datatype, engineering_unit_id,
   low, high, alarm_low, alarm_high, deadband)
SELECT m.id, v.name, v.display_name, v.description, v.datatype, u.id,
       v.low, v.high, v.alarm_low, v.alarm_high, v.deadband
FROM (VALUES
  ('depositor01',     'chocolate_temp', 'Chocolate temperature',  'Chocolate in the depositor hopper', 'float', 'degC', 20.0, 40.0,  28.0, 33.0, 0.1),
  ('depositor01',     'hopper_level',   'Hopper level',           'Chocolate level in the hopper',     'float', 'pct',   0.0, 100.0, 10.0, 95.0, 0.5),
  ('depositor01',     'running',        'Running',                'Depositor running signal',          'bool',  NULL,   NULL, NULL,  NULL, NULL, 0),
  ('depositor01',     'cycle_count',    'Cycle count',            'Deposits since counter reset',      'int',   'pcs',  NULL, NULL,  NULL, NULL, 0),
  ('coolingtunnel01', 'air_temp',       'Tunnel air temperature', 'Air temperature at tunnel exit',    'float', 'degC',  0.0, 25.0,   6.0, 14.0, 0.1)
) AS v (machine, name, display_name, description, datatype, unit, low, high, alarm_low, alarm_high, deadband)
JOIN config.machine m ON m.name = v.machine AND m.retired_at IS NULL
JOIN acme_line ON acme_line.id = m.line_id
LEFT JOIN config.engineering_unit u ON u.code = v.unit
ON CONFLICT (machine_id, COALESCE(sub_asset_id, 0), name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.plc_mapping (property_id, source_id, address, scale_factor, scale_offset)
SELECT p.id, src.id, 'nsu=http://microsoft.com/Opc/OpcPlc/;s=' || v.node, v.scale_factor, v.scale_offset
FROM (VALUES
  ('depositor01',     'chocolate_temp', 'SpikeData',          0.02, 30.5),
  ('depositor01',     'hopper_level',   'PositiveTrendData',  1.0,   0.0),
  ('depositor01',     'running',        'AlternatingBoolean', 1.0,   0.0),
  ('depositor01',     'cycle_count',    'SlowUInt1',          1.0,   0.0),
  ('coolingtunnel01', 'air_temp',       'DipData',            0.02, 10.0)
) AS v (machine, property, node, scale_factor, scale_offset)
JOIN config.machine m ON m.name = v.machine AND m.retired_at IS NULL
JOIN acme_line ON acme_line.id = m.line_id
JOIN config.machine_property p ON p.machine_id = m.id AND p.name = v.property AND p.retired_at IS NULL
JOIN config.source src ON src.name = 'opcplc' AND src.retired_at IS NULL
ON CONFLICT (property_id) WHERE retired_at IS NULL DO UPDATE
  SET source_id    = EXCLUDED.source_id,
      address      = EXCLUDED.address,
      scale_factor = EXCLUDED.scale_factor,
      scale_offset = EXCLUDED.scale_offset
  WHERE (config.plc_mapping.source_id, config.plc_mapping.address,
         config.plc_mapping.scale_factor, config.plc_mapping.scale_offset)
     IS DISTINCT FROM (EXCLUDED.source_id, EXCLUDED.address,
                       EXCLUDED.scale_factor, EXCLUDED.scale_offset);
