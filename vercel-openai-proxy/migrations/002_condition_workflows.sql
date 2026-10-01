BEGIN;
CREATE TABLE IF NOT EXISTS ai_condition_workflows (
  id uuid PRIMARY KEY,
  owner text NOT NULL,
  request_hash text NOT NULL,
  budget_id text NOT NULL REFERENCES ai_budgets(id),
  state text NOT NULL CHECK(state IN ('queued','running','completed','incomplete','uncertain','cancelled','expired','invalid','budget_exhausted')),
  revision integer NOT NULL DEFAULT 0,
  current_step uuid REFERENCES ai_jobs(id),
  record_count integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  UNIQUE(owner,request_hash)
);
CREATE TABLE IF NOT EXISTS ai_condition_workflow_payloads (
  workflow_id uuid PRIMARY KEY REFERENCES ai_condition_workflows(id),
  plan jsonb NOT NULL,
  checkpoint jsonb NOT NULL,
  expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days'
);
CREATE TABLE IF NOT EXISTS ai_condition_workflow_steps (
  workflow_id uuid NOT NULL REFERENCES ai_condition_workflows(id),
  revision integer NOT NULL,
  job_id uuid NOT NULL REFERENCES ai_jobs(id),
  PRIMARY KEY(workflow_id,revision)
);
CREATE INDEX IF NOT EXISTS ai_condition_workflow_expiry ON ai_condition_workflow_payloads(expires_at);
ALTER TABLE ai_condition_workflows ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_condition_workflow_payloads ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_condition_workflow_steps ENABLE ROW LEVEL SECURITY;
COMMIT;
