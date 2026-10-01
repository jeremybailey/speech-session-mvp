BEGIN;
CREATE TABLE IF NOT EXISTS ai_budgets (
  id text PRIMARY KEY,
  limit_nusd bigint NOT NULL CHECK (limit_nusd >= 0),
  used_nusd bigint NOT NULL DEFAULT 0 CHECK (used_nusd >= 0),
  reserved_nusd bigint NOT NULL DEFAULT 0 CHECK (reserved_nusd >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
-- One global evaluation allowance, not one dollar per user/run/device.
INSERT INTO ai_budgets(id,limit_nusd) VALUES ('evaluation-v1',1000000000) ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS ai_jobs (
  id uuid PRIMARY KEY,
  owner text NOT NULL,
  request_hash text NOT NULL,
  stage text NOT NULL,
  model text NOT NULL,
  pricing_version text NOT NULL,
  budget_id text NOT NULL REFERENCES ai_budgets(id),
  state text NOT NULL CHECK (state IN ('queued','running','completed','incomplete','uncertain','cancelled','expired')),
  reserve_nusd bigint NOT NULL,
  cost_nusd bigint,
  input_tokens bigint,
  output_tokens bigint,
  cached_tokens bigint,
  provider_id text,
  retry_count integer NOT NULL DEFAULT 0,
  record_count integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  UNIQUE(owner, request_hash)
);
-- Clinical payloads are isolated from accounting. Purge both input and output.
CREATE TABLE IF NOT EXISTS ai_payloads (
  job_id uuid PRIMARY KEY REFERENCES ai_jobs(id),
  payload jsonb,
  result jsonb,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '7 days'
);
CREATE INDEX IF NOT EXISTS ai_jobs_owner_created ON ai_jobs(owner,created_at);
CREATE INDEX IF NOT EXISTS ai_jobs_queue ON ai_jobs(created_at) WHERE state='queued';
CREATE INDEX IF NOT EXISTS ai_payloads_expiry ON ai_payloads(expires_at);
-- Application uses a private server credential; never expose database credentials to clients.
ALTER TABLE ai_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_payloads ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_budgets ENABLE ROW LEVEL SECURITY;
COMMIT;
