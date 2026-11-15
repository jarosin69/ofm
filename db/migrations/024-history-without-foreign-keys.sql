-- 024 History refers to the model by ID only, without foreign keys
-- (ADR-0030; found on the laptop 2026-11-15 with the made-up year, step H1).
--
-- hist.measurement, hist.measurement_text and hist.production_count had a
-- foreign key to config.machine_property. TimescaleDB copies such a key onto
-- every block (chunk) of the history, one per day: after a year,
-- machine_property is "linked from" hundreds of tables. Mathesar shows one
-- panel of linked records per linking table on a record's page and reloads
-- them all on every save, so saving one property took minutes (370 links
-- with the made-up year; the same would have come with a year of real
-- history). Every value written also checked the key, which costs time on a
-- busy historian.
--
-- What the keys protected stays protected:
-- - an ID cannot be changed: model IDs are generated identity columns
--   (ADR-0004), PostgreSQL refuses to set them;
-- - a property with history cannot be deleted: the trigger below refuses it
--   (same error code as a foreign key, 23503); properties are retired, not
--   deleted. The demo and load-test removals delete the history first, as
--   before.
-- - only the runtime writes history, with IDs from its copy of the model.

ALTER TABLE hist.measurement      DROP CONSTRAINT measurement_property_id_fkey;
ALTER TABLE hist.measurement_text DROP CONSTRAINT measurement_text_property_id_fkey;
ALTER TABLE hist.production_count DROP CONSTRAINT production_count_property_id_fkey;

CREATE FUNCTION config.fn_refuse_delete_property_with_history()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM hist.measurement m WHERE m.property_id = OLD.id)
     OR EXISTS (SELECT 1 FROM hist.measurement_text m WHERE m.property_id = OLD.id)
     OR EXISTS (SELECT 1 FROM hist.production_count c WHERE c.property_id = OLD.id) THEN
    RAISE EXCEPTION 'property % (%) has history and cannot be deleted', OLD.id, OLD.name
      USING ERRCODE = 'foreign_key_violation',
            HINT = 'Retire it instead: set retired_at. Its history stays readable (ADR-0004, ADR-0030).';
  END IF;
  RETURN OLD;
END $$;
COMMENT ON FUNCTION config.fn_refuse_delete_property_with_history() IS
  'Refuses to delete a property that has history (in place of the foreign keys from history, ADR-0030).';

CREATE TRIGGER trg_refuse_delete_with_history
  BEFORE DELETE ON config.machine_property
  FOR EACH ROW EXECUTE FUNCTION config.fn_refuse_delete_property_with_history();

COMMENT ON COLUMN hist.measurement.property_id IS
  'config.machine_property.id; by ID only, no foreign key (ADR-0030): a property with history cannot be deleted (trigger), IDs cannot change.';
COMMENT ON COLUMN hist.measurement_text.property_id IS
  'config.machine_property.id; by ID only, no foreign key (ADR-0030).';
COMMENT ON COLUMN hist.production_count.property_id IS
  'config.machine_property.id; by ID only, no foreign key (ADR-0030).';
