-- 025 Annotations (step H2a, ADR-0031): notes on a moment or a period,
-- written by a signed-in person on the trend page, shown on every chart of
-- the signal, machine or line they belong to, and in Grafana.
--   1. config.annotation_category: the kinds of note (note, quality issue,
--      maintenance, process change, trial), each with a colour; edited in
--      Mathesar.
--   2. hist.annotation and hist.annotation_removal: append-only (ADR-0006).
--      A correction is a new annotation that names the one it replaces; a
--      removal is a row of its own. Who and when are always kept.
--   3. Functions: for the trend page (role ofm_screens: read, annotate,
--      correct, remove as a signed-in person) and for Grafana (ofm_reader).
-- These are ordinary tables, not split into blocks (they stay small), so
-- they keep their foreign keys to the model (ADR-0030 is about the
-- hypertables).

-- ---------------------------------------------------------------------------
-- 1. Kinds of note
-- ---------------------------------------------------------------------------
CREATE TABLE config.annotation_category (
  id            integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name          text        NOT NULL CHECK (name ~ '^[a-z][a-z0-9_]{0,31}$'),
  display_name  text        NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 40),
  colour        text        NOT NULL DEFAULT '#6c7a89' CHECK (colour ~ '^#[0-9a-fA-F]{6}$'),
  sort_order    integer     NOT NULL DEFAULT 0,
  description   text,
  retired_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT CURRENT_USER,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT CURRENT_USER
);
CREATE UNIQUE INDEX annotation_category_name_active_uq ON config.annotation_category (name) WHERE retired_at IS NULL;
CREATE TRIGGER trg_set_audit_columns BEFORE UPDATE ON config.annotation_category
  FOR EACH ROW EXECUTE FUNCTION config.fn_set_audit_columns();
CREATE TRIGGER trg_audit_log AFTER INSERT OR UPDATE OR DELETE ON config.annotation_category
  FOR EACH ROW EXECUTE FUNCTION audit.fn_log_change();
COMMENT ON TABLE config.annotation_category IS
  'Kinds of annotation on trends (ADR-0031), each with a colour (#rrggbb); retire one instead of deleting it.';
COMMENT ON COLUMN config.annotation_category.colour IS 'Colour of its flags and bands on charts, #rrggbb.';
COMMENT ON COLUMN config.annotation_category.sort_order IS 'Order in the trend page''s list (smallest first).';

INSERT INTO config.annotation_category (name, display_name, colour, sort_order, description) VALUES
  ('note',           'Note',           '#6c7a89', 10, 'Anything worth remembering'),
  ('quality_issue',  'Quality issue',  '#c0392b', 20, 'Out-of-spec product, holds, rejects, complaints'),
  ('maintenance',    'Maintenance',    '#3e7cb1', 30, 'Repairs, adjustments, part changes, calibration'),
  ('process_change', 'Process change', '#e8a317', 40, 'Setpoints, recipes, raw material lots, settings'),
  ('trial',          'Trial',          '#8e6cb0', 50, 'Experiments and trials');

-- ---------------------------------------------------------------------------
-- 2. Annotations, append-only
-- ---------------------------------------------------------------------------
CREATE TABLE hist.annotation (
  id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ts           timestamptz NOT NULL,
  ts_end       timestamptz,
  property_id  integer     REFERENCES config.machine_property (id) ON DELETE RESTRICT,
  machine_id   integer     REFERENCES config.machine (id) ON DELETE RESTRICT,
  line_id      integer     REFERENCES config.line (id) ON DELETE RESTRICT,
  category_id  integer     NOT NULL REFERENCES config.annotation_category (id) ON DELETE RESTRICT,
  text         text        NOT NULL CHECK (length(btrim(text)) BETWEEN 1 AND 500),
  person_id    integer     NOT NULL REFERENCES config.person (id) ON DELETE RESTRICT,
  replaces_id  bigint      UNIQUE REFERENCES hist.annotation (id) ON DELETE RESTRICT,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (ts_end IS NULL OR ts_end > ts),
  CHECK (num_nonnulls(property_id, machine_id, line_id) = 1)
);
CREATE INDEX annotation_property_ts_idx ON hist.annotation (property_id, ts) WHERE property_id IS NOT NULL;
CREATE INDEX annotation_machine_ts_idx  ON hist.annotation (machine_id, ts)  WHERE machine_id IS NOT NULL;
CREATE INDEX annotation_line_ts_idx     ON hist.annotation (line_id, ts)     WHERE line_id IS NOT NULL;
COMMENT ON TABLE hist.annotation IS
  'Notes on trends (ADR-0031): a moment (ts) or a period (ts to ts_end), on one signal, machine or line, by a signed-in person. Append-only: a correction is a new row with replaces_id; a removal is a row in hist.annotation_removal.';
COMMENT ON COLUMN hist.annotation.replaces_id IS 'The annotation this one corrects; that one is no longer shown.';

CREATE TABLE hist.annotation_removal (
  annotation_id  bigint      PRIMARY KEY REFERENCES hist.annotation (id) ON DELETE RESTRICT,
  person_id      integer     NOT NULL REFERENCES config.person (id) ON DELETE RESTRICT,
  reason         text        CHECK (reason IS NULL OR length(reason) <= 200),
  removed_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE hist.annotation_removal IS 'Annotations removed from the charts, by whom and when (ADR-0031); the annotation itself is kept.';

-- Written only through the functions below (as a signed-in person).
REVOKE ALL ON hist.annotation, hist.annotation_removal FROM ofm_runtime;
GRANT SELECT ON hist.annotation, hist.annotation_removal TO ofm_reader;

-- ---------------------------------------------------------------------------
-- 3. Functions
-- ---------------------------------------------------------------------------

-- The kinds of note, for the trend page.
CREATE FUNCTION config.fn_annotation_categories()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'displayName', c.display_name, 'colour', c.colour)
                            ORDER BY c.sort_order, c.display_name), '[]'::jsonb)
  FROM config.annotation_category c WHERE c.retired_at IS NULL
$$;

-- The annotations shown, with what they belong to, in words.
CREATE VIEW hist.vw_annotation AS
SELECT a.id, a.ts, a.ts_end, a.property_id, a.machine_id, a.line_id,
       CASE WHEN a.property_id IS NOT NULL THEN 'signal' WHEN a.machine_id IS NOT NULL THEN 'machine' ELSE 'line' END AS scope,
       coalesce(pm.display_name || ' · ' || p.display_name, m.display_name, l.display_name) AS scope_name,
       coalesce(p.machine_id, a.machine_id) AS of_machine_id,
       coalesce(pm.line_id, m.line_id, a.line_id) AS of_line_id,
       c.name AS category, c.display_name AS category_name, c.colour,
       a.text, pe.display_name AS person, a.person_id, a.created_at, a.replaces_id
FROM hist.annotation a
JOIN config.annotation_category c ON c.id = a.category_id
JOIN config.person pe ON pe.id = a.person_id
LEFT JOIN config.machine_property p ON p.id = a.property_id
LEFT JOIN config.machine pm ON pm.id = p.machine_id
LEFT JOIN config.machine m ON m.id = a.machine_id
LEFT JOIN config.line l ON l.id = a.line_id
WHERE NOT EXISTS (SELECT 1 FROM hist.annotation_removal r WHERE r.annotation_id = a.id)
  AND NOT EXISTS (SELECT 1 FROM hist.annotation n WHERE n.replaces_id = a.id);
COMMENT ON VIEW hist.vw_annotation IS 'Annotations shown on charts: not removed and not replaced by a correction (ADR-0031).';
GRANT SELECT ON hist.vw_annotation TO ofm_reader;

-- For a chart: the annotations of its signals, of their machines and of
-- their lines that touch [p_from, p_to). At most 1,000, oldest first.
CREATE FUNCTION hist.fn_trend_annotations(p_property_ids integer[], p_from timestamptz, p_to timestamptz)
RETURNS TABLE (id bigint, ts_ms bigint, ts_end_ms bigint, scope text, scope_name text, property_id integer, machine_id integer,
               line_id integer, category text, category_name text, colour text, text text, person text, created_ms bigint,
               corrected boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  WITH pens AS (
    SELECT p.id, p.machine_id, m.line_id
    FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id
    WHERE p.id = ANY (p_property_ids)
  )
  SELECT v.id, floor(extract(epoch FROM v.ts) * 1000)::bigint, floor(extract(epoch FROM v.ts_end) * 1000)::bigint,
         v.scope, v.scope_name, v.property_id, v.machine_id, v.line_id, v.category, v.category_name, v.colour, v.text,
         v.person, floor(extract(epoch FROM v.created_at) * 1000)::bigint, v.replaces_id IS NOT NULL
  FROM hist.vw_annotation v
  WHERE v.ts < p_to AND coalesce(v.ts_end, v.ts) >= p_from
    AND (v.property_id IN (SELECT pens.id FROM pens)
         OR v.machine_id IN (SELECT pens.machine_id FROM pens)
         OR v.line_id IN (SELECT pens.line_id FROM pens))
  ORDER BY v.ts, v.id
  LIMIT 1000
$$;
COMMENT ON FUNCTION hist.fn_trend_annotations(integer[], timestamptz, timestamptz) IS
  'Annotations of these signals, their machines and their lines touching [from, to), for the trend page (ADR-0031).';

-- For Grafana: a line's annotations and those of its machines and signals,
-- in Grafana's annotation columns (time, timeend, text, tags).
CREATE FUNCTION hist.fn_line_annotations(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE ("time" timestamptz, timeend timestamptz, text text, tags text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT v.ts, coalesce(v.ts_end, v.ts),
         v.category_name || ' · ' || v.scope_name || ': ' || v.text || ' (' || v.person || ')',
         v.category_name
  FROM hist.vw_annotation v
  WHERE v.of_line_id = p_line_id AND v.ts < p_to AND coalesce(v.ts_end, v.ts) >= p_from
  ORDER BY v.ts
  LIMIT 1000
$$;
COMMENT ON FUNCTION hist.fn_line_annotations(integer, timestamptz, timestamptz) IS
  'A line''s annotations (and its machines'' and signals'') for Grafana: time, timeend, text, tags (ADR-0031).';

-- A signed-in person annotates: scope 'signal' (p_target_id = property),
-- 'machine' or 'line'; p_replaces = the annotation this one corrects.
CREATE FUNCTION config.fn_person_annotate(p_person_id integer, p_ts timestamptz, p_ts_end timestamptz, p_scope text,
                                          p_target_id integer, p_category_id integer, p_text text, p_replaces bigint DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE r bigint;
BEGIN
  PERFORM config.fn_person_acting(p_person_id);                   -- signed in, active
  IF p_scope NOT IN ('signal', 'machine', 'line') THEN
    RAISE EXCEPTION 'an annotation belongs to a signal, a machine or a line' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM config.annotation_category c WHERE c.id = p_category_id AND c.retired_at IS NULL) THEN
    RAISE EXCEPTION 'unknown kind of annotation' USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF p_replaces IS NOT NULL AND NOT EXISTS (SELECT 1 FROM hist.vw_annotation v WHERE v.id = p_replaces) THEN
    RAISE EXCEPTION 'annotation % was removed or corrected already', p_replaces USING ERRCODE = 'check_violation';
  END IF;
  INSERT INTO hist.annotation (ts, ts_end, property_id, machine_id, line_id, category_id, text, person_id, replaces_id)
  VALUES (p_ts, p_ts_end,
          CASE WHEN p_scope = 'signal' THEN p_target_id END,
          CASE WHEN p_scope = 'machine' THEN p_target_id END,
          CASE WHEN p_scope = 'line' THEN p_target_id END,
          p_category_id, btrim(p_text), p_person_id, p_replaces)
  RETURNING id INTO r;
  PERFORM set_config('ofm.person_id', '', true);
  RETURN r;
END $$;

-- A signed-in person removes an annotation from the charts (it is kept).
CREATE FUNCTION config.fn_person_annotation_remove(p_person_id integer, p_annotation_id bigint, p_reason text DEFAULT NULL)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE r timestamptz;
BEGIN
  PERFORM config.fn_person_acting(p_person_id);
  IF NOT EXISTS (SELECT 1 FROM hist.vw_annotation v WHERE v.id = p_annotation_id) THEN
    RAISE EXCEPTION 'annotation % was removed or corrected already', p_annotation_id USING ERRCODE = 'check_violation';
  END IF;
  INSERT INTO hist.annotation_removal (annotation_id, person_id, reason)
  VALUES (p_annotation_id, p_person_id, nullif(btrim(left(p_reason, 200)), ''))
  RETURNING removed_at INTO r;
  PERFORM set_config('ofm.person_id', '', true);
  RETURN r;
END $$;

REVOKE ALL ON FUNCTION config.fn_annotation_categories(), hist.fn_trend_annotations(integer[], timestamptz, timestamptz),
  hist.fn_line_annotations(integer, timestamptz, timestamptz),
  config.fn_person_annotate(integer, timestamptz, timestamptz, text, integer, integer, text, bigint),
  config.fn_person_annotation_remove(integer, bigint, text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION config.fn_annotation_categories(), hist.fn_trend_annotations(integer[], timestamptz, timestamptz),
  config.fn_person_annotate(integer, timestamptz, timestamptz, text, integer, integer, text, bigint),
  config.fn_person_annotation_remove(integer, bigint, text)
TO ofm_screens;
GRANT EXECUTE ON FUNCTION config.fn_annotation_categories(), hist.fn_trend_annotations(integer[], timestamptz, timestamptz),
  hist.fn_line_annotations(integer, timestamptz, timestamptz)
TO ofm_reader;
-- the sign-in functions of migration 018 are already granted to ofm_screens
