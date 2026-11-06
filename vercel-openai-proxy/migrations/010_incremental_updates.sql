-- Additive; clinical payloads retain the existing seven-day expiry.
CREATE TABLE IF NOT EXISTS ai_record_updates (
 id uuid PRIMARY KEY, owner text NOT NULL, contract text NOT NULL,
 state text NOT NULL DEFAULT 'queued', stopped boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days',
 manifest jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE TABLE IF NOT EXISTS ai_record_units (
 id uuid PRIMARY KEY, update_id uuid NOT NULL REFERENCES ai_record_updates(id) ON DELETE CASCADE,
 unit_key text NOT NULL, source_hash text NOT NULL, source jsonb NOT NULL,
 state text NOT NULL DEFAULT 'queued', phase text NOT NULL DEFAULT 'extract',
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 3),
 uncertain_replaced boolean NOT NULL DEFAULT false, job_id uuid REFERENCES ai_jobs(id),
 candidate jsonb, result jsonb, diagnostic text,
 UNIQUE(update_id,unit_key)
);
CREATE INDEX IF NOT EXISTS ai_record_units_job ON ai_record_units(job_id);
ALTER TABLE ai_record_updates ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_record_units ENABLE ROW LEVEL SECURITY;

ALTER TABLE ai_record_units ADD COLUMN IF NOT EXISTS validator_version text NOT NULL DEFAULT 'incremental-validator-v1';
ALTER TABLE ai_record_updates ADD COLUMN IF NOT EXISTS last_woken_at timestamptz;
ALTER TABLE ai_record_units ADD COLUMN IF NOT EXISTS next_attempt_at timestamptz NOT NULL DEFAULT now();
