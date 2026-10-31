-- 010 The historian can record "bad, no value" (ADR-0007, step 2.4).
-- A source that is lost before it ever delivered a value, or an address the
-- PLC refuses, is published as v null, q bad. Until now the historian could
-- not store that (value NOT NULL), so dashboards kept showing the last good
-- value. A missing value is now allowed, but only together with quality bad
-- (2), the same rule as the live payload (schemas/value.schema.json).

ALTER TABLE hist.measurement ALTER COLUMN value DROP NOT NULL;
ALTER TABLE hist.measurement ADD CONSTRAINT measurement_value_or_bad
  CHECK (value IS NOT NULL OR quality = 2);

ALTER TABLE hist.measurement_text ALTER COLUMN value DROP NOT NULL;
ALTER TABLE hist.measurement_text ADD CONSTRAINT measurement_text_value_or_bad
  CHECK (value IS NOT NULL OR quality = 2);

COMMENT ON TABLE hist.measurement IS 'Numeric and boolean property values. quality: 0 good, 1 uncertain, 2 bad. ts_source: 0 device, 1 gateway. value is NULL only with quality bad (no value available).';
COMMENT ON TABLE hist.measurement_text IS 'Text property values. Same codes as hist.measurement; value is NULL only with quality bad.';
