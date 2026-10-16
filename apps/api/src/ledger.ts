import type { Tx, SiteCtx } from './db';
import { AxelError, notFound } from './errors';

export async function move(tx: Tx, ctx: SiteCtx, m: {
  itemId: string; kind: 'receive' | 'adjust'; qty: number; key: string; reason?: string;
}) {
  if (m.kind === 'receive' && m.qty <= 0) throw new AxelError('VALIDATION_FAILED', 422, 'Received quantity must be positive.');
  if (m.qty === 0) throw new AxelError('VALIDATION_FAILED', 422, 'Quantity cannot be zero.');

  const item = (await tx.query(
    'SELECT id, name, on_hand, reserved FROM items WHERE site_id = $1 AND id = $2 FOR UPDATE',
    [ctx.siteId, m.itemId])).rows[0];
  if (!item) throw notFound();

  if (item.on_hand + m.qty < item.reserved)
    throw new AxelError('INSUFFICIENT_STOCK', 409,
      `Adjust refused: ${item.name} has ${item.reserved} reserved; on-hand cannot drop to ${item.on_hand + m.qty}.`,
      { because: { kind: 'law', ref: 'reserved_le_on_hand' }, suggestion: 'Release or commit reservations first.' });

  const ins = await tx.query(
    `INSERT INTO stock_movements (site_id, item_id, kind, qty, reason, idempotency_key, actor_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (site_id, idempotency_key) DO NOTHING RETURNING id`,
    [ctx.siteId, m.itemId, m.kind, m.qty, m.reason ?? null, m.key, ctx.userId]);
  if (!ins.rowCount) return { replay: true, item };

  const after = (await tx.query(
    `UPDATE items SET on_hand = on_hand + $3, row_version = row_version + 1, updated_at = now()
     WHERE site_id = $1 AND id = $2 RETURNING *`, [ctx.siteId, m.itemId, m.qty])).rows[0];

  await tx.query(
    `INSERT INTO audit_events (site_id, entity, record_id, kind, actor_id, actor_role, before, after, version_id, idempotency_key)
     VALUES ($1,'item',$2,$3,$4,$5,$6,$7,$8,$9)`,
    [ctx.siteId, m.itemId, `stock_${m.kind}`, ctx.userId, ctx.role,
     { on_hand: item.on_hand }, { on_hand: after.on_hand }, ctx.versionId ?? null, m.key]);
  return { replay: false, item: after };
}
