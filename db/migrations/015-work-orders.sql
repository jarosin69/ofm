-- 015 Work orders (Phase 3a, step 3a.5; ADR-0010).
--
-- 1. config.work_order             what to make: order number, line, product,
--                                  planned quantity; model data, planned in
--                                  Mathesar or created on the spot
-- 2. hist.work_order_event         what happened: start, changeover_end,
--                                  complete; append-only (ADR-0006), each at
--                                  most once per order
-- 3. config.fn_work_order_start, _changeover_end, _complete, _start_new
--                                  the only way operators' screens record an
--                                  event: everything is checked first
-- 4. hist.vw_work_order_interval   each order's start, end of changeover, end
--    hist.vw_line_work_order       each line's newest order and whether it
--                                  is active, for the runtime's .../workorder
--
-- Every event notifies the runtime (channel work_order, payload = line id),
-- which publishes the line's active order, retained, on
-- {enterprise}/{site}/{area}/{line}/workorder (schemas/workorder.schema.json).
-- The changeover window closes at the first changeover_end: an operator's,
-- or the one the runtime records at the first good unit counted at the
-- line's output machine (entered_by 'ofm'). Ramp-up after the first good
-- unit is speed loss (ADR-0010 amendment, open question 10).

-- ---------------------------------------------------------------------------
-- 1. Work orders. Editable until started; then line and product are locked
-- (ADR-0010 decision 2), and an order with events cannot be deleted.
-- ---------------------------------------------------------------------------
CREATE TABLE config.work_order (
  id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  wo_number      text NOT NULL CHECK (wo_number ~ '^[^[:space:]].{0,62}[^[:space:]]$|^[^[:space:]]$'),
  line_id        integer NOT NULL REFERENCES config.line (id) ON DELETE RESTRICT,
  material_id    integer NOT NULL REFERENCES config.material (id) ON DELETE RESTRICT,
  planned_qty    integer NOT NULL CHECK (planned_qty > 0),    -- in the product's base unit
  planned_start  timestamptz,
  note           text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     text        NOT NULL DEFAULT current_user,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     text        NOT NULL DEFAULT current_user,
  CONSTRAINT work_order_number_uq UNIQUE (wo_number)
);
COMMENT ON TABLE config.work_order IS
  'Work orders (ADR-0010): what to make on which line, how many. Editable until started; then line and product are locked. Execution is in hist.work_order_event.';

-- Runs with its owner's rights: it looks at the event history, which the
-- model editors cannot read.
CREATE FUNCTION config.fn_check_work_order()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM config.material
                 WHERE id = NEW.material_id AND material_type IN ('finished', 'semi_finished')) THEN
    RAISE EXCEPTION 'material % is not a product (finished or semi_finished): no work order for it', NEW.material_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.line_id, NEW.material_id) IS DISTINCT FROM (OLD.line_id, OLD.material_id)
     AND EXISTS (SELECT 1 FROM hist.work_order_event WHERE work_order_id = OLD.id) THEN
    RAISE EXCEPTION 'work order % has been started: its line and product cannot change', OLD.wo_number
      USING ERRCODE = 'check_violation',
            HINT = 'Complete it and start a new order for the other line or product.';
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Execution events. One of each kind per order at most: an order is
-- started once, its changeover ends once (the first changeover_end wins;
-- a repeat is ignored), and it is completed once. A completed order is not
-- started again: a new order continues the product.
-- ---------------------------------------------------------------------------
CREATE TABLE hist.work_order_event (
  work_order_id  integer     NOT NULL REFERENCES config.work_order (id) ON DELETE RESTRICT,
  event_type     text        NOT NULL CHECK (event_type IN ('start', 'changeover_end', 'complete')),
  ts             timestamptz NOT NULL,
  entered_by     text        NOT NULL CHECK (length(entered_by) BETWEEN 1 AND 128),
  PRIMARY KEY (work_order_id, event_type)
);
COMMENT ON TABLE hist.work_order_event IS
  'Work order execution (ADR-0010): start, changeover_end, complete, each at most once per order; never updated. entered_by: the person, auto-operator, or ofm (changeover closed at the first good count).';

CREATE TRIGGER trg_check_work_order BEFORE INSERT OR UPDATE ON config.work_order
  FOR EACH ROW EXECUTE FUNCTION config.fn_check_work_order();

-- Events in a sensible order: nothing before the start; no end of changeover
-- after the order is complete.
CREATE FUNCTION hist.fn_check_work_order_event()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE started timestamptz; completed timestamptz;
BEGIN
  IF NEW.event_type = 'start' THEN RETURN NEW; END IF;
  SELECT max(ts) FILTER (WHERE event_type = 'start'), max(ts) FILTER (WHERE event_type = 'complete')
    INTO started, completed
    FROM hist.work_order_event WHERE work_order_id = NEW.work_order_id;
  IF started IS NULL OR NEW.ts < started THEN
    RAISE EXCEPTION 'work order % has no start before %: % refused', NEW.work_order_id, NEW.ts, NEW.event_type
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.event_type = 'changeover_end' AND completed IS NOT NULL THEN
    RAISE EXCEPTION 'work order % is complete: its changeover ended then', NEW.work_order_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_check_work_order_event BEFORE INSERT ON hist.work_order_event
  FOR EACH ROW EXECUTE FUNCTION hist.fn_check_work_order_event();

-- Tell the runtime: it republishes the line's active order.
CREATE FUNCTION hist.fn_notify_work_order_event()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_notify('work_order', (SELECT line_id::text FROM config.work_order WHERE id = NEW.work_order_id));
  RETURN NULL;
END $$;
CREATE TRIGGER trg_notify_work_order_event AFTER INSERT ON hist.work_order_event
  FOR EACH ROW EXECUTE FUNCTION hist.fn_notify_work_order_event();

-- ---------------------------------------------------------------------------
-- 3. Recording events. These functions run with the rights of their owner
-- (SECURITY DEFINER): whoever may call them can record exactly these events,
-- checked, and nothing else. The time is the database's clock (ADR-0003).
-- Granted to the runtime (operator screens, step 3a.8); the demo's
-- auto-operator calls them through demo.start_order (db/examples).
-- ---------------------------------------------------------------------------
CREATE FUNCTION config.fn_work_order_start(p_work_order_id integer, p_entered_by text)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  wo config.work_order;
  sku text;
  line_name text;
  previous integer;
  at timestamptz := now();
BEGIN
  SELECT * INTO wo FROM config.work_order WHERE id = p_work_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'work order % does not exist', p_work_order_id USING ERRCODE = 'no_data_found';
  END IF;
  -- One start at a time per line.
  SELECT name INTO line_name FROM config.line WHERE id = wo.line_id AND retired_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'the line of work order % is retired', wo.wo_number USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM hist.work_order_event WHERE work_order_id = wo.id AND event_type = 'complete') THEN
    RAISE EXCEPTION 'work order % is complete', wo.wo_number
      USING ERRCODE = 'check_violation', HINT = 'Start a new order to make more of this product.';
  END IF;
  IF EXISTS (SELECT 1 FROM hist.work_order_event WHERE work_order_id = wo.id AND event_type = 'start') THEN
    RAISE EXCEPTION 'work order % is already running', wo.wo_number USING ERRCODE = 'check_violation';
  END IF;
  SELECT code INTO sku FROM config.material WHERE id = wo.material_id;
  IF config.fn_material_rate(wo.line_id, wo.material_id, at) IS NULL THEN
    RAISE EXCEPTION 'product % has no rated speed on line % at %', sku, line_name, at
      USING ERRCODE = 'check_violation',
            HINT = 'Add a row to config.material_line_rate in Mathesar first: performance is judged against it (ADR-0010).';
  END IF;
  -- Starting an order completes the line's running order, at the same time.
  SELECT e.work_order_id INTO previous
  FROM hist.work_order_event e JOIN config.work_order w ON w.id = e.work_order_id
  WHERE w.line_id = wo.line_id AND e.event_type = 'start'
    AND NOT EXISTS (SELECT 1 FROM hist.work_order_event c WHERE c.work_order_id = e.work_order_id AND c.event_type = 'complete');
  IF previous IS NOT NULL THEN
    INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (previous, 'complete', at, p_entered_by);
  END IF;
  INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (wo.id, 'start', at, p_entered_by);
  RETURN at;
END $$;

CREATE FUNCTION config.fn_work_order_complete(p_work_order_id integer, p_entered_by text)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE at timestamptz := now();
BEGIN
  IF NOT EXISTS (SELECT 1 FROM hist.work_order_event WHERE work_order_id = p_work_order_id AND event_type = 'start') THEN
    RAISE EXCEPTION 'work order % has not been started', p_work_order_id USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM hist.work_order_event WHERE work_order_id = p_work_order_id AND event_type = 'complete') THEN
    RAISE EXCEPTION 'work order % is already complete', p_work_order_id USING ERRCODE = 'check_violation';
  END IF;
  INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (p_work_order_id, 'complete', at, p_entered_by);
  RETURN at;
END $$;

-- Closes the changeover window (operator's "Changeover done"). If it is
-- already closed, nothing changes and the time it closed is returned.
CREATE FUNCTION config.fn_work_order_changeover_end(p_work_order_id integer, p_entered_by text)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE closed timestamptz;
BEGIN
  SELECT ts INTO closed FROM hist.work_order_event WHERE work_order_id = p_work_order_id AND event_type = 'changeover_end';
  IF FOUND THEN RETURN closed; END IF;
  INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by)
  VALUES (p_work_order_id, 'changeover_end', now(), p_entered_by);
  RETURN now();
END $$;

-- An order created on the spot (SKU and quantity) and started. Its number
-- is "adhoc-" and its id. Returns the new order's id.
CREATE FUNCTION config.fn_work_order_start_new(p_line_id integer, p_sku text, p_planned_qty integer, p_entered_by text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE mat integer; new_id integer;
BEGIN
  SELECT id INTO mat FROM config.material WHERE code = p_sku AND retired_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no product with code %', p_sku USING ERRCODE = 'no_data_found';
  END IF;
  INSERT INTO config.work_order (wo_number, line_id, material_id, planned_qty, note)
  VALUES ('adhoc-' || txid_current() || '-' || p_line_id, p_line_id, mat, p_planned_qty, 'Created and started by ' || p_entered_by)
  RETURNING id INTO new_id;
  UPDATE config.work_order SET wo_number = 'adhoc-' || new_id WHERE id = new_id;
  PERFORM config.fn_work_order_start(new_id, p_entered_by);
  RETURN new_id;
END $$;

REVOKE ALL ON FUNCTION config.fn_work_order_start(integer, text), config.fn_work_order_complete(integer, text),
  config.fn_work_order_changeover_end(integer, text), config.fn_work_order_start_new(integer, text, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION config.fn_work_order_start(integer, text), config.fn_work_order_complete(integer, text),
  config.fn_work_order_changeover_end(integer, text), config.fn_work_order_start_new(integer, text, integer, text) TO ofm_runtime;

-- ---------------------------------------------------------------------------
-- 4. Orders as intervals. The changeover window runs from the start to the
-- first changeover_end, or to the completion if none was recorded.
-- ---------------------------------------------------------------------------
CREATE VIEW hist.vw_work_order_interval AS
SELECT
  w.id           AS work_order_id,
  w.wo_number,
  w.line_id,
  w.material_id,
  m.code         AS sku,
  w.planned_qty,
  s.ts           AS started_at,
  c.ts           AS changeover_end_at,
  x.ts           AS completed_at,
  s.entered_by   AS started_by,
  c.entered_by   AS changeover_ended_by,
  x.entered_by   AS completed_by
FROM config.work_order w
JOIN config.material m ON m.id = w.material_id
JOIN hist.work_order_event s ON s.work_order_id = w.id AND s.event_type = 'start'
LEFT JOIN hist.work_order_event c ON c.work_order_id = w.id AND c.event_type = 'changeover_end'
LEFT JOIN hist.work_order_event x ON x.work_order_id = w.id AND x.event_type = 'complete';
COMMENT ON VIEW hist.vw_work_order_interval IS
  'Each started work order: start, end of changeover (NULL while open, or if completed during it), completion (NULL while running) (ADR-0010).';

-- Each line's newest started order: active, or the last one completed. What
-- the runtime publishes on .../workorder; ts = the time of its newest event.
-- good_property_id: the counter whose first good unit closes the changeover
-- (count_good of the line's output machine, ADR-0008 amendment).
CREATE VIEW hist.vw_line_work_order AS
SELECT DISTINCT ON (i.line_id)
  i.line_id,
  concat_ws('/', e.name, s.name, a.name, l.name) AS line_topic,
  i.completed_at IS NULL                         AS active,
  greatest(i.started_at, i.changeover_end_at, i.completed_at) AS ts,
  i.work_order_id, i.wo_number, i.material_id, i.sku, i.planned_qty, i.started_at,
  i.changeover_end_at IS NULL AND i.completed_at IS NULL     AS changeover,
  config.fn_material_rate(i.line_id, i.material_id, now())   AS rate_per_hour,
  (SELECT c.property_id FROM config.fn_line_count_properties((config.fn_line_kpi_rule(i.line_id, now())).id) c
   WHERE c.kind = 'good' LIMIT 1)                             AS good_property_id
FROM hist.vw_work_order_interval i
JOIN config.line l       ON l.id = i.line_id AND l.retired_at IS NULL
JOIN config.area a       ON a.id = l.area_id
JOIN config.site s       ON s.id = a.site_id
JOIN config.enterprise e ON e.id = s.enterprise_id
ORDER BY i.line_id, i.started_at DESC, i.work_order_id DESC;   -- same time: the later order
COMMENT ON VIEW hist.vw_line_work_order IS
  'Per line, its newest started work order and whether it is active: the content of {line}/workorder (ADR-0010).';

CALL audit.fn_enable('config.work_order');
-- Orders are not part of the runtime model (config.vw_runtime_model): editing
-- one must not make the runtime reload it. Their events notify on their own
-- channel (section 2).
DROP TRIGGER trg_notify_model_changed ON config.work_order;
