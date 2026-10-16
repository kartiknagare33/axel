import { Router } from 'express';
import { z } from 'zod';
import { compile, type Blueprint, type Compiled, type Role } from '@axel/compiler';
import { pool, withSite, UUID, type Tx } from './db';
import { ah, notFound } from './errors';
import { runTransition } from './workflow';
import { impactReport } from './impact';

// Mounted at /api/sites/:siteId (Admin only).
export const replayRouter = Router({ mergeParams: true });

type Outcome = 'allowed' | 'blocked_by_guard' | 'blocked_by_role' | 'step_missing' | 'insufficient_stock' | 'no_reservation' | 'refused';
const TEXT: Record<Outcome, string> = {
  allowed: 'allowed', blocked_by_guard: 'blocked by a rule', blocked_by_role: 'blocked because the role may not do it',
  step_missing: 'impossible (the step no longer exists)', insufficient_stock: 'blocked by stock', no_reservation: 'blocked (nothing reserved)', refused: 'refused',
};
const classify = (e: any): Outcome => {
  switch (e?.code) {
    case 'GUARD_FAILED': return 'blocked_by_guard';
    case 'TRANSITION_NOT_ALLOWED': return e.status === 403 ? 'blocked_by_role' : 'step_missing';
    case 'INSUFFICIENT_STOCK': return 'insufficient_stock';
    case 'NO_RESERVATION': return 'no_reservation';
    default: return 'refused';
  }
};
const pin = (req: any, config: any): Blueprint => ({ ...config, siteId: req.site.siteId, slug: req.site.slug });

interface Ev { from_state: string; to_state: string; actor_role: string; after: any }

/** Re-creates a request as it was before its first recorded step, then applies its real history step by step. */
async function replayOne(c: Tx, siteId: string, userId: string, versionId: string, compiled: Compiled, name: string, rec: any, events: Ev[], tag: string) {
  const outs: { step: number; transition: string; outcome: Outcome; detail?: string }[] = [];
  const id = (await c.query(
    `INSERT INTO requests (site_id, item_id, qty, state, requested_by, data) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
    [siteId, rec.item_id, rec.qty, events[0].from_state, rec.requested_by, rec.data])).rows[0].id;
  for (const [k, ev] of events.entries()) {
    const role = (['Member', 'Manager', 'Admin'].includes(ev.actor_role) ? ev.actor_role : 'Admin') as Role;
    const transition = `${ev.from_state} > ${ev.to_state}`;
    await c.query('SAVEPOINT rp');
    try {
      await runTransition(c, { siteId, userId, role, versionId }, compiled, name, 'request', id, {
        to: ev.to_state, idempotencyKey: `replay-${tag}-${k}`,
        payload: ev.after?.assigned_to ? { assigned_to: ev.after.assigned_to } : undefined,
      });
      await c.query('RELEASE SAVEPOINT rp');
      outs.push({ step: k + 1, transition, outcome: 'allowed' });
    } catch (e: any) {
      await c.query('ROLLBACK TO SAVEPOINT rp');
      outs.push({ step: k + 1, transition, outcome: classify(e), detail: e?.message });
      break;
    }
  }
  const final = (await c.query('SELECT state FROM requests WHERE id = $1', [id])).rows[0]?.state as string;
  return { outs, final };
}

// POST /api/sites/:siteId/versions/:v/replay { sample? }
replayRouter.post('/versions/:v/replay', ah(async (req, res) => {
  if (!UUID.test(req.params.v)) throw notFound();
  const b = z.object({ sample: z.number().int().min(5).max(300).default(50) }).parse(req.body ?? {});
  const s = req.site!;
  const v = await withSite(s.ctx, async c => (await c.query('SELECT id, config FROM site_versions WHERE id = $1', [req.params.v])).rows[0]);
  if (!v) throw notFound();
  const draftBp = pin(req, v.config);
  const draft = compile(draftBp);
  const live = s.compiled;

  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SELECT set_config('app.site_id',$1,true), set_config('app.user_id',$2,true), set_config('app.role','Admin',true)`, [s.siteId, s.ctx.userId]);
    const impact = await impactReport(c, live.blueprint, draftBp);
    if (!live.blueprint.workflows.request || !live.blueprint.entities.request) {
      return res.json({ sampled: 0, identical: 0, divergent: [], summary: ['This site has no request history to replay.'], impact });
    }
    const recs = (await c.query(
      `SELECT r.* FROM requests r
        WHERE EXISTS (SELECT 1 FROM audit_events e WHERE e.entity = 'request' AND e.record_id = r.id AND e.kind = 'transition')
        ORDER BY r.created_at DESC LIMIT $1`, [b.sample])).rows;
    const evs = (await c.query(
      `SELECT record_id, from_state, to_state, actor_role, after FROM audit_events
        WHERE entity = 'request' AND kind = 'transition' AND record_id = ANY($1) ORDER BY at, id`, [recs.map(r => r.id)])).rows;
    const byRec = new Map<string, Ev[]>();
    for (const e of evs) { if (!byRec.has(e.record_id)) byRec.set(e.record_id, []); byRec.get(e.record_id)!.push(e); }

    const divergent: any[] = [];
    let identical = 0;
    for (const [n, rec] of recs.entries()) {
      const events = byRec.get(rec.id) ?? [];
      if (!events.length) { identical++; continue; }
      await c.query('SAVEPOINT rec');
      const a = await replayOne(c, s.siteId, s.ctx.userId, s.versionId, live, s.name, rec, events, `L${n}`);
      await c.query('ROLLBACK TO SAVEPOINT rec');
      const d = await replayOne(c, s.siteId, s.ctx.userId, v.id, draft, s.name, rec, events, `D${n}`);
      await c.query('ROLLBACK TO SAVEPOINT rec');
      const firstDiff = d.outs.findIndex((o, i) => o.outcome !== a.outs[i]?.outcome);
      if (firstDiff === -1 && d.outs.length === a.outs.length && d.final === a.final) { identical++; continue; }
      const i = firstDiff === -1 ? Math.min(a.outs.length, d.outs.length) : firstDiff;
      const at = d.outs[i] ?? a.outs[i];
      divergent.push({
        recordId: rec.id, label: rec.data?.serial_no ?? rec.data?.site_location ?? String(rec.id).slice(0, 8),
        step: at?.step, transition: at?.transition, live: a.outs[i]?.outcome ?? 'n/a', draft: d.outs[i]?.outcome ?? 'n/a',
        detail: d.outs[i]?.detail, liveFinal: a.final, draftFinal: d.final,
      });
    }

    const groups = new Map<string, number>();
    for (const d of divergent) { const k = `${d.transition}|${d.draft}|${d.live}`; groups.set(k, (groups.get(k) ?? 0) + 1); }
    const summary = [...groups].map(([k, n]) => {
      const [tr, dr, lv] = k.split('|');
      return `${n} of ${recs.length}: ${tr} would be ${TEXT[dr as Outcome] ?? dr} (today: ${TEXT[lv as Outcome] ?? lv}).`;
    });
    if (!divergent.length) summary.push(`All ${recs.length} replayed requests behave exactly as they do today.`);
    res.json({ sampled: recs.length, identical, divergent, summary, impact });
  } finally {
    await c.query('ROLLBACK').catch(() => {});
    c.release();
  }
}));

// GET /api/sites/:siteId/versions/:v/impact - used before a rollback
replayRouter.get('/versions/:v/impact', ah(async (req, res) => {
  if (!UUID.test(req.params.v)) throw notFound();
  const s = req.site!;
  const impact = await withSite(s.ctx, async c => {
    const v = (await c.query('SELECT config FROM site_versions WHERE id = $1', [req.params.v])).rows[0];
    if (!v) throw notFound();
    return impactReport(c, s.compiled.blueprint, pin(req, v.config));
  });
  res.json({ impact });
}));
