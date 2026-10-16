import type { Tx, SiteCtx } from './db';
import { AxelError, notFound } from './errors';

// Stock is an append-only ledger. items.on_hand / items.reserved are maintained only here,
// always under a row lock on the item, inside the caller's transaction.

const actor = (ctx: SiteCtx) => ctx.userId || null;
export const label = (it: any) => (it?.data?.sku ? `${it.data.sku} (${it.name})` : it?.name ?? 'item');

export async function lockItem(tx: Tx, ctx: SiteCtx, itemId: string) {
  const it = (await tx.query(
    'SELECT id, name, on_hand, reserved, data FROM items WHERE site_id = $1 AND id = $2 FOR UPDATE',
    [ctx.siteId, itemId])).rows[0];
  if (!it) throw new AxelError('VALIDATION_FAILED', 422, 'That item does not exist in this site.');
  return it as { id: string; name: string; on_hand: number; reserved: number; data: any };
}

async function insertMove(tx: Tx, ctx: SiteCtx, m: {
  itemId: string; kind: string; qty: number; key: string;
  refType?: string; refId?: string; reason?: string; ttl?: string;
}) {
  const r = await tx.query(
    `INSERT INTO stock_movements (site_id, item_id, kind, qty, ref_type, ref_id, reason, idempotency_key, expires_at, actor_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8, CASE WHEN $9::text IS NULL THEN NULL ELSE now() + ($9::text)::interval END, $10)
     ON CONFLICT (site_id, idempotency_key) DO NOTHING RETURNING id`,
    [ctx.siteId, m.itemId, m.kind, m.qty, m.refType ?? null, m.refId ?? null, m.reason ?? null, m.key, m.ttl ?? null, actor(ctx)]);
  return r.rows[0]?.id as string | undefined;
}

async function bump(tx: Tx, ctx: SiteCtx, itemId: string, dOnHand: number, dReserved: number) {
  return (await tx.query(
    `UPDATE items SET on_hand = on_hand + $3, reserved = reserved + $4, row_version = row_version + 1, updated_at = now()
     WHERE site_id = $1 AND id = $2 RETURNING *`, [ctx.siteId, itemId, dOnHand, dReserved])).rows[0];
}

async function activeReservation(tx: Tx, ctx: SiteCtx, refId: string, itemId: string) {
  return (await tx.query(
    `SELECT id, qty FROM stock_movements
      WHERE site_id = $1 AND ref_id = $2 AND item_id = $3 AND kind = 'reserve' AND consumed_by IS NULL
      ORDER BY id DESC LIMIT 1 FOR UPDATE`, [ctx.siteId, refId, itemId])).rows[0] as { id: string; qty: number } | undefined;
}

// receive / adjust (inventory module)
export async function move(tx: Tx, ctx: SiteCtx, m: { itemId: string; kind: 'receive' | 'adjust'; qty: number; key: string; reason?: string }) {
  if (m.kind === 'receive' && m.qty <= 0) throw new AxelError('VALIDATION_FAILED', 422, 'Received quantity must be positive.');
  if (m.qty === 0) throw new AxelError('VALIDATION_FAILED', 422, 'Quantity cannot be zero.');
  const item = await lockItem(tx, ctx, m.itemId).catch(() => { throw notFound(); });
  if (item.on_hand + m.qty < item.reserved)
    throw new AxelError('INSUFFICIENT_STOCK', 409,
      `Adjust refused: ${label(item)} has ${item.reserved} reserved; on-hand cannot drop to ${item.on_hand + m.qty}.`,
      { because: { kind: 'law', ref: 'reserved_le_on_hand' }, suggestion: 'Release or commit reservations first.' });
  const id = await insertMove(tx, ctx, { itemId: m.itemId, kind: m.kind, qty: m.qty, key: m.key, reason: m.reason });
  if (!id) return { replay: true, item };
  const after = await bump(tx, ctx, m.itemId, m.qty, 0);
  await tx.query(
    `INSERT INTO audit_events (site_id, entity, record_id, kind, actor_id, actor_role, before, after, version_id, idempotency_key)
     VALUES ($1,'item',$2,$3,$4,$5,$6,$7,$8,$9)`,
    [ctx.siteId, m.itemId, `stock_${m.kind}`, actor(ctx), ctx.role, { on_hand: item.on_hand }, { on_hand: after.on_hand }, ctx.versionId ?? null, m.key]);
  return { replay: false, item: after };
}

export async function reserve(tx: Tx, ctx: SiteCtx, a: { itemId: string; qty: number; refId: string; key: string; ttl: string }) {
  const it = await lockItem(tx, ctx, a.itemId);
  const available = it.on_hand - it.reserved;
  if (available < a.qty)
    throw new AxelError('INSUFFICIENT_STOCK', 409,
      `Approval refused: reserving ${a.qty} would push reserved above on-hand for ${label(it)} (only ${available} available).`,
      { because: { kind: 'law', ref: 'reserved_le_on_hand' }, suggestion: 'Receive more stock or reduce the quantity.' });
  const id = await insertMove(tx, ctx, { itemId: a.itemId, kind: 'reserve', qty: a.qty, key: a.key, refType: 'request', refId: a.refId, ttl: a.ttl });
  if (id) await bump(tx, ctx, a.itemId, 0, a.qty);
}

export async function commit(tx: Tx, ctx: SiteCtx, a: { itemId: string; refId: string; key: string }) {
  const it = await lockItem(tx, ctx, a.itemId);
  const res = await activeReservation(tx, ctx, a.refId, a.itemId);
  if (!res)
    throw new AxelError('NO_RESERVATION', 409,
      `Nothing is reserved for this request on ${label(it)}. The reservation may have expired.`,
      { suggestion: 'Approve the request again to reserve stock.' });
  const id = await insertMove(tx, ctx, { itemId: a.itemId, kind: 'commit', qty: res.qty, key: a.key, refType: 'request', refId: a.refId });
  if (!id) return;
  await tx.query('UPDATE stock_movements SET consumed_by = $2 WHERE id = $1', [res.id, id]);
  await bump(tx, ctx, a.itemId, -res.qty, -res.qty);
}

export async function release(tx: Tx, ctx: SiteCtx, a: { itemId: string; refId: string; key: string; reason: string }) {
  await lockItem(tx, ctx, a.itemId);
  const res = await activeReservation(tx, ctx, a.refId, a.itemId);
  if (!res) return; // nothing reserved: release is a no-op
  const id = await insertMove(tx, ctx, { itemId: a.itemId, kind: 'release', qty: res.qty, key: a.key, refType: 'request', refId: a.refId, reason: a.reason });
  if (!id) return;
  await tx.query('UPDATE stock_movements SET consumed_by = $2 WHERE id = $1', [res.id, id]);
  await bump(tx, ctx, a.itemId, 0, -res.qty);
}

export async function giveBack(tx: Tx, ctx: SiteCtx, a: { itemId: string; qty: number; refId: string; key: string; reason?: string }) {
  await lockItem(tx, ctx, a.itemId);
  const id = await insertMove(tx, ctx, { itemId: a.itemId, kind: 'return', qty: a.qty, key: a.key, refType: 'request', refId: a.refId, reason: a.reason ?? 'return' });
  if (id) await bump(tx, ctx, a.itemId, a.qty, 0);
}

// Expiry: caller must already hold the lock on the referencing request row.
export async function expireOne(tx: Tx, ctx: SiteCtx, movementId: string) {
  const res = (await tx.query(
    `SELECT id, item_id, qty FROM stock_movements
      WHERE id = $1 AND kind = 'reserve' AND consumed_by IS NULL AND expires_at < now() FOR UPDATE`, [movementId])).rows[0];
  if (!res) return null;
  await lockItem(tx, ctx, res.item_id);
  const id = await insertMove(tx, ctx, { itemId: res.item_id, kind: 'release', qty: res.qty, key: `expire-${res.id}`, reason: 'timeout' });
  if (!id) return null;
  await tx.query('UPDATE stock_movements SET consumed_by = $2 WHERE id = $1', [res.id, id]);
  await bump(tx, ctx, res.item_id, 0, -res.qty);
  return { qty: Number(res.qty) };
}
