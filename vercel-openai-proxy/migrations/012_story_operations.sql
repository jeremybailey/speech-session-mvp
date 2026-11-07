CREATE TABLE IF NOT EXISTS ai_story_operations (
 owner text NOT NULL, id uuid NOT NULL, request_hash text NOT NULL,
 request jsonb, job_id uuid NOT NULL REFERENCES ai_jobs(id),
 check_job_id uuid REFERENCES ai_jobs(id), cancelled boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(owner,id)
);
ALTER TABLE ai_story_operations ENABLE ROW LEVEL SECURITY;
