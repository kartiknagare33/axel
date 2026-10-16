import { Router } from 'express';
import { z } from 'zod';
import { pool, withSite } from './db';
import { getPublished } from './blueprints';
import { TABLES } from './entities';
import { AxelError, ah } from './errors';

// Public tracking (role: Public). Any unit can enable it with blueprint.publicTracking.
// Returns only the stage and dates: no names, prices or notes.
export const publicRouter = Router();
const KEY = /^[a-z_][a-z0-9_]*$/;

publicRouter.get('/track-units', ah(async (_req, res) => {
  const sites = (await pool.query('SELECT id, slug, name FROM sites ORDER BY name')).rows;
  const out: { slug: string; name: string; label: string }[] = [];
  for (const s of sites) {
    const pt = (await getPublished(s.id))?.compiled.blueprint;
    const t = pt?.publicTracking;
    if (t) out.push({ slug: s.slug, name: s.name, label: pt!.entities[t.entity]?.fields.find(f => f.key === t.field)?.label ?? 'Reference' });
  }
  res.json(out);
}));

publicRouter.get('/track/:slug', ah(async (req, res) => {
  const ref = z.string().trim().min(3).max(60).parse(req.query.ref);
  const none = new AxelError('NOT_FOUND', 404, 'Nothing found with that reference. Check it and try again.');
  const site = (await pool.query('SELECT id, name FROM sites WHERE slug = $1', [req.params.slug])).rows[0];
  if (!site) throw none;
  const bp = (await getPublished(site.id))?.compiled.blueprint;
  const pt = bp?.publicTracking;
  if (!bp || !pt || !KEY.test(pt.field)) throw none;
  const spec = TABLES[pt.entity];
  const wf = bp.workflows[pt.entity];
  if (!spec || !wf || !bp.entities[pt.entity]?.fields.some(f => f.key === pt.field)) throw none;
  const col = spec.core.includes(pt.field) ? pt.field : `data->>'${pt.field}'`;
  const out = await withSite({ siteId: site.id, userId: '', role: 'Public' }, async c => {
    const r = (await c.query(`SELECT id, state, created_at, updated_at FROM ${spec.table} WHERE lower(${col}) = lower($1) ORDER BY created_at DESC LIMIT 1`, [ref])).rows[0];
    if (!r) return null;
    const steps = (await c.query(
      `SELECT to_state, at FROM audit_events WHERE entity = $1 AND record_id = $2 AND kind = 'transition' ORDER BY at`, [pt.entity, r.id])).rows;
    return { state: r.state as string, received: r.created_at, updated: r.updated_at, steps };
  });
  if (!out) throw none;
  const states = wf.states.filter(st => !['rejected', 'scrapped'].includes(st) || st === out.state);
  res.json({ unit: site.name, ref, ...out, states });
}));
