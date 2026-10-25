-- 007 Reserve the machine name 'foodsafety'.
-- Food safety check states are published on .../{line}/foodsafety/{check}
-- (ADR-0015), so no machine may be called 'foodsafety'. The constraint is
-- replaced with the complete list of line-level topic words.
ALTER TABLE config.machine DROP CONSTRAINT machine_name_not_reserved;
ALTER TABLE config.machine ADD CONSTRAINT machine_name_not_reserved
  CHECK (name NOT IN ('workorder', 'kpi', 'spc', 'foodsafety'));
