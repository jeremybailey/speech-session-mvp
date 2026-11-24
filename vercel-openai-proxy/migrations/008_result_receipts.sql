BEGIN;
-- Receipt markers contain no clinical output. Retain dedupe and cost identities.
ALTER TABLE ai_jobs ADD COLUMN IF NOT EXISTS result_received_at timestamptz;
ALTER TABLE ai_condition_workflows ADD COLUMN IF NOT EXISTS result_received_at timestamptz;
COMMIT;
