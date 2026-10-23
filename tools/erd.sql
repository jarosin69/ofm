-- Generates docs/generated/erd.md: a Mermaid entity-relationship diagram of
-- the config and hist schemas, read from the live database.
-- Run with: docker compose run --rm migrate erd
-- Audit columns (created_*/updated_*) are left out to keep the diagram readable.

WITH tbl AS (
  SELECT c.oid, n.nspname AS schema_name, c.relname AS table_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname IN ('config', 'hist')
    AND c.relkind IN ('r', 'p')
),
col AS (
  SELECT t.table_name, a.attnum, a.attname, ty.typname,
         EXISTS (SELECT 1 FROM pg_constraint k
                 WHERE k.conrelid = t.oid AND k.contype = 'p' AND a.attnum = ANY (k.conkey)) AS is_pk,
         EXISTS (SELECT 1 FROM pg_constraint k
                 WHERE k.conrelid = t.oid AND k.contype = 'f' AND a.attnum = ANY (k.conkey)) AS is_fk
  FROM tbl t
  JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
  JOIN pg_type ty ON ty.oid = a.atttypid
  WHERE a.attname NOT IN ('created_at', 'created_by', 'updated_at', 'updated_by')
),
rel AS (
  SELECT DISTINCT
         pt.relname AS parent, ct.relname AS child,
         (SELECT string_agg(a.attname, ', ' ORDER BY a.attnum)
            FROM pg_attribute a WHERE a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey)) AS label,
         bool_and(a.attnotnull) OVER (PARTITION BY k.oid) AS mandatory
  FROM pg_constraint k
  JOIN pg_class ct ON ct.oid = k.conrelid
  JOIN pg_class pt ON pt.oid = k.confrelid
  JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = ANY (k.conkey)
  WHERE k.contype = 'f' AND k.conrelid IN (SELECT oid FROM tbl)
),
lines AS (
  SELECT 0 AS grp, '' AS tbl, 0 AS ord,
         '# Database structure (generated)' || chr(10) || chr(10) ||
         'Generated from the live database by `docker compose run --rm migrate erd`. ' ||
         'Do not edit by hand. Audit columns (created_*/updated_*) are omitted.' || chr(10) || chr(10) ||
         '```mermaid' || chr(10) || 'erDiagram' AS line
  UNION ALL
  SELECT 1, table_name, -1, '  ' || table_name || ' {' FROM tbl
  UNION ALL
  SELECT 1, table_name, attnum,
         '    ' || typname || ' ' || attname ||
         CASE WHEN is_pk AND is_fk THEN ' PK,FK' WHEN is_pk THEN ' PK' WHEN is_fk THEN ' FK' ELSE '' END
  FROM col
  UNION ALL
  SELECT 1, table_name, 100000, '  }' FROM tbl
  UNION ALL
  SELECT 2, parent || child || label, 0,
         '  ' || parent || CASE WHEN mandatory THEN ' ||--o{ ' ELSE ' |o--o{ ' END || child || ' : "' || label || '"'
  FROM rel
  UNION ALL
  SELECT 3, '', 0, '```'
)
SELECT line FROM lines ORDER BY grp, tbl, ord;
