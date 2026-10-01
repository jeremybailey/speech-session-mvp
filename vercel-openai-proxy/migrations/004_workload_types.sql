BEGIN;
ALTER TABLE ai_jobs ADD COLUMN IF NOT EXISTS workload_type text NOT NULL DEFAULT 'unknown'
  CHECK(workload_type IN ('initial','incremental','retry','development','unknown'));
ALTER TABLE ai_condition_workflows ADD COLUMN IF NOT EXISTS workload_type text NOT NULL DEFAULT 'unknown'
  CHECK(workload_type IN ('initial','incremental','retry','development','unknown'));
COMMIT;
