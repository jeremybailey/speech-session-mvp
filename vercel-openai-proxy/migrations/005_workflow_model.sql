BEGIN;
-- Pin in-flight workflows to their original model across deploys and relaunches.
ALTER TABLE ai_condition_workflows ADD COLUMN IF NOT EXISTS model text NOT NULL DEFAULT 'gpt-4o-mini'
  CHECK(model IN ('gpt-4o-mini','gpt-6-luna'));
COMMIT;
