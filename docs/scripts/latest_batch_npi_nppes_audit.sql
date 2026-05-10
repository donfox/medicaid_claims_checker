WITH latest AS (
  SELECT id, batch_id, source, status, inserted_at
  FROM batches
  WHERE EXISTS (
    SELECT 1
    FROM edi_files e
    WHERE e.batch_id = batches.id
      AND (
        (e.raw_claim_json IS NOT NULL AND e.raw_claim_json ? 'claim')
        OR (e.json_output IS NOT NULL AND e.json_output ? 'claim')
      )
  )
  ORDER BY id DESC
  LIMIT 1
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
  JOIN latest l ON e.batch_id = l.id
)
SELECT
  l.id AS batch_db_id,
  l.batch_id,
  l.source,
  l.status AS batch_status,
  l.inserted_at,
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
FROM latest l
JOIN extracted ex ON true
LEFT JOIN nppes_providers np1 ON np1.npi = ex.rendering_npi
LEFT JOIN nppes_providers np2 ON np2.npi = ex.billing_npi
ORDER BY ex.filename;
