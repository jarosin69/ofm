-- Example plant "acme" (a placeholder company), for development and demos.
-- Not a migration: applied on request with
--   docker compose run --rm migrate example
-- It reads from the OPC PLC simulator added in Phase 1 step 1.2.
--
-- PROVISIONAL: the simulator NodeIds and the scaling below are assumptions,
-- to be confirmed by browsing the simulator in step 1.2.

WITH
e AS (INSERT INTO config.enterprise (name, display_name, description)
      VALUES ('acme', 'Acme Confectionery', 'Example enterprise for OFM development')
      RETURNING id),
s AS (INSERT INTO config.site (enterprise_id, name, display_name, time_zone)
      SELECT id, 'melbourne', 'Melbourne plant', 'Australia/Melbourne' FROM e
      RETURNING id),
a AS (INSERT INTO config.area (site_id, name, display_name)
      SELECT id, 'chocolate', 'Chocolate moulding' FROM s
      RETURNING id),
l AS (INSERT INTO config.line (area_id, name, display_name)
      SELECT id, 'eggline01', 'Egg line 1' FROM a
      RETURNING id)
INSERT INTO config.machine (line_id, name, display_name, description)
SELECT l.id, v.name, v.display_name, v.description
FROM l, (VALUES
  ('depositor01',     'Depositor 1',     'Deposits tempered chocolate into moulds'),
  ('coolingtunnel01', 'Cooling tunnel 1', 'Cools and sets the moulded shells')
) AS v (name, display_name, description);

INSERT INTO config.source (name, display_name, description, protocol, endpoint, settings)
VALUES ('opcplc', 'OPC PLC simulator', 'Microsoft OPC PLC simulator container (Phase 1 data source)',
        'opcua', 'opc.tcp://opcplc:50000',
        '{"securityMode": "None", "publishingIntervalMs": 1000}');

INSERT INTO config.machine_property
  (machine_id, name, display_name, description, datatype, engineering_unit_id,
   low, high, alarm_low, alarm_high, deadband)
SELECT m.id, v.name, v.display_name, v.description, v.datatype, u.id,
       v.low, v.high, v.alarm_low, v.alarm_high, v.deadband
FROM (VALUES
  ('depositor01',     'chocolate_temp', 'Chocolate temperature', 'Chocolate in the depositor hopper', 'float', 'degC', 20.0, 40.0, 28.0, 33.0, 0.1),
  ('depositor01',     'hopper_level',   'Hopper level',          'Chocolate level in the hopper',     'float', 'pct',   0.0, 100.0, 10.0, 95.0, 0.5),
  ('depositor01',     'running',        'Running',               'Depositor running signal',          'bool',  NULL,   NULL, NULL,  NULL, NULL, 0),
  ('depositor01',     'cycle_count',    'Cycle count',           'Deposits since counter reset',      'int',   'pcs',  NULL, NULL,  NULL, NULL, 0),
  ('coolingtunnel01', 'air_temp',       'Tunnel air temperature','Air temperature at tunnel exit',    'float', 'degC',  0.0, 25.0,  6.0, 14.0, 0.1)
) AS v (machine, name, display_name, description, datatype, unit, low, high, alarm_low, alarm_high, deadband)
JOIN config.machine m ON m.name = v.machine AND m.retired_at IS NULL
LEFT JOIN config.engineering_unit u ON u.code = v.unit;

INSERT INTO config.plc_mapping (property_id, source_id, address, scale_factor, scale_offset)
SELECT p.id, src.id, v.address, v.scale_factor, v.scale_offset
FROM (VALUES
  ('chocolate_temp', 'ns=3;s=SpikeData',          0.02, 30.5),
  ('hopper_level',   'ns=3;s=PosTrendData',       1.0,   0.0),
  ('running',        'ns=3;s=AlternatingBoolean', 1.0,   0.0),
  ('cycle_count',    'ns=3;s=SlowUInt1',          1.0,   0.0),
  ('air_temp',       'ns=3;s=DipData',            0.02, 10.0)
) AS v (property, address, scale_factor, scale_offset)
JOIN config.machine_property p ON p.name = v.property AND p.retired_at IS NULL
JOIN config.source src ON src.name = 'opcplc' AND src.retired_at IS NULL;
