CREATE TABLE IF NOT EXISTS ai_story_operations (
 owner text NOT NULL, id uuid NOT NULL, request_hash text NOT NULL,
 request jsonb, job_id uuid REFERENCES ai_jobs(id),
 check_job_id uuid REFERENCES ai_jobs(id), cancelled boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(owner,id)
);
ALTER TABLE ai_story_operations ENABLE ROW LEVEL SECURITY;

ALTER TABLE ai_story_operations ALTER COLUMN job_id DROP NOT NULL;

ALTER TABLE ai_story_operations ADD COLUMN IF NOT EXISTS attempts smallint NOT NULL DEFAULT 1 CHECK(attempts BETWEEN 1 AND 3);
ALTER TABLE ai_story_operations ADD COLUMN IF NOT EXISTS next_attempt_at timestamptz;
