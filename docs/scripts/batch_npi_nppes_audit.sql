-- Usage:
--   psql -P pager=off -v batch_id=560 medicaid_claims_checker_dev -f ../docs/scripts/batch_npi_nppes_audit.sql

WITH target AS (
  SELECT :batch_id::bigint AS id
),
batch_meta AS (
  SELECT b.id, b.batch_id, b.source, b.status, b.inserted_at
  FROM batches b
  JOIN target t ON b.id = t.id
),
extracted AS (
  SELECT
    e.filename,
    e.status AS file_status,
    COALESCE(
      e.raw_claim_json->'claim'->'rendering_provider'->>'npi',
      e.json_output->'claim'->'rendering_provider'->>'npi',
      ''
    ) AS rendering_npi,
    COALESCE(
      e.raw_claim_json->'billing_provider'->>'npi',
      e.json_output->'billing_provider'->>'npi',
      ''
    ) AS billing_npi,
    COALESCE(
      (
        SELECT MIN(to_date(sd, 'YYYYMMDD'))
        FROM jsonb_array_elements(
          COALESCE(
            e.raw_claim_json->'claim'->'service_lines',
            e.json_output->'claim'->'service_lines',
            '[]'::jsonb
          )
        ) sl
        CROSS JOIN LATERAL (VALUES (sl->>'service_date'), (sl->>'date_of_service')) d(sd)
        WHERE d.sd ~ '^[0-9]{8}$'
      ),
      '1900-01-01'::date
    ) AS service_date
  FROM edi_files e
  JOIN target t ON e.batch_id = t.id
)
SELECT
  m.id AS batch_db_id,
  m.batch_id,
  m.source,
  m.status AS batch_status,
  m.inserted_at,
  ex.filename,
  ex.file_status,
  ex.service_date,
  ex.rendering_npi,
  CASE WHEN ex.rendering_npi = '' THEN NULL ELSE (np1.npi IS NOT NULL) END AS rendering_exists,
  CASE
    WHEN ex.rendering_npi = '' THEN NULL
    ELSE (np1.deactivation_date IS NULL OR np1.deactivation_date > ex.service_date)
  END AS rendering_active,
  ex.billing_npi,
  CASE WHEN ex.billing_npi = '' THEN NULL ELSE (np2.npi IS NOT NULL) END AS billing_exists,
  CASE
    WHEN ex.billing_npi = '' THEN NULL
    ELSE (np2.deactivation_date IS NULL OR np2.deactivation_date > ex.service_date)
  END AS billing_active
FROM batch_meta m
JOIN extracted ex ON true
LEFT JOIN nppes_providers np1 ON np1.npi = ex.rendering_npi
LEFT JOIN nppes_providers np2 ON np2.npi = ex.billing_npi
ORDER BY ex.filename;
