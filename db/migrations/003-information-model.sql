-- 003 Information Model: what is measured, and where it comes from
-- (Architecture Overview §5, ADR-0001, ADR-0007).

-- ---------------------------------------------------------------------------
-- Engineering units. One list for the whole platform, so degC, °C and C can
-- never coexist. unece_code is the UN/ECE Recommendation 20 code, which OPC UA
-- also uses for its EngineeringUnits.
-- ---------------------------------------------------------------------------
CREATE TABLE config.engineering_unit (
  id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         text NOT NULL UNIQUE CHECK (code ~ '^[A-Za-z0-9_%/.\-]{1,32}$'),
  symbol       text NOT NULL,
  quantity     text NOT NULL,        -- what it measures: temperature, pressure, ...
  unece_code   text,
  description  text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   text        NOT NULL DEFAULT current_user,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   text        NOT NULL DEFAULT current_user
);

INSERT INTO config.engineering_unit (code, symbol, quantity, unece_code) VALUES
  ('degC',     '°C',     'temperature',      'CEL'),
  ('bar',      'bar',    'pressure',         'BAR'),
  ('kPa',      'kPa',    'pressure',         'KPA'),
  ('pct',      '%',      'ratio',            'P1'),
  ('rpm',      'rpm',    'rotational speed', 'RPM'),
  ('Hz',       'Hz',     'frequency',        'HTZ'),
  ('A',        'A',      'electric current', 'AMP'),
  ('V',        'V',      'voltage',          'VLT'),
  ('kW',       'kW',     'power',            'KWT'),
  ('kWh',      'kWh',    'energy',           'KWH'),
  ('kg',       'kg',     'mass',             'KGM'),
  ('g',        'g',      'mass',             'GRM'),
  ('kg_per_h', 'kg/h',   'mass flow',        'E93'),
  ('m3_per_h', 'm³/h',   'volume flow',      'MQH'),
  ('l',        'L',      'volume',           'LTR'),
  ('mm',       'mm',     'length',           'MMT'),
  ('m_per_min','m/min',  'linear speed',     '2X'),
  ('s',        's',      'time',             'SEC'),
  ('min',      'min',    'time',             'MIN'),
  ('pcs',      'pcs',    'count',            'H87'),
  ('pcs_per_min','pcs/min','production rate', NULL);

-- ---------------------------------------------------------------------------
-- Acquisition sources: one row per PLC or OPC UA server connection.
-- ---------------------------------------------------------------------------
CREATE TABLE config.source (
  id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name          text NOT NULL CHECK (config.fn_is_valid_name(name)),   -- used in ofm/_system/sources/{name}
  display_name  text NOT NULL,
  description   text,
  protocol      text NOT NULL CHECK (protocol IN ('opcua', 's7', 'modbus', 'mqtt')),
  endpoint      text NOT NULL,     -- e.g. opc.tcp://opcplc:50000 or 192.168.10.21
  settings      jsonb NOT NULL DEFAULT '{}'::jsonb,   -- protocol details: rack/slot, poll interval, security mode
  runtime_name  text NOT NULL DEFAULT 'ofm_runtime_01' CHECK (config.fn_is_valid_name(runtime_name)),
                                   -- the Node-RED instance that owns this source (Overview §7.3)
  is_enabled    boolean NOT NULL DEFAULT true,
  retired_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT current_user,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT current_user
);
CREATE UNIQUE INDEX source_name_active_uq ON config.source (name) WHERE retired_at IS NULL;

-- ---------------------------------------------------------------------------
-- Properties: what is observed on a machine (or on one of its sub-assets).
-- The topic is derived from the names; nothing here stores a topic string.
-- ---------------------------------------------------------------------------
CREATE TABLE config.machine_property (
  id                       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  machine_id               integer NOT NULL REFERENCES config.machine (id) ON DELETE RESTRICT,
  sub_asset_id             integer,
  name                     text NOT NULL CHECK (config.fn_is_valid_name(name)),
  display_name             text NOT NULL,
  description              text,
  datatype                 text NOT NULL CHECK (datatype IN ('float', 'int', 'bool', 'string')),
  engineering_unit_id      integer REFERENCES config.engineering_unit (id) ON DELETE RESTRICT,
  low                      double precision,   -- engineering range
  high                     double precision,
  alarm_low                double precision,
  alarm_high               double precision,
  deadband                 double precision NOT NULL DEFAULT 0 CHECK (deadband >= 0),
  max_publish_interval_ms  integer NOT NULL DEFAULT 60000 CHECK (max_publish_interval_ms >= 1000),  -- ADR-0007
  is_historised            boolean NOT NULL DEFAULT true,
  retired_at               timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  created_by               text        NOT NULL DEFAULT current_user,
  updated_at               timestamptz NOT NULL DEFAULT now(),
  updated_by               text        NOT NULL DEFAULT current_user,
  -- A sub-asset must belong to the same machine.
  CONSTRAINT machine_property_sub_asset_fk FOREIGN KEY (machine_id, sub_asset_id)
    REFERENCES config.sub_asset (machine_id, id) ON DELETE RESTRICT,
  -- Same rule as the _meta payload schema: numbers need a unit.
  CONSTRAINT machine_property_unit_required
    CHECK (datatype NOT IN ('float', 'int') OR engineering_unit_id IS NOT NULL),
  CONSTRAINT machine_property_range_valid CHECK (low IS NULL OR high IS NULL OR low < high),
  -- .../{machine}/state is the machine state topic (ADR-0006).
  CONSTRAINT machine_property_name_not_reserved CHECK (name <> 'state')
);
CREATE UNIQUE INDEX machine_property_name_active_uq
  ON config.machine_property (machine_id, COALESCE(sub_asset_id, 0), name) WHERE retired_at IS NULL;

-- ---------------------------------------------------------------------------
-- PLC mapping: binds a property to an address on a source. When maintenance
-- moves a tag, this row changes and nothing else notices.
-- Engineering value = raw value * scale_factor + scale_offset.
-- ---------------------------------------------------------------------------
CREATE TABLE config.plc_mapping (
  id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  property_id   integer NOT NULL REFERENCES config.machine_property (id) ON DELETE RESTRICT,
  source_id     integer NOT NULL REFERENCES config.source (id) ON DELETE RESTRICT,
  address       text NOT NULL CHECK (length(address) BETWEEN 1 AND 1024),  -- DB20.DBD4, ns=3;s=..., 40001
  scale_factor  double precision NOT NULL DEFAULT 1,
  scale_offset  double precision NOT NULL DEFAULT 0,
  is_enabled    boolean NOT NULL DEFAULT true,
  retired_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT current_user,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT current_user
);
-- Two PLCs may use the same address, one PLC may not (ADR-0001 amendment).
CREATE UNIQUE INDEX plc_mapping_address_active_uq ON config.plc_mapping (source_id, address) WHERE retired_at IS NULL;
-- At most one active acquisition path per property.
CREATE UNIQUE INDEX plc_mapping_property_active_uq ON config.plc_mapping (property_id) WHERE retired_at IS NULL;

-- ---------------------------------------------------------------------------
-- Relationships between machines (feeds, supplies, ...). Present from Phase 1
-- but unused until Phase 4, so the door stays open (Overview §5, §19).
-- ---------------------------------------------------------------------------
CREATE TABLE config.asset_relationship (
  id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  from_machine_id  integer NOT NULL REFERENCES config.machine (id) ON DELETE RESTRICT,
  to_machine_id    integer NOT NULL REFERENCES config.machine (id) ON DELETE RESTRICT,
  relation_type    text NOT NULL CHECK (config.fn_is_valid_name(relation_type)),
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       text        NOT NULL DEFAULT current_user,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       text        NOT NULL DEFAULT current_user,
  CONSTRAINT asset_relationship_uq UNIQUE (from_machine_id, to_machine_id, relation_type),
  CONSTRAINT asset_relationship_not_self CHECK (from_machine_id <> to_machine_id)
);

CALL audit.fn_enable('config.engineering_unit');
CALL audit.fn_enable('config.source');
CALL audit.fn_enable('config.machine_property');
CALL audit.fn_enable('config.plc_mapping');
CALL audit.fn_enable('config.asset_relationship');

COMMENT ON TABLE config.engineering_unit   IS 'Platform-wide list of engineering units (UN/ECE Rec. 20 codes).';
COMMENT ON TABLE config.source             IS 'An acquisition connection: one PLC or OPC UA server.';
COMMENT ON TABLE config.machine_property   IS 'Something observed on a machine: datatype, unit, limits, publish and historian policy.';
COMMENT ON TABLE config.plc_mapping        IS 'Where a property is read: source, address and scaling.';
COMMENT ON TABLE config.asset_relationship IS 'Relationships between machines; unused until Phase 4.';
