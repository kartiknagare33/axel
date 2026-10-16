-- one transition per idempotency key per site (double-click / retry safety)
CREATE UNIQUE INDEX ux_audit_transition_idem ON audit_events (site_id, idempotency_key)
  WHERE kind = 'transition' AND idempotency_key IS NOT NULL;
-- fast lookup of the active reservation for a request
CREATE INDEX ix_mov_ref ON stock_movements (site_id, ref_id) WHERE kind = 'reserve' AND consumed_by IS NULL;
