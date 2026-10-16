-- Helpers read the transaction-local context. NULLIF guards the '' a pooled
-- connection reports after a set_config(...,true) transaction ends.
CREATE FUNCTION app_site() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT NULLIF(current_setting('app.site_id', true), '')::uuid $$;
CREATE FUNCTION app_user() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT NULLIF(current_setting('app.user_id', true), '')::uuid $$;

-- ---------- hub tables (not site-scoped) ----------
CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email citext UNIQUE NOT NULL,
  password_hash text NOT NULL,
  name text NOT NULL,
  is_hub_admin boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE sites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text UNIQUE NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  name text NOT NULL,
  published_version_id uuid,
  created_by uuid REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now());

-- ---------- site-scoped platform tables ----------
CREATE TABLE memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  user_id uuid NOT NULL REFERENCES users(id),
  role text NOT NULL CHECK (role IN ('Public','Member','Manager','Admin')),
  UNIQUE (site_id, user_id));

CREATE TABLE site_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  config jsonb NOT NULL,
  content_hash text NOT NULL,
  parent_id uuid REFERENCES site_versions(id),
  status text NOT NULL CHECK (status IN ('draft','gated','published','archived')),
  author_id uuid REFERENCES users(id),
  reason text,
  updated_rev integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, content_hash),
  UNIQUE (site_id, id));
ALTER TABLE sites ADD CONSTRAINT fk_sites_published
  FOREIGN KEY (published_version_id) REFERENCES site_versions(id);

CREATE TABLE site_deployments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  version_id uuid NOT NULL,
  audience jsonb NOT NULL DEFAULT '{"roles":"all"}',
  proof jsonb NOT NULL,
  plans jsonb,
  deployed_by uuid REFERENCES users(id),
  deployed_at timestamptz NOT NULL DEFAULT now(),
  rollback_of uuid REFERENCES site_deployments(id),
  FOREIGN KEY (site_id, version_id) REFERENCES site_versions (site_id, id));

CREATE TABLE recordings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  version_id uuid REFERENCES site_versions(id),
  steps jsonb NOT NULL, created_by uuid, created_at timestamptz DEFAULT now());

CREATE TABLE law_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  version_id uuid NOT NULL REFERENCES site_versions(id),
  seed bigint NOT NULL, steps integer NOT NULL, passed boolean NOT NULL,
  failures jsonb NOT NULL DEFAULT '[]', duration_ms integer, ran_at timestamptz DEFAULT now());

CREATE TABLE audit_events (
  id bigserial PRIMARY KEY,
  site_id uuid NOT NULL REFERENCES sites(id),
  entity text NOT NULL, record_id uuid NOT NULL,
  kind text NOT NULL,
  transition_id text, from_state text, to_state text,
  actor_id uuid, actor_role text,
  before jsonb, after jsonb,
  version_id uuid REFERENCES site_versions(id),
  idempotency_key text,
  at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ix_audit_record ON audit_events (site_id, entity, record_id, at);

-- ---------- business tables ----------
CREATE TABLE items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  name text NOT NULL,
  on_hand numeric NOT NULL DEFAULT 0 CHECK (on_hand >= 0),
  reserved numeric NOT NULL DEFAULT 0 CHECK (reserved >= 0 AND reserved <= on_hand),
  data jsonb NOT NULL DEFAULT '{}',
  row_version integer NOT NULL DEFAULT 1,
  created_under_version uuid, created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id));
CREATE UNIQUE INDEX ux_items_sku ON items (site_id, (data->>'sku'));

CREATE TABLE stock_movements (
  id bigserial PRIMARY KEY,
  site_id uuid NOT NULL REFERENCES sites(id),
  item_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('receive','adjust','reserve','commit','release','consume','return')),
  qty numeric NOT NULL CHECK (qty <> 0 AND (qty > 0 OR kind = 'adjust')),
  ref_type text, ref_id uuid, reason text,
  idempotency_key text NOT NULL,
  expires_at timestamptz,
  consumed_by bigint REFERENCES stock_movements(id),
  actor_id uuid, at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (site_id, item_id) REFERENCES items (site_id, id),
  UNIQUE (site_id, idempotency_key));
CREATE INDEX ix_mov_item ON stock_movements (site_id, item_id, at);
CREATE INDEX ix_mov_expiry ON stock_movements (expires_at) WHERE kind = 'reserve' AND consumed_by IS NULL;

CREATE TABLE requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  item_id uuid NOT NULL,
  qty numeric NOT NULL CHECK (qty > 0),
  state text NOT NULL,
  requested_by uuid REFERENCES users(id),
  data jsonb NOT NULL DEFAULT '{}',
  row_version integer NOT NULL DEFAULT 1,
  created_under_version uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id),
  FOREIGN KEY (site_id, item_id) REFERENCES items (site_id, id));
CREATE INDEX ix_req_state ON requests (site_id, state);
CREATE INDEX ix_req_by ON requests (site_id, requested_by);

CREATE TABLE approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  request_id uuid NOT NULL,
  decision text NOT NULL CHECK (decision IN ('approved','rejected')),
  decided_by uuid, note text,
  data jsonb NOT NULL DEFAULT '{}',
  row_version integer NOT NULL DEFAULT 1, created_under_version uuid,
  at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id),
  FOREIGN KEY (site_id, request_id) REFERENCES requests (site_id, id));

CREATE TABLE assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  request_id uuid NOT NULL, item_id uuid NOT NULL,
  qty numeric NOT NULL CHECK (qty > 0),
  assigned_to uuid, state text NOT NULL DEFAULT 'assigned',
  data jsonb NOT NULL DEFAULT '{}',
  row_version integer NOT NULL DEFAULT 1, created_under_version uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id),
  FOREIGN KEY (site_id, request_id) REFERENCES requests (site_id, id),
  FOREIGN KEY (site_id, item_id) REFERENCES items (site_id, id));
CREATE INDEX ix_asg_state ON assignments (site_id, state);

CREATE TABLE consumptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  assignment_id uuid NOT NULL,
  qty numeric NOT NULL CHECK (qty > 0),
  note text,
  data jsonb NOT NULL DEFAULT '{}',
  idempotency_key text NOT NULL,
  recorded_by uuid, recorded_at timestamptz NOT NULL DEFAULT now(), synced_at timestamptz,
  row_version integer NOT NULL DEFAULT 1, created_under_version uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id), UNIQUE (site_id, idempotency_key),
  FOREIGN KEY (site_id, assignment_id) REFERENCES assignments (site_id, id));

CREATE TABLE returns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  ref_type text NOT NULL CHECK (ref_type IN ('assignment','request')),
  ref_id uuid NOT NULL, item_id uuid NOT NULL,
  qty numeric NOT NULL CHECK (qty > 0), condition text,
  data jsonb NOT NULL DEFAULT '{}', returned_by uuid,
  at timestamptz NOT NULL DEFAULT now(),
  row_version integer NOT NULL DEFAULT 1, created_under_version uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id),
  FOREIGN KEY (site_id, item_id) REFERENCES items (site_id, id));

CREATE TABLE repairs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  request_id uuid NOT NULL,
  serial_no text, fault text, diagnosis text,
  parts_used jsonb NOT NULL DEFAULT '[]',
  state text NOT NULL DEFAULT 'open',
  technician_id uuid,
  data jsonb NOT NULL DEFAULT '{}',
  row_version integer NOT NULL DEFAULT 1, created_under_version uuid,
  opened_at timestamptz NOT NULL DEFAULT now(), closed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id),
  FOREIGN KEY (site_id, request_id) REFERENCES requests (site_id, id));

CREATE INDEX gin_items_data ON items USING gin (data);
CREATE INDEX gin_requests_data ON requests USING gin (data);
CREATE INDEX gin_approvals_data ON approvals USING gin (data);
CREATE INDEX gin_assignments_data ON assignments USING gin (data);
CREATE INDEX gin_consumptions_data ON consumptions USING gin (data);
CREATE INDEX gin_returns_data ON returns USING gin (data);
CREATE INDEX gin_repairs_data ON repairs USING gin (data);

CREATE VIEW v_ledger_balance WITH (security_invoker = true) AS
SELECT site_id, item_id,
  SUM(CASE kind WHEN 'receive' THEN qty WHEN 'adjust' THEN qty WHEN 'return' THEN qty
                WHEN 'commit' THEN -qty WHEN 'consume' THEN -qty ELSE 0 END) AS on_hand,
  SUM(CASE kind WHEN 'reserve' THEN qty WHEN 'commit' THEN -qty WHEN 'release' THEN -qty ELSE 0 END) AS reserved
FROM stock_movements GROUP BY site_id, item_id;

-- ---------- FORCE RLS on every site-scoped table ----------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['site_versions','site_deployments','recordings','law_runs','audit_events',
    'items','stock_movements','requests','approvals','assignments','consumptions','returns','repairs'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY site_iso ON %I USING (site_id = app_site()) WITH CHECK (site_id = app_site())', t);
  END LOOP;
END $$;

ALTER TABLE memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE memberships FORCE ROW LEVEL SECURITY;
CREATE POLICY m_read   ON memberships FOR SELECT USING (site_id = app_site() OR user_id = app_user());
CREATE POLICY m_insert ON memberships FOR INSERT WITH CHECK (site_id = app_site());
CREATE POLICY m_update ON memberships FOR UPDATE USING (site_id = app_site()) WITH CHECK (site_id = app_site());
CREATE POLICY m_delete ON memberships FOR DELETE USING (site_id = app_site());

CREATE FUNCTION memberships_role_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    IF coalesce(current_setting('app.role', true), '') <> 'Admin' THEN
      RAISE EXCEPTION 'ROLE_CHANGE_ADMIN_ONLY' USING ERRCODE = '42501';
    END IF;
    IF NEW.user_id = app_user() THEN
      RAISE EXCEPTION 'SELF_ROLE_CHANGE' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_memberships_role BEFORE UPDATE ON memberships
  FOR EACH ROW EXECUTE FUNCTION memberships_role_guard();
