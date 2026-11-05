-- 012 Production context (Phase 3a, step 3a.2): what a line makes, how fast,
-- when it is scheduled, and the KPI rules of each line - the facts OEE needs
-- (ADR-0008, ADR-0009, ADR-0010, ADR-0014).
--
-- 1. config.loss_category       the positions of the time waterfall (reference data)
-- 2. config.material            the material master; a product is a material of
--                               type finished or semi_finished (ADR-0014)
-- 3. config.material_line_rate  rated speed of a material on a line, from a date (ADR-0010)
-- 4. config.line_kpi_rule       a line's constraint machine and minor-stop threshold,
--                               from a date; its id is the KPI definition version
--                               reported with every KPI result (ADR-0008 amendment)
-- 5. config.line_schedule       weekly windows in the site's local time: production,
--                               and planned cleaning, maintenance or other downtime
--    config.fn_line_schedule()  those windows as real UTC intervals, daylight saving included
--
-- Rates and KPI rules are effective-dated and never changed once in force:
-- history must keep being judged by the rules of its time. A new value is a
-- new row with a later valid_from; a row not yet in force may still be
-- deleted (a typo caught in time). The schedule may be corrected at any time:
-- KPIs are calculated when read, so a corrected schedule reclassifies the
-- affected history (ADR-0009 decision 5).

-- ---------------------------------------------------------------------------
-- A unit for numbers that stand for something rather than measure it (state
-- codes, fault codes). The model requires a unit on every number.
-- ---------------------------------------------------------------------------
INSERT INTO config.engineering_unit (code, symbol, quantity, description) VALUES
  ('code', '', 'code', 'A number that identifies a state, fault or setting; not a quantity');

-- A machine's (line, id) pair, so a line's settings can point only at its own machines.
ALTER TABLE config.machine ADD CONSTRAINT machine_line_id_uq UNIQUE (line_id, id);

-- ---------------------------------------------------------------------------
-- 1. Loss categories (ADR-0008): id = the waterfall position; 90 = Unaccounted,
-- shown after position 12. Fixed by this migration; editors may change only
-- the display name and description.
-- ---------------------------------------------------------------------------
CREATE TABLE config.loss_category (
  id             integer PRIMARY KEY CHECK (id BETWEEN 1 AND 13 OR id = 90),
  name           text NOT NULL UNIQUE CHECK (config.fn_is_valid_name(name)),
  display_name   text NOT NULL,
  category_type  text NOT NULL CHECK (category_type IN
                   ('milestone', 'no_activity', 'planned', 'unplanned', 'speed', 'quality', 'unaccounted')),
  sort_order     integer NOT NULL,
  description    text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     text        NOT NULL DEFAULT current_user,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     text        NOT NULL DEFAULT current_user
);
INSERT INTO config.loss_category (id, name, display_name, category_type, sort_order, description) VALUES
  (1,  'maximum_time',             'Maximum time',             'milestone',   10,  'Calendar time of the period'),
  (2,  'no_activity',              'No activity',              'no_activity', 20,  'Not scheduled, no demand, force majeure'),
  (3,  'hours_used',               'Hours used',               'milestone',   30,  'Scheduled time'),
  (4,  'maintenance',              'Maintenance',              'planned',     40,  'Planned maintenance'),
  (5,  'cleaning',                 'Cleaning',                 'planned',     50,  'Planned cleaning and hygiene'),
  (6,  'changeover',               'Changeover',               'planned',     60,  'From the start of a work order to its first good unit (ADR-0010)'),
  (7,  'other_planned_downtime',   'Other planned downtime',   'planned',     70,  'Breaks, meetings, trials, waiting for an order'),
  (8,  'production_hours',         'Production hours',         'milestone',   80,  'Scheduled time less planned downtime'),
  (9,  'breakdowns',               'Breakdowns',               'unplanned',   90,  'Stops coded as a breakdown'),
  (10, 'speed_loss',               'Speed loss',               'speed',       100, 'Running below rated speed (calculated)'),
  (11, 'quality_loss',             'Quality loss',             'quality',     110, 'Time spent on rejected units (calculated)'),
  (12, 'other_unplanned_downtime', 'Other unplanned downtime', 'unplanned',   120, 'Minor stops, starved and blocked, shortages'),
  (13, 'operating_time',           'Operating time',           'milestone',   140, 'Good units at rated speed'),
  (90, 'unaccounted',              'Unaccounted',              'unaccounted', 125, 'Unknown time and stops nobody has coded yet');
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON config.loss_category FROM ofm_config;
GRANT UPDATE (display_name, description) ON config.loss_category TO ofm_config;
COMMENT ON TABLE config.loss_category IS
  'Positions of the time-based loss waterfall (ADR-0008); id = position, 90 = Unaccounted. Reference data: only display_name and description may be edited.';

-- ---------------------------------------------------------------------------
-- 2. Material master (ADR-0014).
-- ---------------------------------------------------------------------------
CREATE TABLE config.material (
  id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code           text NOT NULL CHECK (code ~ '^[^[:space:]]{1,40}$'),   -- SKU / article number, as text (leading zeros kept)
  name           text NOT NULL,
  material_type  text NOT NULL CHECK (material_type IN ('raw', 'ingredient', 'packaging', 'semi_finished', 'finished')),
  base_unit_id   integer NOT NULL REFERENCES config.engineering_unit (id) ON DELETE RESTRICT,
  description    text,
  external_ref   text,          -- e.g. ERP material number; never used as a key
  retired_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     text        NOT NULL DEFAULT current_user,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     text        NOT NULL DEFAULT current_user
);
CREATE UNIQUE INDEX material_code_active_uq ON config.material (code) WHERE retired_at IS NULL;
COMMENT ON TABLE config.material IS
  'Material master (ADR-0014). A product is a material of type finished or semi_finished; rates, work orders and SPC specifications refer to it.';
COMMENT ON COLUMN config.material.code IS 'SKU or article number as text, no spaces; unique among active materials. Shown as sku on the UNS.';

-- ---------------------------------------------------------------------------
-- Rows in force are never changed (rates, KPI rules). The removal scripts of
-- the demo and test lines may delete them by setting ofm.removing = on.
-- ---------------------------------------------------------------------------
CREATE FUNCTION config.fn_refuse_change_in_force()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_setting('ofm.removing', true) = 'on' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF (to_jsonb(NEW) - ARRAY['note', 'updated_at', 'updated_by'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['note', 'updated_at', 'updated_by']) THEN
      RAISE EXCEPTION '% rows are never changed: add a new row with a later valid_from', TG_TABLE_NAME
        USING ERRCODE = 'check_violation',
              HINT = 'Only the note may be edited. A row whose valid_from is still in the future may be deleted.';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.valid_from <= now() THEN
    RAISE EXCEPTION '% row % is in force since % and cannot be deleted', TG_TABLE_NAME, OLD.id, OLD.valid_from
      USING ERRCODE = 'check_violation',
            HINT = 'History is judged by the rules of its time. Add a new row with a later valid_from instead.';
  END IF;
  RETURN OLD;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Rated speed of a product on a line, from a date (ADR-0010).
-- ---------------------------------------------------------------------------
CREATE TABLE config.material_line_rate (
  id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id        integer NOT NULL REFERENCES config.line (id) ON DELETE RESTRICT,
  material_id    integer NOT NULL REFERENCES config.material (id) ON DELETE RESTRICT,
  rate_per_hour  double precision NOT NULL CHECK (rate_per_hour > 0),   -- in the material's base unit
  valid_from     timestamptz NOT NULL DEFAULT now(),
  note           text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     text        NOT NULL DEFAULT current_user,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     text        NOT NULL DEFAULT current_user,
  CONSTRAINT material_line_rate_uq UNIQUE (line_id, material_id, valid_from)
);
COMMENT ON TABLE config.material_line_rate IS
  'Rated (demonstrated maximum) speed of a product on a line, in its base unit per hour, from valid_from (ADR-0010). Never changed once in force: a new rate is a new row.';

-- Only products have rated speeds.
CREATE FUNCTION config.fn_check_rate_material()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM config.material
                 WHERE id = NEW.material_id AND material_type IN ('finished', 'semi_finished')) THEN
    RAISE EXCEPTION 'material % is not a product (finished or semi_finished): it has no rated speed', NEW.material_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_check_rate_material BEFORE INSERT ON config.material_line_rate
  FOR EACH ROW EXECUTE FUNCTION config.fn_check_rate_material();
CREATE TRIGGER trg_refuse_change_in_force BEFORE UPDATE OR DELETE ON config.material_line_rate
  FOR EACH ROW EXECUTE FUNCTION config.fn_refuse_change_in_force();

-- ---------------------------------------------------------------------------
-- 4. A line's KPI rules, from a date. The row in force at a time is the KPI
-- definition version of results for that time (ADR-0008 decision 7).
-- ---------------------------------------------------------------------------
CREATE TABLE config.line_kpi_rule (
  id                      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id                 integer NOT NULL REFERENCES config.line (id) ON DELETE RESTRICT,
  valid_from              timestamptz NOT NULL DEFAULT now(),
  constraint_machine_id   integer NOT NULL,      -- the line's state and output pace (ADR-0008 decision 5)
  minor_stop_threshold_s  integer NOT NULL DEFAULT 300 CHECK (minor_stop_threshold_s BETWEEN 1 AND 86400),   -- ADR-0009
  note                    text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  created_by              text        NOT NULL DEFAULT current_user,
  updated_at              timestamptz NOT NULL DEFAULT now(),
  updated_by              text        NOT NULL DEFAULT current_user,
  CONSTRAINT line_kpi_rule_uq UNIQUE (line_id, valid_from),
  -- The constraint machine must be a machine of this line.
  CONSTRAINT line_kpi_rule_constraint_machine_fk FOREIGN KEY (line_id, constraint_machine_id)
    REFERENCES config.machine (line_id, id) ON DELETE RESTRICT
);
COMMENT ON TABLE config.line_kpi_rule IS
  'KPI rules of a line from valid_from: constraint machine and minor-stop threshold. Never changed once in force; its id is the KPI definition version (ADR-0008).';
CREATE TRIGGER trg_refuse_change_in_force BEFORE UPDATE OR DELETE ON config.line_kpi_rule
  FOR EACH ROW EXECUTE FUNCTION config.fn_refuse_change_in_force();

-- ---------------------------------------------------------------------------
-- 5. Weekly schedule of a line, in the site's local time (ADR-0009 rule 1 and 5).
-- production: scheduled time (outside it = No activity). maintenance,
-- cleaning, other_planned: planned downtime inside it (positions 4, 5, 7).
-- A window whose end is not after its start ends the next day (22:00-06:00);
-- equal start and end = 24 hours.
-- ---------------------------------------------------------------------------
CREATE TABLE config.line_schedule (
  id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id     integer NOT NULL REFERENCES config.line (id) ON DELETE RESTRICT,
  kind        text NOT NULL CHECK (kind IN ('production', 'maintenance', 'cleaning', 'other_planned')),
  mon         boolean NOT NULL DEFAULT false,
  tue         boolean NOT NULL DEFAULT false,
  wed         boolean NOT NULL DEFAULT false,
  thu         boolean NOT NULL DEFAULT false,
  fri         boolean NOT NULL DEFAULT false,
  sat         boolean NOT NULL DEFAULT false,
  sun         boolean NOT NULL DEFAULT false,
  start_time  time NOT NULL,
  end_time    time NOT NULL,
  valid_from  date NOT NULL DEFAULT current_date,   -- first day a window starts on
  valid_to    date,                                 -- last day; NULL = no end
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text        NOT NULL DEFAULT current_user,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  text        NOT NULL DEFAULT current_user,
  CONSTRAINT line_schedule_some_day CHECK (mon OR tue OR wed OR thu OR fri OR sat OR sun),
  CONSTRAINT line_schedule_dates CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
COMMENT ON TABLE config.line_schedule IS
  'Weekly windows of a line in the site''s local time: production (scheduled time) and planned maintenance, cleaning or other downtime. Read as UTC intervals with config.fn_line_schedule().';

-- The windows of a line that overlap [p_from, p_to), as UTC intervals, cut to
-- that range. Each window is placed on its local calendar day, so a shift on
-- the day clocks go forward is an hour shorter in real time (ADR-0003, ADR-0008).
CREATE FUNCTION config.fn_line_schedule(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (schedule_id integer, kind text, starts_at timestamptz, ends_at timestamptz)
LANGUAGE sql STABLE
AS $$
  WITH zone AS (
    SELECT s.time_zone AS tz
    FROM config.line l
    JOIN config.area a ON a.id = l.area_id
    JOIN config.site s ON s.id = a.site_id
    WHERE l.id = p_line_id
  ),
  local_day AS (            -- every local day that can hold a window touching the range
    SELECT d::date AS day, extract(isodow FROM d)::int AS dow
    FROM zone, generate_series((p_from AT TIME ZONE zone.tz)::date - 1, (p_to AT TIME ZONE zone.tz)::date, interval '1 day') d
  ),
  window_ AS (
    SELECT w.id, w.kind,
           (ld.day + w.start_time) AT TIME ZONE zone.tz AS starts_at,
           ((ld.day + CASE WHEN w.end_time > w.start_time THEN 0 ELSE 1 END) + w.end_time) AT TIME ZONE zone.tz AS ends_at
    FROM config.line_schedule w
    CROSS JOIN zone
    JOIN local_day ld ON (ARRAY[w.mon, w.tue, w.wed, w.thu, w.fri, w.sat, w.sun])[ld.dow]
                     AND ld.day >= w.valid_from AND (w.valid_to IS NULL OR ld.day <= w.valid_to)
    WHERE w.line_id = p_line_id
  )
  SELECT id, kind, greatest(starts_at, p_from), least(ends_at, p_to)
  FROM window_
  WHERE starts_at < p_to AND ends_at > p_from
  ORDER BY 3, 2
$$;
COMMENT ON FUNCTION config.fn_line_schedule(integer, timestamptz, timestamptz) IS
  'The line''s schedule windows overlapping [p_from, p_to) as UTC intervals, cut to the range; daylight saving included.';

-- The rate and KPI rule in force at a time.
CREATE FUNCTION config.fn_material_rate(p_line_id integer, p_material_id integer, p_at timestamptz)
RETURNS double precision
LANGUAGE sql STABLE
AS $$
  SELECT rate_per_hour FROM config.material_line_rate
  WHERE line_id = p_line_id AND material_id = p_material_id AND valid_from <= p_at
  ORDER BY valid_from DESC LIMIT 1
$$;
CREATE FUNCTION config.fn_line_kpi_rule(p_line_id integer, p_at timestamptz)
RETURNS config.line_kpi_rule
LANGUAGE sql STABLE
AS $$
  SELECT * FROM config.line_kpi_rule
  WHERE line_id = p_line_id AND valid_from <= p_at
  ORDER BY valid_from DESC LIMIT 1
$$;

-- Audit columns, audit log and the runtime's model-change notification.
CALL audit.fn_enable('config.loss_category');
CALL audit.fn_enable('config.material');
CALL audit.fn_enable('config.material_line_rate');
CALL audit.fn_enable('config.line_kpi_rule');
CALL audit.fn_enable('config.line_schedule');
