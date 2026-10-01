BEGIN;
-- Existing Luna requests used low effort; Mini ignores this field.
ALTER TABLE ai_condition_workflows ADD COLUMN IF NOT EXISTS reasoning_effort text NOT NULL DEFAULT 'low'
  CHECK(reasoning_effort IN ('low','medium'));
ALTER TABLE ai_jobs ADD COLUMN IF NOT EXISTS reasoning_effort text NOT NULL DEFAULT 'low'
  CHECK(reasoning_effort IN ('low','medium'));
COMMIT;
