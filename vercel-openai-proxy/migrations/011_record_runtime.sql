-- Operational deployment fence only; no clinical records or payloads changed.
CREATE TABLE IF NOT EXISTS ai_record_runtime (
 id text PRIMARY KEY CHECK (id = 'record-updates'),
 deployment_id text NOT NULL,
 activated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE ai_record_runtime ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_record_units ADD COLUMN IF NOT EXISTS worker_deployment_id text;
