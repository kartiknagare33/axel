import { Router } from 'express';
import { z } from 'zod';
import { withSite, UUID } from './db';
import { TABLES, resolveEntity, toRecord } from './entities';
import { AxelError, ah, notFound } from './errors';
import { runTransition, describeTransitions } from './workflow';
import { bus } from './blueprints';

export const workflow = Router({ mergeParams: true });

const entityOr404 = (req: any) => {
  const e = resolveEntity(req.site.compiled.blueprint, req.params.entity);
  if (!e || !UUID.test(req.params.id)) throw new AxelError('ENTITY_NOT_IN_SITE', 404, 'Not found.');
  return e;
};
const present = (req: any, entity: string, row: any) =>
  req.site.compiled.mask(entity, req.site.role, req.site.compiled.computeFormulas(entity, toRecord(entity, row)));

// POST /api/:siteId/:entity/:id/transition
workflow.post('/:entity/:id/transition', ah(async (req, res) => {
  const entity = entityOr404(req);
  const b = z.object({
    to: z.string().min(1),
    idempotencyKey: z.string().min(8).max(100),
    ifVersion: z.number().int().optional(),
    payload: z.record(z.unknown()).optional(),
  }).parse(req.body);
  const s = req.site!;
  const r = await withSite(s.ctx, tx => runTransition(tx, { ...s.ctx, role: s.role }, s.compiled, s.name, entity, req.params.id, b));
  if (!r.replay) bus.emit('record_changed', { siteId: s.siteId, entity });
  res.status(r.replay ? 200 : 201).json({
    replay: r.replay,
    record: present(req, entity, r.row),
    transitions: describeTransitions(s.compiled, entity, r.row, s.role),
  });
}));

// GET /api/:siteId/:entity/:id/timeline - audit events + ledger movements for the record
workflow.get('/:entity/:id/timeline', ah(async (req, res) => {
  const entity = entityOr404(req);
  const s = req.site!;
  const out = await withSite(s.ctx, async c => {
    const exists = (await c.query(`SELECT 1 FROM ${TABLES[entity].table} WHERE id = $1`, [req.params.id])).rowCount;
    if (!exists) throw notFound();
    const events = (await c.query(
      `SELECT e.id, e.kind, e.transition_id, e.from_state, e.to_state, e.actor_role, e.after, e.at, u.name AS actor_name
         FROM audit_events e LEFT JOIN users u ON u.id = e.actor_id
        WHERE e.entity = $1 AND e.record_id = $2 ORDER BY e.at, e.id`, [entity, req.params.id])).rows;
    const movements = (await c.query(
      `SELECT id, kind, qty, reason, ref_id, expires_at, consumed_by, at FROM stock_movements
        WHERE ${entity === 'item' ? 'item_id' : 'ref_id'} = $1 ORDER BY id`, [req.params.id])).rows;
    return { events, movements };
  });
  const clean = (o: any) => (o ? s.compiled.mask(entity, s.role, o) : null);
  res.json({ events: out.events.map(e => ({ ...e, after: clean(e.after) })), movements: out.movements });
}));
