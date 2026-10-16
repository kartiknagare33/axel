import { Router } from 'express';
import { z } from 'zod';
import { REGISTRY } from '@axel/compiler';
import { withSite, UUID, type Tx } from './db';
import { TABLES, resolveEntity, toRecord, split } from './entities';
import { AxelError, ah, notFound } from './errors';
import { requireRole } from './site';
import { move } from './ledger';
import { describeTransitions } from './workflow';

export const resources = Router({ mergeParams: true });

const entityOr404 = (req: any) => {
  const e = resolveEntity(req.site.compiled.blueprint, req.params.entity);
  if (!e) throw new AxelError('ENTITY_NOT_IN_SITE', 404, 'Not found.');
  return e;
};
const present = (req: any, entity: string, row: any) => {
  const { compiled, role } = req.site;
  return compiled.mask(entity, role, compiled.computeFormulas(entity, toRecord(entity, row)));
};
const audit = (tx: Tx, req: any, entity: string, id: string, kind: string, before: unknown, after: unknown) =>
  tx.query(
    `INSERT INTO audit_events (site_id, entity, record_id, kind, actor_id, actor_role, before, after, version_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
    [req.site.siteId, entity, id, kind, req.site.ctx.userId, req.site.role, before, after, req.site.versionId]);

// GET /components - enabled modules (brief alias)
resources.get('/components', (req, res) => {
  const bp = req.site!.compiled.blueprint;
  res.json(bp.modules.map(id => ({ id, name: REGISTRY[id]?.name, kind: REGISTRY[id]?.kind })));
});

// LIST
resources.get('/:entity', ah(async (req, res) => {
  const entity = entityOr404(req);
  const spec = TABLES[entity];
  const fields = new Set(req.site!.compiled.blueprint.entities[entity].fields.map(f => f.key));
  const q = z.object({
    page: z.coerce.number().int().min(1).default(1),
    limit: z.coerce.number().int().min(1).max(200).default(50),
    sort: z.string().optional(),
    filter: z.record(z.string()).optional(),
  }).parse(req.query);

  const where: string[] = [];
  const args: unknown[] = [];
  for (const [k, v] of Object.entries(q.filter ?? {})) {
    if (!fields.has(k) && k !== 'state') throw new AxelError('VALIDATION_FAILED', 422, `Cannot filter by ${k}.`);
    args.push(v);
    where.push(spec.core.includes(k) ? `${k}::text = $${args.length}` : `data->>'${k}' = $${args.length}`);
  }
  let order = 'created_at DESC';
  if (q.sort) {
    const desc = q.sort.startsWith('-');
    const col = q.sort.replace(/^-/, '');
    if (![...spec.core, 'created_at', 'updated_at'].includes(col)) throw new AxelError('VALIDATION_FAILED', 422, `Cannot sort by ${col}.`);
    order = `${col} ${desc ? 'DESC' : 'ASC'}`;
  }
  args.push(q.limit, (q.page - 1) * q.limit);
  const rows = await withSite(req.site!.ctx, async c => (await c.query(
    `SELECT *, count(*) OVER() AS _total FROM ${spec.table}
     ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
     ORDER BY ${order} LIMIT $${args.length - 1} OFFSET $${args.length}`, args)).rows);
  res.json({ total: Number(rows[0]?._total ?? 0), page: q.page, rows: rows.map(({ _total, ...r }) => present(req, entity, r)) });
}));

// CREATE
resources.post('/:entity', ah(async (req, res) => {
  const entity = entityOr404(req);
  const spec = TABLES[entity];
  const { compiled, role, ctx } = req.site!;
  const body = compiled.validator(entity, role, 'create').parse(req.body ?? {});
  const { core, data } = split(spec, body);
  if (entity === 'request') {
    core.state = compiled.blueprint.workflows.request?.initial ?? 'draft';
    core.requested_by = ctx.userId;
  }
  Object.assign(core, spec.insertDefaults?.());
  const cols = ['site_id', 'created_under_version', ...Object.keys(core), 'data'];
  const vals = [ctx.siteId, req.site!.versionId, ...Object.values(core), data];
  const row = await withSite(ctx, async c => {
    const r = (await c.query(
      `INSERT INTO ${spec.table} (${cols.join(',')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(',')}) RETURNING *`, vals)).rows[0];
    await audit(c, req, entity, r.id, 'create', null, body);
    return r;
  });
  res.status(201).json(present(req, entity, row));
}));

// READ
resources.get('/:entity/:id', ah(async (req, res) => {
  const entity = entityOr404(req);
  if (!UUID.test(req.params.id)) throw notFound();
  const row = await withSite(req.site!.ctx, async c =>
    (await c.query(`SELECT * FROM ${TABLES[entity].table} WHERE id = $1`, [req.params.id])).rows[0]);
  if (!row) throw notFound();
  const transitions = describeTransitions(req.site!.compiled, entity, row, req.site!.role);
  res.json({ ...present(req, entity, row), transitions, allowedTransitions: transitions.filter(t => t.allowed) });
}));

// UPDATE (optimistic concurrency)
resources.patch('/:entity/:id', ah(async (req, res) => {
  const entity = entityOr404(req);
  if (!UUID.test(req.params.id)) throw notFound();
  const spec = TABLES[entity];
  const { compiled, role, ctx } = req.site!;
  const { ifVersion, ...rest } = req.body ?? {};
  if (!Number.isInteger(ifVersion)) throw new AxelError('VALIDATION_FAILED', 422, 'ifVersion is required.');
  const body = compiled.validator(entity, role, 'update').parse(rest);
  const { core, data } = split(spec, body);

  const row = await withSite(ctx, async c => {
    const before = (await c.query(`SELECT * FROM ${spec.table} WHERE id = $1 FOR UPDATE`, [req.params.id])).rows[0];
    if (!before) throw notFound();
    if (before.row_version !== ifVersion)
      throw new AxelError('STALE_RECORD', 409, `This record changed since you opened it (now v${before.row_version}). Reload to continue.`, { current: before.row_version });
    const sets = Object.keys(core).map((k, i) => `${k} = $${i + 3}`);
    const r = (await c.query(
      `UPDATE ${spec.table} SET ${[...sets, `data = data || $${sets.length + 3}`, 'row_version = row_version + 1', 'updated_at = now()'].join(', ')}
       WHERE id = $1 AND row_version = $2 RETURNING *`,
      [req.params.id, ifVersion, ...Object.values(core), data])).rows[0];
    await audit(c, req, entity, r.id, 'update', toRecord(entity, before), body);
    return r;
  });
  res.json(present(req, entity, row));
}));

// STOCK: receive / adjust through the ledger only
resources.post('/:entity/:id/stock', requireRole('Manager'), ah(async (req, res) => {
  const entity = entityOr404(req);
  if (entity !== 'item' || !UUID.test(req.params.id)) throw notFound();
  const b = z.object({
    kind: z.enum(['receive', 'adjust']),
    qty: z.coerce.number().refine(n => n !== 0, 'qty cannot be zero'),
    reason: z.string().max(200).optional(),
    idempotencyKey: z.string().min(8).max(100),
  }).parse(req.body);
  const r = await withSite(req.site!.ctx, c => move(c, req.site!.ctx, { itemId: req.params.id, kind: b.kind, qty: b.qty, key: b.idempotencyKey, reason: b.reason }));
  res.status(r.replay ? 200 : 201).json({ replay: r.replay, item: present(req, 'item', r.item) });
}));
