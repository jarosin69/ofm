-- 002 Physical Model: what exists (Architecture Overview §5).
-- enterprise -> site -> area -> line -> machine -> (optional) sub_asset
--
-- Conventions in every table (ADR-0004, ADR-0005):
--   id            immutable integer, generated; never typed, never changed
--   name          topic segment; unique among active siblings
--   display_name  free text for people ("Depositor 1")
--   retired_at    set instead of deleting; a retired row keeps its history
--                 and frees its name for reuse
--   created_*/updated_*  maintained automatically

CREATE TABLE config.enterprise (
  id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name          text NOT NULL CHECK (config.fn_is_valid_name(name)),
  display_name  text NOT NULL,
  description   text,
  retired_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT current_user,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT current_user,
  -- 'ofm' is the platform's own topic branch (ofm/_system, ofm/_unmapped, ofm/_cmd)
  CONSTRAINT enterprise_name_not_reserved CHECK (name <> 'ofm')
);
CREATE UNIQUE INDEX enterprise_name_active_uq ON config.enterprise (name) WHERE retired_at IS NULL;

CREATE TABLE config.site (
  id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  enterprise_id  integer NOT NULL REFERENCES config.enterprise (id) ON DELETE RESTRICT,
  name           text NOT NULL CHECK (config.fn_is_valid_name(name)),
  display_name   text NOT NULL,
  description    text,
  -- Local time zone for displays, shifts and KPI periods (ADR-0003, ADR-0008).
  time_zone      text NOT NULL DEFAULT 'Australia/Melbourne'
                 CHECK (config.fn_is_valid_time_zone(time_zone)),
  retired_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     text        NOT NULL DEFAULT current_user,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     text        NOT NULL DEFAULT current_user
);
CREATE UNIQUE INDEX site_name_active_uq ON config.site (enterprise_id, name) WHERE retired_at IS NULL;

CREATE TABLE config.area (
  id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  site_id       integer NOT NULL REFERENCES config.site (id) ON DELETE RESTRICT,
  name          text NOT NULL CHECK (config.fn_is_valid_name(name)),
  display_name  text NOT NULL,
  description   text,
  retired_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT current_user,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT current_user
);
CREATE UNIQUE INDEX area_name_active_uq ON config.area (site_id, name) WHERE retired_at IS NULL;

CREATE TABLE config.line (
  id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  area_id       integer NOT NULL REFERENCES config.area (id) ON DELETE RESTRICT,
  name          text NOT NULL CHECK (config.fn_is_valid_name(name)),
  display_name  text NOT NULL,
  description   text,
  retired_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT current_user,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT current_user
);
CREATE UNIQUE INDEX line_name_active_uq ON config.line (area_id, name) WHERE retired_at IS NULL;

CREATE TABLE config.machine (
  id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id       integer NOT NULL REFERENCES config.line (id) ON DELETE RESTRICT,
  name          text NOT NULL CHECK (config.fn_is_valid_name(name)),
  display_name  text NOT NULL,
  description   text,
  external_ref  text,          -- e.g. CMMS asset number; never used as a key
  retired_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT current_user,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT current_user,
  -- Line-level topics use these words (ADR-0010, ADR-0011).
  CONSTRAINT machine_name_not_reserved CHECK (name NOT IN ('workorder', 'kpi', 'spc'))
);
CREATE UNIQUE INDEX machine_name_active_uq ON config.machine (line_id, name) WHERE retired_at IS NULL;

-- Optional components of a machine (motor, valve, sensor). Their properties
-- get one extra topic level: .../{machine}/{sub_asset}/{property}.
CREATE TABLE config.sub_asset (
  id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  machine_id    integer NOT NULL REFERENCES config.machine (id) ON DELETE RESTRICT,
  name          text NOT NULL CHECK (config.fn_is_valid_name(name)),
  display_name  text NOT NULL,
  description   text,
  external_ref  text,
  retired_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT current_user,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT current_user,
  -- .../{machine}/state is the machine state topic (ADR-0006).
  CONSTRAINT sub_asset_name_not_reserved CHECK (name <> 'state'),
  -- Lets machine_property check that a sub-asset belongs to the same machine.
  CONSTRAINT sub_asset_machine_uq UNIQUE (machine_id, id)
);
CREATE UNIQUE INDEX sub_asset_name_active_uq ON config.sub_asset (machine_id, name) WHERE retired_at IS NULL;

CALL audit.fn_enable('config.enterprise');
CALL audit.fn_enable('config.site');
CALL audit.fn_enable('config.area');
CALL audit.fn_enable('config.line');
CALL audit.fn_enable('config.machine');
CALL audit.fn_enable('config.sub_asset');

COMMENT ON TABLE config.enterprise IS 'Top of the asset hierarchy; first topic segment.';
COMMENT ON TABLE config.site       IS 'A plant. Carries the local time zone used for displays and KPI periods.';
COMMENT ON TABLE config.area       IS 'A production area within a site.';
COMMENT ON TABLE config.line       IS 'A production line; the level at which KPIs and work orders apply.';
COMMENT ON TABLE config.machine    IS 'A machine (ISA-95 work cell) on a line; the level at which states are recorded.';
COMMENT ON TABLE config.sub_asset  IS 'Optional component of a machine (motor, valve, sensor).';
