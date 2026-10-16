import { Router } from 'express';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { withSite } from './db';
import { toRecord } from './entities';
import { AxelError, ah } from './errors';
import { runTransition } from './workflow';
import { bus } from './blueprints';

// Endpoints named in PS 03. They are thin wrappers: approvals and assignments run through
// the same workflow engine, guards, roles, ledger and audit trail as the generic transition route.
export const aliases = Router({ mergeParams: true });

const needModule = (req: any, id: string) => {
  if (!req.site.compiled.blueprint.modules.includes(id)) throw new AxelError('ENTITY_NOT_IN_SITE', 404, 'Not found.');
};
const present = (req: any, row: any) =>
  req.site.compiled.mask('request', req.site.role, req.site.compiled.computeFormulas('request', toRecord('request', row)));

// GET /api/:siteId/approvals - decision history
aliases.get('/approvals', ah(async (req, res) => {
  needModule(req, 'approval');
  const rows = await withSite(req.site!.ctx, async c => (await c.query(
    `SELECT a.id, a.request_id, a.decision, a.note, a.at, u.name AS decided_by
       FROM approvals a LEFT JOIN users u ON u.id = a.decided_by ORDER BY a.at DESC LIMIT 200`)).rows);
  res.json({ total: rows.length, rows });
}));

// POST /api/:siteId/approvals { requestId, decision: approved|rejected, note?, idempotencyKey? }
aliases.post('/approvals', ah(async (req, res) => {
  needModule(req, 'approval');
  const b = z.object({
    requestId: z.string().uuid(), decision: z.enum(['approved', 'rejected']),
    note: z.string().max(500).optional(), idempotencyKey: z.string().min(8).max(100).optional(),
  }).parse(req.body);
  const s = req.site!;
  const r = await withSite(s.ctx, tx => runTransition(tx, { ...s.ctx, role: s.role }, s.compiled, s.name, 'request', b.requestId, {
    to: b.decision, idempotencyKey: b.idempotencyKey ?? randomUUID(), payload: b.note ? { note: b.note } : undefined,
  }));
  if (!r.replay) bus.emit('record_changed', { siteId: s.siteId, entity: 'request' });
  res.status(r.replay ? 200 : 201).json({ replay: r.replay, record: present(req, r.row) });
}));

// POST /api/:siteId/assignments { requestId, assignedTo?, idempotencyKey? }
// (GET /api/:siteId/assignments is served by the generic resource route.)
aliases.post('/assignments', ah(async (req, res) => {
  needModule(req, 'material-assignment');
  const b = z.object({
    requestId: z.string().uuid(), assignedTo: z.string().max(100).optional(),
    idempotencyKey: z.string().min(8).max(100).optional(),
  }).parse(req.body);
  const s = req.site!;
  const r = await withSite(s.ctx, tx => runTransition(tx, { ...s.ctx, role: s.role }, s.compiled, s.name, 'request', b.requestId, {
    to: 'assigned', idempotencyKey: b.idempotencyKey ?? randomUUID(), payload: { assigned_to: b.assignedTo ?? null },
  }));
  if (!r.replay) bus.emit('record_changed', { siteId: s.siteId, entity: 'assignment' });
  res.status(r.replay ? 200 : 201).json({ replay: r.replay, record: present(req, r.row) });
}));
