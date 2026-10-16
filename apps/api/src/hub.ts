import { Router } from 'express';
import { z } from 'zod';
import { pool, withSite } from './db';
import { requireAuth, requireHubAdmin } from './auth';
import { getPublished } from './blueprints';
import { AxelError, ah } from './errors';
import { runTransition } from './workflow';
import * as ledger from './ledger';

export const hubRouter = Router();

// POST /api/hub/chaos - N concurrent approvals against an item with K units. Exactly K must succeed.
hubRouter.post('/chaos', requireAuth, requireHubAdmin, ah(async (req, res) => {
  const b = z.object({
    siteId: z.string().uuid().optional(),
    concurrency: z.number().int().min(2).max(200).default(50),
    stock: z.number().int().min(1).max(100).default(10),
    keep: z.boolean().default(false),
  }).parse(req.body ?? {});
  const userId = req.user!.id;

  const candidates = b.siteId ? [b.siteId] : (await pool.query('SELECT id FROM sites ORDER BY name')).rows.map(r => r.id);
  let picked: { siteId: string; loaded: NonNullable<Awaited<ReturnType<typeof getPublished>>>; from: string; to: string; tid: string } | null = null;
  for (const id of candidates) {
    const loaded = await getPublished(id);
    const t = loaded?.compiled.blueprint.workflows.request?.transitions.find(x => x.actions?.some(a => a.startsWith('stock.reserve')));
    if (loaded && t) { picked = { siteId: id, loaded, from: t.from, to: t.to, tid: t.id }; break; }
  }
  if (!picked) throw new AxelError('VALIDATION_FAILED', 422, 'No site has a transition that reserves stock.');
  const { siteId, loaded } = picked;

  const role = await withSite({ siteId, userId, role: '' }, async c =>
    (await c.query('SELECT role FROM memberships WHERE site_id = $1 AND user_id = $2', [siteId, userId])).rows[0]?.role);
  if (role !== 'Admin') throw new AxelError('FORBIDDEN', 403, 'You must be an Admin of the target site.');
  const ctx = { siteId, userId, role: 'Admin' as const, versionId: loaded.versionId };

  const stamp = Date.now();
  const { itemId, requestIds } = await withSite(ctx, async tx => {
    const item = (await tx.query(
      `INSERT INTO items (site_id, name, on_hand, data, created_under_version) VALUES ($1,$2,0,$3,$4) RETURNING id`,
      [siteId, `CHAOS-${stamp}`, { sku: `CHAOS-${stamp}`, category: 'Consumable' }, loaded.versionId])).rows[0].id as string;
    await ledger.move(tx, ctx, { itemId: item, kind: 'receive', qty: b.stock, key: `chaos-recv-${item}` });
    const ids: string[] = [];
    for (let i = 0; i < b.concurrency; i++)
      ids.push((await tx.query(
        `INSERT INTO requests (site_id, item_id, qty, state, requested_by, data, created_under_version) VALUES ($1,$2,1,$3,$4,$5,$6) RETURNING id`,
        [siteId, item, picked!.from, userId, { fault: 'chaos', site_location: 'chaos', priority: 'normal' }, loaded.versionId])).rows[0].id);
    return { itemId: item, requestIds: ids };
  });

  const started = Date.now();
  const outcomes = await Promise.all(requestIds.map(id =>
    withSite(ctx, tx => runTransition(tx, ctx, loaded.compiled, loaded.name, 'request', id, { to: picked!.to, idempotencyKey: `chaos-${id}` }))
      .then(() => 'ok', (e: any) => String(e?.code ?? 'ERROR'))));
  const durationMs = Date.now() - started;

  const verify = await withSite(ctx, async tx => ({
    item: (await tx.query('SELECT on_hand, reserved FROM items WHERE id = $1', [itemId])).rows[0],
    reserves: (await tx.query(`SELECT count(*)::int AS n FROM stock_movements WHERE item_id = $1 AND kind = 'reserve'`, [itemId])).rows[0].n,
    ledger: (await tx.query('SELECT on_hand, reserved FROM v_ledger_balance WHERE item_id = $1', [itemId])).rows[0],
  }));
  const counts = outcomes.reduce<Record<string, number>>((m, o) => { m[o] = (m[o] ?? 0) + 1; return m; }, {});
  const passed = counts.ok === b.stock && verify.reserves === b.stock && verify.item.reserved === b.stock
    && verify.ledger.reserved === verify.item.reserved && verify.ledger.on_hand === verify.item.on_hand;

  if (!b.keep) {
    await withSite(ctx, async tx => {
      await tx.query('DELETE FROM approvals WHERE request_id = ANY($1)', [requestIds]);
      await tx.query('DELETE FROM audit_events WHERE record_id = ANY($1) OR record_id = $2', [requestIds, itemId]);
      await tx.query('DELETE FROM stock_movements WHERE item_id = $1', [itemId]);
      await tx.query('DELETE FROM requests WHERE id = ANY($1)', [requestIds]);
      await tx.query('DELETE FROM items WHERE id = $1', [itemId]);
    });
  }

  res.json({
    site: loaded.name, transition: picked.tid, concurrency: b.concurrency, stock: b.stock, durationMs,
    outcomes: counts, item: verify.item, ledger: verify.ledger, reserveMovements: verify.reserves, passed,
  });
}));
