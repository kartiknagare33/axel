ALTER TABLE law_runs ADD COLUMN content_hash text;
ALTER TABLE law_runs ADD COLUMN report jsonb NOT NULL DEFAULT '{}';
CREATE INDEX ix_law_runs_version ON law_runs (site_id, version_id, ran_at DESC);
