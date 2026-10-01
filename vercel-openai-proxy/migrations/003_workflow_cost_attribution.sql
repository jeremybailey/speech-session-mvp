BEGIN;
-- NULL means old attribution cannot be reconstructed; never guess historical cost.
ALTER TABLE ai_condition_workflow_steps ADD COLUMN IF NOT EXISTS incurs_cost boolean;
CREATE INDEX IF NOT EXISTS ai_condition_workflow_step_job ON ai_condition_workflow_steps(job_id);
COMMIT;
