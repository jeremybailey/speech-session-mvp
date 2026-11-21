BEGIN;
CREATE TABLE IF NOT EXISTS ai_summary_workflows (
 id uuid PRIMARY KEY, owner text NOT NULL, request_hash text NOT NULL, kind text NOT NULL,
 target text NOT NULL, state text NOT NULL DEFAULT 'queued', revision integer NOT NULL DEFAULT 0,
 retry_at timestamptz, error_code text, created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days', received_at timestamptz,
 budget_id text NOT NULL REFERENCES ai_budgets(id), max_calls integer NOT NULL, calls integer NOT NULL DEFAULT 0,
 UNIQUE(owner,id)
);
CREATE TABLE IF NOT EXISTS ai_summary_payloads (
 workflow_id uuid PRIMARY KEY REFERENCES ai_summary_workflows(id), input jsonb NOT NULL,
 plan jsonb NOT NULL, result text
);
CREATE TABLE IF NOT EXISTS ai_summary_steps (
 workflow_id uuid NOT NULL REFERENCES ai_summary_workflows(id), key text NOT NULL, state text NOT NULL DEFAULT 'queued',
 job_id uuid REFERENCES ai_jobs(id), attempt integer NOT NULL DEFAULT 0, output jsonb, error_code text,
 PRIMARY KEY(workflow_id,key), UNIQUE(job_id)
);
CREATE TABLE IF NOT EXISTS ai_summary_children (
 workflow_id uuid NOT NULL REFERENCES ai_summary_workflows(id), job_id uuid PRIMARY KEY REFERENCES ai_jobs(id)
);
ALTER TABLE ai_summary_children ENABLE ROW LEVEL SECURITY;
CREATE TABLE IF NOT EXISTS ai_summary_outbox (
 workflow_id uuid PRIMARY KEY REFERENCES ai_summary_workflows(id), available_at timestamptz NOT NULL DEFAULT now(),
 lease_until timestamptz, fence bigint NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS ai_summary_owner_active ON ai_summary_workflows(owner,state);
CREATE INDEX IF NOT EXISTS ai_summary_outbox_due ON ai_summary_outbox(available_at);
ALTER TABLE ai_summary_workflows ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_summary_payloads ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_summary_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_summary_outbox ENABLE ROW LEVEL SECURITY;
COMMIT;
BEGIN;
CREATE TABLE IF NOT EXISTS ai_summary_uploads (
 owner text NOT NULL, id uuid NOT NULL, digest text NOT NULL, count integer NOT NULL CHECK(count BETWEEN 1 AND 12),
 expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days', PRIMARY KEY(owner,id)
);
CREATE TABLE IF NOT EXISTS ai_summary_upload_parts (
 owner text NOT NULL,id uuid NOT NULL, part integer NOT NULL, content text NOT NULL,
 PRIMARY KEY(owner,id,part), FOREIGN KEY(owner,id) REFERENCES ai_summary_uploads(owner,id) ON DELETE CASCADE
);
ALTER TABLE ai_summary_uploads ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_summary_upload_parts ENABLE ROW LEVEL SECURITY;
COMMIT;
BEGIN;
CREATE TABLE IF NOT EXISTS ai_summary_cancellations (
 owner text NOT NULL,id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(owner,id)
);
ALTER TABLE ai_summary_cancellations ENABLE ROW LEVEL SECURITY;
COMMIT;
-- Existing and resumed workflows retain the original concurrency policy.
ALTER TABLE ai_summary_workflows ADD COLUMN IF NOT EXISTS execution_policy text NOT NULL DEFAULT 'baseline-three-v1';

-- Bridge for queues pinned to older releases: they do not set this transaction
-- marker, so cannot admit, reject or publish work using a newer frozen policy.
CREATE OR REPLACE FUNCTION enforce_summary_execution_policy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.execution_policy IN ('baseline-three-v2','parallel-six-v2','parallel-six-low-merge-v2')
    AND NEW.state IN ('running','retry_scheduled','needs_attention','completed')
    AND current_setting('collectivecare.summary_execution_policy',true) IS DISTINCT FROM NEW.execution_policy THEN
  RAISE EXCEPTION 'summary_execution_policy_mismatch' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS summary_execution_policy_fence ON ai_summary_workflows;
CREATE TRIGGER summary_execution_policy_fence BEFORE UPDATE OF state,calls ON ai_summary_workflows
 FOR EACH ROW EXECUTE FUNCTION enforce_summary_execution_policy();

CREATE OR REPLACE FUNCTION enforce_summary_dispatch_policy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.lease_until IS NOT NULL
    AND EXISTS(SELECT 1 FROM ai_summary_workflows WHERE id=NEW.workflow_id AND execution_policy IN ('baseline-three-v2','parallel-six-v2','parallel-six-low-merge-v2'))
    AND current_setting('collectivecare.summary_dispatch',true) IS DISTINCT FROM 'v2' THEN
  RAISE EXCEPTION 'summary_dispatch_policy_mismatch' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS summary_dispatch_policy_fence ON ai_summary_outbox;
CREATE TRIGGER summary_dispatch_policy_fence BEFORE UPDATE OF lease_until,fence ON ai_summary_outbox
 FOR EACH ROW EXECUTE FUNCTION enforce_summary_dispatch_policy();
