BEGIN;
CREATE TABLE IF NOT EXISTS ai_condition_uploads (
  owner text NOT NULL,
  digest text NOT NULL,
  part_count integer NOT NULL CHECK (part_count BETWEEN 1 AND 256),
  state text NOT NULL DEFAULT 'uploading' CHECK (state IN ('uploading','cancelled','completed','expired')),
  workflow_id uuid REFERENCES ai_condition_workflows(id),
  expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days',
  PRIMARY KEY(owner,digest)
);
CREATE TABLE IF NOT EXISTS ai_condition_upload_parts (
  owner text NOT NULL,
  digest text NOT NULL,
  part_index integer NOT NULL CHECK (part_index BETWEEN 0 AND 255),
  content text NOT NULL,
  PRIMARY KEY(owner,digest,part_index),
  FOREIGN KEY(owner,digest) REFERENCES ai_condition_uploads(owner,digest)
);
ALTER TABLE ai_condition_uploads ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_condition_upload_parts ENABLE ROW LEVEL SECURITY;
COMMIT;
