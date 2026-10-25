-- 006 Support for the model editor (Mathesar, ADR-0013).
--
-- 1. A single-column foreign key from machine_property to sub_asset.
--    Mathesar offers related records as a pick-list only for single-column
--    foreign keys. The two-column key from 003 stays: it is what guarantees
--    that a sub-asset belongs to the same machine as the property.
ALTER TABLE config.machine_property
  ADD CONSTRAINT machine_property_sub_asset_id_fk
  FOREIGN KEY (sub_asset_id) REFERENCES config.sub_asset (id) ON DELETE RESTRICT;

-- 2. The login Mathesar uses to connect to this database. On its first
--    connection Mathesar installs its helper schemas (msar, __msar,
--    mathesar_types), which needs CREATE on the database. As a member of
--    ofm_config it sees and edits the model like NocoDB did, nothing more:
--    no access to the historian or the audit log.
--    Its password comes from deploy/.env (OFM_MATHESAR_DB_PASSWORD) and is
--    set by the migration runner, so no secret is stored here.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ofm_mathesar') THEN
    CREATE ROLE ofm_mathesar LOGIN;
  END IF;
  EXECUTE format('GRANT CREATE ON DATABASE %I TO ofm_mathesar', current_database());
END $$;

GRANT ofm_config TO ofm_mathesar;
