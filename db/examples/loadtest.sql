-- Load-test line (step 2.9), for measuring what one runtime can carry.
-- Not a migration: add it, or change its size, with
--   docker compose --profile loadtest up -d
--   docker compose run --rm migrate loadtest [N]        (default 2000)
-- and remove it, with all its history, with
--   docker compose run --rm migrate loadtest-remove
--
-- N integer properties on 20 machines of one line, enterprise "ofmload" -
-- kept apart from any real or example plant - each mapped to one fast node
-- of the second OPC PLC simulator (service "opcplc-load", started with
-- --fn=N --fr=1: every node changes once a second). So N values per second
-- go the real way: OPC UA acquisition, the UNS, the historian.
-- Running it again with another N adds or retires properties to match.
-- psql variable :n = number of properties.

INSERT INTO config.enterprise (name, display_name, description)
VALUES ('ofmload', 'OFM load test', 'Synthetic load for measuring the runtime (step 2.9); remove with migrate loadtest-remove')
ON CONFLICT (name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.site (enterprise_id, name, display_name, time_zone)
SELECT id, 'lab', 'Test lab', 'Australia/Melbourne'
FROM config.enterprise WHERE name = 'ofmload' AND retired_at IS NULL
ON CONFLICT (enterprise_id, name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.area (site_id, name, display_name)
SELECT s.id, 'loadtest', 'Load test'
FROM config.site s JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'ofmload' AND s.name = 'lab' AND s.retired_at IS NULL
ON CONFLICT (site_id, name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.line (area_id, name, display_name)
SELECT a.id, 'loadline01', 'Load line 1'
FROM config.area a JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'ofmload' AND s.name = 'lab' AND a.name = 'loadtest' AND a.retired_at IS NULL
ON CONFLICT (area_id, name) WHERE retired_at IS NULL DO NOTHING;

CREATE TEMP VIEW load_line AS
SELECT l.id
FROM config.line l JOIN config.area a ON a.id = l.area_id
JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'ofmload' AND s.name = 'lab' AND a.name = 'loadtest'
  AND l.name = 'loadline01' AND l.retired_at IS NULL;

INSERT INTO config.machine (line_id, name, display_name, description)
SELECT load_line.id, 'loadmachine' || lpad(g::text, 2, '0'), 'Load machine ' || g, 'Synthetic machine for the load test'
FROM load_line, generate_series(1, 20) g
ON CONFLICT (line_id, name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.source (name, display_name, description, protocol, endpoint, settings)
VALUES ('opcplc_load', 'OPC PLC load simulator', 'Second OPC PLC simulator with N fast nodes (service opcplc-load, profile loadtest)',
        'opcua', 'opc.tcp://opcplc-load:50000',
        '{"securityMode": "None", "publishingIntervalMs": 1000}')
ON CONFLICT (name) WHERE retired_at IS NULL DO NOTHING;

-- Property i sits on machine ((i - 1) % 20) + 1 and reads node FastUInt<i>.
CREATE TEMP TABLE wanted AS
SELECT i, 'loadmachine' || lpad((((i - 1) % 20) + 1)::text, 2, '0') AS machine,
       'value' || lpad(i::text, 4, '0') AS name
FROM generate_series(1, :n) i;

INSERT INTO config.machine_property (machine_id, name, display_name, description, datatype, engineering_unit_id, deadband)
SELECT m.id, w.name, 'Load value ' || w.i, 'Counter from simulator node FastUInt' || w.i, 'int', u.id, 0
FROM wanted w
JOIN config.machine m ON m.name = w.machine AND m.retired_at IS NULL
JOIN load_line ON load_line.id = m.line_id
JOIN config.engineering_unit u ON u.code = 'pcs'
ON CONFLICT (machine_id, COALESCE(sub_asset_id, 0), name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.plc_mapping (property_id, source_id, address)
SELECT p.id, src.id, 'nsu=http://microsoft.com/Opc/OpcPlc/;s=FastUInt' || w.i
FROM wanted w
JOIN config.machine m ON m.name = w.machine AND m.retired_at IS NULL
JOIN load_line ON load_line.id = m.line_id
JOIN config.machine_property p ON p.machine_id = m.id AND p.name = w.name AND p.retired_at IS NULL
JOIN config.source src ON src.name = 'opcplc_load' AND src.retired_at IS NULL
ON CONFLICT (property_id) WHERE retired_at IS NULL DO NOTHING;

-- Fewer properties than before: retire the ones beyond N (history kept until loadtest-remove).
UPDATE config.plc_mapping pm SET retired_at = now()
FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id JOIN load_line ON load_line.id = m.line_id
WHERE pm.property_id = p.id AND pm.retired_at IS NULL AND p.retired_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM wanted w WHERE w.name = p.name AND w.machine = m.name);
UPDATE config.machine_property p SET retired_at = now()
FROM config.machine m JOIN load_line ON load_line.id = m.line_id
WHERE p.machine_id = m.id AND p.retired_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM wanted w WHERE w.name = p.name AND w.machine = m.name);
