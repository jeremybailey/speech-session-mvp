-- Independent of migration 008. No health content or access tokens are stored.
CREATE TABLE IF NOT EXISTS pilot_agreement_acceptances (
  id uuid PRIMARY KEY,
  owner text NOT NULL,
  version text NOT NULL,
  sha256 text NOT NULL CHECK (length(sha256) = 64),
  agreement_text text NOT NULL,
  action text NOT NULL,
  accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  app_version text NOT NULL,
  app_build text NOT NULL,
  UNIQUE(owner, version, sha256)
);
-- Append-only for ordinary SQL updates/deletes; privileged schema administrators
-- can still alter the database. This is an audit trail, not tamper-proof storage.
CREATE OR REPLACE FUNCTION protect_pilot_acceptance() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'pilot agreement receipts are append-only';
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS pilot_acceptance_immutable ON pilot_agreement_acceptances;
CREATE TRIGGER pilot_acceptance_immutable BEFORE UPDATE OR DELETE ON pilot_agreement_acceptances
FOR EACH ROW EXECUTE FUNCTION protect_pilot_acceptance();
