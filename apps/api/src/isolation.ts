import { Router } from 'express';
import { pool, withSite } from './db';
import { requireAuth, requireHubAdmin, memberships } from './auth';
import { ah } from './errors';

// Mounted at /api/hub. Shows and proves the database-level isolation.
export const isolationRouter = Router();
const SCOPED = ['memberships', 'site_versions', 'site_deployments', 'recordings', 'law_runs', 'audit_events',
  'items', 'stock_movements', 'requests', 'approvals', 'assignments', 'consumptions', 'returns', 'repairs'];

isolationRouter.get('/isolation-ledger', requireAuth, requireHubAdmin, ah(async (req, res) => {
  const tables = (await pool.query(
    `SELECT c.relname AS "table", c.relrowsecurity AS rls, c.relforcerowsecurity AS forced,
            pg_get_userbyid(c.relowner) AS owner,
            (SELECT count(*)::int FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = c.relname) AS policies,
            (SELECT count(*)::int FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'f' AND array_length(k.conkey, 1) = 2) AS composite_fks
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname = ANY($1) ORDER BY c.relname`, [SCOPED])).rows;
  const role = (await pool.query(`SELECT current_user AS name, rolbypassrls AS bypass, rolsuper AS superuser FROM pg_roles WHERE rolname = current_user`)).rows[0];
  const owns = Number((await pool.query(
    `SELECT count(*) AS n FROM pg_class WHERE relowner = (SELECT oid FROM pg_roles WHERE rolname = current_user) AND relkind IN ('r', 'v')`)).rows[0].n);
  const uniques = (await pool.query(
    `SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' AND indexdef ILIKE 'CREATE UNIQUE%' AND indexdef ILIKE '%site_id%' ORDER BY tablename`)).rows;
  const sites = await memberships(req.user!.id);
  const gates = await Promise.all(sites.map(async (m: any) => ({
    id: m.site_id, name: m.name,
    lastGate: await withSite({ siteId: m.site_id, userId: req.user!.id, role: '' }, async c =>
      (await c.query('SELECT passed, steps, seed, ran_at FROM law_runs ORDER BY ran_at DESC LIMIT 1')).rows[0] ?? null),
  })));
  res.json({ role: { ...role, ownsTables: owns }, tables, uniques, sites: gates });
}));

isolationRouter.post('/isolation-ledger/check', requireAuth, requireHubAdmin, ah(async (req, res) => {
  const sites = (await memberships(req.user!.id)).map((m: any) => ({ id: m.site_id as string, name: m.name as string }));
  const checks: { name: string; passed: boolean; detail: string }[] = [];
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    const none = Number((await c.query('SELECT (SELECT count(*) FROM items) + (SELECT count(*) FROM requests) + (SELECT count(*) FROM audit_events) AS n')).rows[0].n);
    checks.push({ name: 'With no unit selected, nothing is visible', passed: none === 0, detail: `${none} rows visible without a unit context.` });
    for (const a of sites) for (const b of sites) {
      if (a.id === b.id) continue;
      await c.query(`SELECT set_config('app.site_id', $1, true)`, [a.id]);
      const leak = Number((await c.query(
        `SELECT (SELECT count(*) FROM items WHERE site_id = $1) + (SELECT count(*) FROM requests WHERE site_id = $1) + (SELECT count(*) FROM stock_movements WHERE site_id = $1) AS n`, [b.id])).rows[0].n);
      checks.push({ name: `${a.name} cannot read ${b.name}`, passed: leak === 0, detail: leak ? `${leak} rows leaked` : 'asked for every item, request and stock movement of the other unit: 0 rows' });
    }
    if (sites.length >= 2) {
      const [a, b] = sites;
      await c.query(`SELECT set_config('app.site_id', $1, true)`, [b.id]);
      const otherItem = (await c.query('SELECT id FROM items LIMIT 1')).rows[0]?.id;
      await c.query(`SELECT set_config('app.site_id', $1, true)`, [a.id]);
      await c.query('SAVEPOINT w');
      let refused = false;
      try { await c.query(`INSERT INTO items (site_id, name) VALUES ($1, 'smuggled')`, [b.id]); } catch { refused = true; }
      await c.query('ROLLBACK TO SAVEPOINT w');
      checks.push({ name: `${a.name} cannot write into ${b.name}`, passed: refused, detail: refused ? 'refused by row-level security' : 'the insert was accepted' });
      if (otherItem) {
        const myItem = (await c.query('SELECT id FROM items LIMIT 1')).rows[0]?.id;
        await c.query('SAVEPOINT f');
        let blocked = false;
        try { await c.query(`INSERT INTO requests (site_id, item_id, qty, state) VALUES ($1, $2, 1, 'draft')`, [a.id, otherItem]); } catch { blocked = true; }
        await c.query('ROLLBACK TO SAVEPOINT f');
        checks.push({ name: `${a.name} cannot point at ${b.name}'s items`, passed: blocked, detail: blocked ? 'refused by the composite foreign key (site_id, id)' : 'a cross-unit reference was accepted' });
        void myItem;
      }
    }
  } finally {
    await c.query('ROLLBACK').catch(() => {});
    c.release();
  }
  if (sites.length) {
    const counts = await Promise.all(Array.from({ length: 30 }, (_, i) => sites[i % sites.length]).map(s =>
      withSite({ siteId: s.id, userId: '', role: '' }, async x => Number((await x.query('SELECT count(*) AS n FROM items WHERE site_id <> $1', [s.id])).rows[0].n))));
    checks.push({ name: '30 parallel requests on pooled connections never mix units', passed: counts.every(n => n === 0), detail: `${counts.filter(n => n === 0).length} of 30 saw only their own unit` });
  }
  res.json({ passed: checks.every(x => x.passed), checks, ranAt: new Date().toISOString() });
}));
