# Axel - batch 3 (workflow engine, reservation ledger, chaos, timelines). Run from the axel folder.
$ErrorActionPreference = 'Stop'
function W([string]$Path, [string]$Content) {
  $full = Join-Path $PSScriptRoot $Path
  New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
  $text = $Content.Replace("`r`n", "`n").TrimStart("`n") + "`n"
  [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding $false))
  Write-Host "created $Path"
}
function Patch([string]$Path, [string]$Old, [string]$New) {
  $full = Join-Path $PSScriptRoot $Path
  $text = [System.IO.File]::ReadAllText($full).Replace("`r`n", "`n")
  $Old = $Old.Replace("`r`n", "`n"); $New = $New.Replace("`r`n", "`n")
  if ($text.Contains($New)) { Write-Host "already patched $Path"; return }
  if (-not $text.Contains($Old)) { throw "patch target not found in $Path" }
  [System.IO.File]::WriteAllText($full, $text.Replace($Old, $New), (New-Object System.Text.UTF8Encoding $false))
  Write-Host "patched $Path"
}

# ============================== PATCHES ==============================
Patch 'packages/compiler/src/compile.ts' @'
'stock.consume', 'repair.open'
'@ @'
'stock.consume', 'stock.return', 'repair.open'
'@

Patch 'apps/api/seed/blueprints.ts' @'
actions: ["stock.release(item_id, qty, reason='return')"]
'@ @'
actions: ['stock.return(item_id, qty)']
'@

Patch 'apps/api/src/entities.ts' @'
'qty', 'assigned_to', 'state'
'@ @'
'qty', 'state'
'@

Patch 'apps/api/src/resources.ts' @'
import { move } from './ledger';
'@ @'
import { move } from './ledger';
import { describeTransitions } from './workflow';
'@

Patch 'apps/api/src/resources.ts' @'
  const wf = req.site!.compiled.blueprint.workflows[entity];
  const allowedTransitions = wf?.transitions
    .filter(t => t.from === row.state && t.roles.includes(req.site!.role))
    .map(t => ({ id: t.id, to: t.to, label: t.label ?? t.to })) ?? [];
  res.json({ ...present(req, entity, row), allowedTransitions });
'@ @'
  const transitions = describeTransitions(req.site!.compiled, entity, row, req.site!.role);
  res.json({ ...present(req, entity, row), transitions, allowedTransitions: transitions.filter(t => t.allowed) });
'@

Patch 'apps/api/seed/seed.ts' @'
import { centralStores, serviceCentre, distribution, SITE_IDS } from './blueprints';
'@ @'
import { centralStores, serviceCentre, distribution, SITE_IDS } from './blueprints';
import { runLifecycle } from './lifecycle';
'@

Patch 'apps/api/seed/seed.ts' @'
await pool.end();
console.log('done. login: admin@axel.dev / demo1234');
'@ @'
const managerIds = Object.fromEntries(Object.entries(people).map(([slug, ps]) => [slug, ps.find(p => p[1] === 'Manager')![0]]));
await runLifecycle(blueprints, SITE_IDS, managerIds);
await pool.end();
console.log('done. login: admin@axel.dev / demo1234');
'@

Patch 'apps/api/package.json' @'
"test:isolation": "tsx --env-file=../../.env --test test/isolation.test.ts"
'@ @'
"test:isolation": "tsx --env-file=../../.env --test test/isolation.test.ts",
    "test:workflow": "tsx --env-file=../../.env --test test/workflow.test.ts"
'@

Patch 'package.json' @'
"test:isolation": "pnpm --filter @axel/api test:isolation"
'@ @'
"test:isolation": "pnpm --filter @axel/api test:isolation",
    "test:workflow": "pnpm --filter @axel/api test:workflow"
'@

Patch '.env' @'
PORT=4000
'@ @'
PORT=4000
# Uncomment for the stage demo so approved reservations expire quickly:
# DEMO_RESERVATION_TTL=45 seconds
'@

Patch 'apps/web/src/renderer/views.tsx' @'
import { RecordForm } from './RecordForm';
'@ @'
import { RecordForm } from './RecordForm';
import { KanbanBoard } from './kanban';
'@

Patch 'apps/web/src/renderer/views.tsx' @'
kanban: KanbanView,
'@ @'
kanban: KanbanBoard,
'@

Patch 'apps/web/src/pages/Hub.tsx' @'
import { useSession } from '../store/session';
'@ @'
import { useSession } from '../store/session';
import { ChaosCard } from './Chaos';
'@

Patch 'apps/web/src/pages/Hub.tsx' @'
      </main>
'@ @'
        {user?.hubAdmin && <ChaosCard />}
      </main>
'@

# ============================== NEW / REWRITTEN FILES ==============================
W 'apps/api/migrations/002_workflow.sql' @'
-- one transition per idempotency key per site (double-click / retry safety)
CREATE UNIQUE INDEX ux_audit_transition_idem ON audit_events (site_id, idempotency_key)
  WHERE kind = 'transition' AND idempotency_key IS NOT NULL;
-- fast lookup of the active reservation for a request
CREATE INDEX ix_mov_ref ON stock_movements (site_id, ref_id) WHERE kind = 'reserve' AND consumed_by IS NULL;
'@

W 'apps/api/src/ledger.ts' @'
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
'@

W 'apps/api/src/workflow.ts' @'
import { parse, evaluate, type Compiled, type Node, type Role } from '@axel/compiler';
import type { Tx, SiteCtx } from './db';
import { TABLES, toRecord } from './entities';
import { AxelError, notFound } from './errors';
import * as ledger from './ledger';

const astCache = new Map<string, Node>();
const ast = (s: string) => {
  let n = astCache.get(s);
  if (!n) { n = parse(s); astCache.set(s, n); }
  return n;
};

function stockCalls(n: Node, out: Extract<Node, { k: 'call' }>[] = []) {
  if (n.k === 'call') { if (n.fn.startsWith('stock.')) out.push(n); n.args.forEach(a => stockCalls(a, out)); }
  else if (n.k === 'un') stockCalls(n.e, out);
  else if (n.k === 'bin') { stockCalls(n.l, out); stockCalls(n.r, out); }
  return out;
}

function ttlInterval(v: unknown): string {
  const override = process.env.DEMO_RESERVATION_TTL;
  if (override) return override;
  const m = /^(\d+)\s*([smhd])$/.exec(String(v ?? '72h'));
  if (!m) return '72 hours';
  return `${m[1]} ${({ s: 'seconds', m: 'minutes', h: 'hours', d: 'days' } as Record<string, string>)[m[2]]}`;
}

export interface TransitionInput {
  to: string; idempotencyKey: string; ifVersion?: number; payload?: Record<string, unknown>;
}

/** Every transition out of the record's current state, with an explained reason when the role cannot use it. */
export function describeTransitions(compiled: Compiled, entity: string, row: any, role: Role) {
  const wf = compiled.blueprint.workflows[entity];
  if (!wf) return [];
  return wf.transitions.filter(t => t.from === row.state).map(t => {
    const allowed = t.roles.includes(role);
    const label = t.label ?? t.to;
    return {
      id: t.id, to: t.to, label, allowed,
      reason: allowed ? undefined : `Only ${t.roles.filter(r => r !== 'Public').join(', ')} can ${label.toLowerCase()} here (transition ${t.id}).`,
    };
  });
}

export async function runTransition(
  tx: Tx, ctx: SiteCtx & { role: Role }, compiled: Compiled, siteName: string,
  entity: string, id: string, input: TransitionInput,
) {
  const wf = compiled.blueprint.workflows[entity];
  const spec = TABLES[entity];
  if (!wf || !spec) throw new AxelError('ENTITY_NOT_IN_SITE', 404, 'Not found.');

  // 1. Lock the record first: concurrent transitions on it serialise here.
  const before = (await tx.query(`SELECT * FROM ${spec.table} WHERE id = $1 FOR UPDATE`, [id])).rows[0];
  if (!before) throw notFound();

  // 2. Idempotency: a retry / double-click with the same key returns the first result.
  const prior = (await tx.query(
    `SELECT 1 FROM audit_events WHERE site_id = $1 AND kind = 'transition' AND idempotency_key = $2`,
    [ctx.siteId, input.idempotencyKey])).rowCount;
  if (prior) return { row: before, replay: true };

  // 3. Optimistic concurrency.
  if (input.ifVersion != null && before.row_version !== input.ifVersion)
    throw new AxelError('STALE_RECORD', 409, `This record changed since you opened it (now v${before.row_version}). Reload to continue.`, { current: before.row_version });

  // 4. Is this a legal step from the current state, and may this role take it?
  const t = wf.transitions.find(x => x.from === before.state && x.to === input.to);
  if (!t) {
    const known = wf.transitions.some(x => x.to === input.to);
    throw new AxelError('TRANSITION_NOT_ALLOWED', 409, known
      ? `This record is '${before.state}', so it cannot move to '${input.to}'. Someone may have changed it already.`
      : `'${input.to}' is not a step in this workflow.`);
  }
  const label = t.label ?? t.to;
  if (!t.roles.includes(ctx.role))
    throw new AxelError('TRANSITION_NOT_ALLOWED', 403,
      `Only ${t.roles.filter(r => r !== 'Public').join(', ')} can ${label.toLowerCase()} in ${siteName} (transition ${t.id}).`,
      { because: { kind: 'transition', ref: t.id } });

  const rec = compiled.computeFormulas(entity, toRecord(entity, before));
  const recScope = { get: (k: string) => (k === 'user.role' ? ctx.role : rec[k]) };

  // 5. Guard, evaluated against locked stock rows.
  if (t.guard) {
    const g = ast(t.guard);
    const stock = new Map<string, Awaited<ReturnType<typeof ledger.lockItem>>>();
    for (const c of stockCalls(g)) {
      const itemId = String(evaluate(c.args[0], recScope));
      if (!stock.has(itemId)) stock.set(itemId, await ledger.lockItem(tx, ctx, itemId));
    }
    const ok = evaluate(g, {
      get: recScope.get,
      call: (fn, args) => {
        const it = stock.get(String(args[0]));
        if (fn === 'stock.available') return it ? it.on_hand - it.reserved : 0;
        if (fn === 'stock.on_hand') return it ? it.on_hand : 0;
        if (fn === 'now') return Date.now();
        throw new AxelError('GUARD_FAILED', 422, `${fn}() is not allowed in a guard.`);
      },
    });
    if (!ok) {
      const detail = [...stock.values()].map(it => `available stock for ${ledger.label(it)} is ${it.on_hand - it.reserved}`).join('; ');
      throw new AxelError('GUARD_FAILED', 422,
        `${label} blocked: ${detail ? `${detail}, ` : ''}rule "${t.guard}" is not met (transition ${t.id}).`,
        { because: { kind: 'guard', ref: t.id, rule: t.guard } });
    }
  }

  // 6. Actions (ledger operations), all inside this transaction.
  for (const [i, a] of (t.actions ?? []).entries()) {
    const n = ast(a);
    if (n.k !== 'call') continue;
    const args = n.args.map(x => evaluate(x, recScope));
    const key = `${input.idempotencyKey}:${i}`;
    const itemId = String(args[0] ?? '');
    switch (n.fn) {
      case 'stock.reserve': await ledger.reserve(tx, ctx, { itemId, qty: Number(args[1]), refId: id, key, ttl: ttlInterval(args[2]) }); break;
      case 'stock.commit': await ledger.commit(tx, ctx, { itemId, refId: id, key }); break;
      case 'stock.release': await ledger.release(tx, ctx, { itemId, refId: id, key, reason: String(args[2] ?? 'cancel') }); break;
      case 'stock.return': await ledger.giveBack(tx, ctx, { itemId, qty: Number(args[1]), refId: id, key }); break;
      case 'repair.open':
        await tx.query(
          `INSERT INTO repairs (site_id, request_id, serial_no, fault, created_under_version) VALUES ($1,$2,$3,$4,$5)`,
          [ctx.siteId, id, rec.serial_no ?? null, rec.fault ?? null, ctx.versionId ?? null]);
        break;
      case 'repair.close':
        await tx.query(
          `UPDATE repairs SET state = 'closed', closed_at = now(), row_version = row_version + 1, updated_at = now()
            WHERE site_id = $1 AND request_id = $2 AND state <> 'closed'`, [ctx.siteId, id]);
        break;
      default: break; // notify(): no-op in the prototype
    }
  }

  // 7. Module effects owned by Approval and Material Assignment.
  const mods = new Set(compiled.blueprint.modules);
  if (entity === 'request' && mods.has('approval') && t.from === 'submitted' && (t.to === 'approved' || t.to === 'rejected'))
    await tx.query(
      `INSERT INTO approvals (site_id, request_id, decision, decided_by, note, created_under_version) VALUES ($1,$2,$3,$4,$5,$6)`,
      [ctx.siteId, id, t.to, ctx.userId || null, (input.payload?.note as string) ?? null, ctx.versionId ?? null]);
  if (entity === 'request' && mods.has('material-assignment') && t.to === 'assigned')
    await tx.query(
      `INSERT INTO assignments (site_id, request_id, item_id, qty, state, data, created_under_version) VALUES ($1,$2,$3,$4,'assigned',$5,$6)`,
      [ctx.siteId, id, before.item_id, before.qty, { assigned_to: input.payload?.assigned_to ?? null }, ctx.versionId ?? null]);

  // 8. Move the record and write the event.
  const after = (await tx.query(
    `UPDATE ${spec.table} SET state = $2, row_version = row_version + 1, updated_at = now() WHERE id = $1 RETURNING *`,
    [id, t.to])).rows[0];
  await tx.query(
    `INSERT INTO audit_events (site_id, entity, record_id, kind, transition_id, from_state, to_state, actor_id, actor_role, before, after, version_id, idempotency_key)
     VALUES ($1,$2,$3,'transition',$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
    [ctx.siteId, entity, id, t.id, t.from, t.to, ctx.userId || null, ctx.role,
     { state: before.state }, { state: t.to, ...(input.payload ?? {}) }, ctx.versionId ?? null, input.idempotencyKey]);
  return { row: after, replay: false };
}
'@

W 'apps/api/src/workflowRoutes.ts' @'
import { Router } from 'express';
import { z } from 'zod';
import { withSite, UUID } from './db';
import { TABLES, resolveEntity, toRecord } from './entities';
import { AxelError, ah, notFound } from './errors';
import { runTransition, describeTransitions } from './workflow';

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
'@

W 'apps/api/src/hub.ts' @'
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
'@

W 'apps/api/src/jobs.ts' @'
import { pool, withSite } from './db';
import { getPublished } from './blueprints';
import * as ledger from './ledger';

// Every 10 s: release expired reservations and send their requests back for re-approval.
export function startJobs() {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      const sites = (await pool.query('SELECT id FROM sites')).rows;
      for (const s of sites) {
        const loaded = await getPublished(s.id);
        if (!loaded) continue;
        const ctx = { siteId: s.id, userId: '', role: 'Admin' as const, versionId: loaded.versionId };
        const reserveT = loaded.compiled.blueprint.workflows.request?.transitions.find(t => t.actions?.some(a => a.startsWith('stock.reserve')));
        const expired = await withSite(ctx, async tx => (await tx.query(
          `SELECT id, ref_id FROM stock_movements
            WHERE kind = 'reserve' AND consumed_by IS NULL AND expires_at < now() ORDER BY id LIMIT 100`)).rows);
        for (const r of expired) {
          await withSite(ctx, async tx => {
            if (r.ref_id) await tx.query('SELECT id FROM requests WHERE id = $1 FOR UPDATE', [r.ref_id]); // same lock order as transitions
            const done = await ledger.expireOne(tx, ctx, r.id);
            if (!done || !r.ref_id) return;
            const back = reserveT ? (await tx.query(
              `UPDATE requests SET state = $2, row_version = row_version + 1, updated_at = now() WHERE id = $1 AND state = $3 RETURNING id`,
              [r.ref_id, reserveT.from, reserveT.to])).rowCount : 0;
            await tx.query(
              `INSERT INTO audit_events (site_id, entity, record_id, kind, from_state, to_state, actor_role, after, version_id)
               VALUES ($1,'request',$2,'reservation_expired',$3,$4,'system',$5,$6)`,
              [ctx.siteId, r.ref_id, reserveT?.to ?? null, back ? reserveT!.from : null, { released: done.qty }, ctx.versionId]);
          });
        }
      }
    } catch (e) {
      console.error('expiry job', e);
    } finally {
      running = false;
    }
  };
  setInterval(tick, 10_000);
}
'@

W 'apps/api/src/server.ts' @'
import express from 'express';
import { authRouter, requireAuth, memberships } from './auth';
import { sitesRouter } from './sites';
import { siteScope } from './site';
import { resources } from './resources';
import { analytics } from './analytics';
import { workflow } from './workflowRoutes';
import { hubRouter } from './hub';
import { errorHandler, ah } from './errors';
import { pool } from './db';
import { startPublishListener } from './blueprints';
import { startJobs } from './jobs';

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '2mb' }));

app.get('/api/health', ah(async (_req, res) => { await pool.query('SELECT 1'); res.json({ ok: true }); }));
app.use('/api/auth', authRouter);
app.get('/api/me', requireAuth, ah(async (req, res) => {
  const u = (await pool.query('SELECT id, email, name, is_hub_admin FROM users WHERE id = $1', [req.user!.id])).rows[0];
  res.json({ user: { id: u.id, email: u.email, name: u.name, hubAdmin: u.is_hub_admin }, memberships: await memberships(u.id) });
}));
app.use('/api/sites', sitesRouter);
app.use('/api/hub', hubRouter);
app.use('/api/:siteId', requireAuth, siteScope, analytics, workflow, resources);
app.use(errorHandler);

await startPublishListener();
startJobs();
const port = Number(process.env.PORT ?? 4000);
app.listen(port, () => console.log(`Axel API on :${port}`));
'@

W 'apps/api/seed/lifecycle.ts' @'
import { compile, type Blueprint, type Workflow } from '@axel/compiler';
import { pool, withSite } from '../src/db';
import { runTransition } from '../src/workflow';

// Seeded reservations always use the Blueprint TTL, never the stage-demo override.
delete process.env.DEMO_RESERVATION_TTL;

function happyPath(wf: Workflow) {
  const out: string[] = [];
  const seen = new Set<string>(['submitted']);
  let s = 'submitted';
  for (;;) {
    const t = wf.transitions.find(x => x.from === s && x.to !== 'rejected' && !seen.has(x.to));
    if (!t) break;
    out.push(t.to); seen.add(t.to); s = t.to;
  }
  return out;
}

// Push seeded requests through the real engine so every state, reservation and audit event is genuine.
export async function runLifecycle(bps: Blueprint[], siteIds: Record<string, string>, managers: Record<string, string>) {
  for (const bp of bps) {
    const wf = bp.workflows.request;
    if (!wf) continue;
    const compiled = compile(bp);
    const siteId = siteIds[bp.slug];
    const versionId = (await pool.query('SELECT published_version_id FROM sites WHERE id = $1', [siteId])).rows[0].published_version_id;
    const ctx = { siteId, userId: managers[bp.slug], role: 'Manager' as const, versionId };
    const submitted: string[] = await withSite(ctx, async tx =>
      (await tx.query(`SELECT id FROM requests WHERE state = 'submitted' ORDER BY created_at, id`)).rows.map(r => r.id));
    const path = happyPath(wf);
    for (const [i, id] of submitted.entries()) {
      const steps = i === submitted.length - 1 && wf.transitions.some(t => t.to === 'rejected') ? ['rejected'] : path.slice(0, i % (path.length + 1));
      for (const to of steps) {
        try {
          await withSite(ctx, tx => runTransition(tx, ctx, compiled, bp.name, 'request', id, {
            to, idempotencyKey: `seed-${id}-${to}`,
            payload: to === 'assigned' ? { assigned_to: ['Ravi', 'Neha', 'Imran'][i % 3] } : undefined,
          }));
        } catch (e) {
          console.warn(`seed ${bp.slug}: ${to} failed: ${(e as Error).message}`);
          break;
        }
      }
    }
    console.log(`lifecycle ${bp.slug}: walked ${submitted.length} requests along ${path.join(' > ')}`);
  }
}
'@

W 'apps/api/test/workflow.test.ts' @'
import { test, before } from 'node:test';
import assert from 'node:assert/strict';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const SC = '22222222-2222-4222-8222-222222222222';

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  assert.equal(r.status, 200);
  return (await r.json()).token as string;
}
async function call(token: string, method: string, site: string, path: string, body?: unknown) {
  const r = await fetch(`${API}/${site}${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, 'x-site-id': site, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}

let admin = '', scManager = '', scMember = '';
before(async () => { [admin, scManager, scMember] = await Promise.all(['admin@axel.dev', 'manager@sc.dev', 'member@sc.dev'].map(login)); });

const submitted = async () =>
  (await call(scManager, 'GET', SC, '/requests?filter%5Bstate%5D=submitted&limit=50')).body.rows as any[];

test('chaos: 50 concurrent approvals against 10 units, exactly 10 succeed', async () => {
  const r = await fetch(`${API}/hub/chaos`, {
    method: 'POST',
    headers: { authorization: `Bearer ${admin}`, 'content-type': 'application/json' },
    body: JSON.stringify({ concurrency: 50, stock: 10 }),
  });
  const b = await r.json();
  assert.equal(r.status, 200, JSON.stringify(b));
  assert.equal(b.outcomes.ok, 10);
  assert.equal(b.outcomes.INSUFFICIENT_STOCK, 40);
  assert.equal(b.item.reserved, 10);
  assert.equal(b.passed, true);
});

test('a Member cannot approve (role on transition)', async t => {
  const req = (await submitted())[0];
  if (!req) return t.skip('no submitted requests; run pnpm seed');
  const r = await call(scMember, 'POST', SC, `/requests/${req.id}/transition`, { to: 'approved', idempotencyKey: `member-${Date.now()}` });
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'TRANSITION_NOT_ALLOWED');
});

test('stale ifVersion is refused', async t => {
  const req = (await submitted())[0];
  if (!req) return t.skip('no submitted requests; run pnpm seed');
  const r = await call(scManager, 'POST', SC, `/requests/${req.id}/transition`, { to: 'rejected', idempotencyKey: `stale-${Date.now()}`, ifVersion: req.row_version - 1 });
  assert.equal(r.status, 409);
  assert.equal(r.body.code, 'STALE_RECORD');
});

test('double-click approve is idempotent: one reservation only', async t => {
  const req = (await submitted())[0];
  if (!req) return t.skip('no submitted requests; run pnpm seed');
  const key = `dbl-${Date.now()}`;
  const [a, b] = await Promise.all([1, 2].map(() =>
    call(scManager, 'POST', SC, `/requests/${req.id}/transition`, { to: 'approved', idempotencyKey: key })));
  assert.deepEqual([a.status, b.status].sort(), [200, 201]);
  const tl = await call(scManager, 'GET', SC, `/requests/${req.id}/timeline`);
  assert.equal(tl.body.movements.filter((m: any) => m.kind === 'reserve').length, 1);
});
'@

W 'apps/web/src/renderer/kanban.tsx' @'
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import type { Page } from '@axel/compiler';
import { site, errOf, type ApiErr } from '../api';
import { useList, useSite, RANK } from '../hooks';
import { Cell, columnFields, Denial, labelOf, StateBadge, btn } from './fields';
import { RecordForm } from './RecordForm';

// Kanban grouped by workflow state. Dropping a card on a column runs the matching transition.
export function KanbanBoard({ page }: { page: Page }) {
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const qc = useQueryClient();
  const entity = page.entity!;
  const ent = schema.entities[entity];
  const wf = ent.workflow;
  const q = useList(siteId, entity);
  const [creating, setCreating] = useState(false);
  const [dragId, setDragId] = useState<string | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const [err, setErr] = useState<ApiErr | null>(null);
  const rows: any[] = q.data?.rows ?? [];
  const groupBy = page.groupBy ?? 'state';
  const states = wf?.states ?? [...new Set(rows.map(r => String(r[groupBy])))];
  const cols = columnFields(ent, page.columns);
  const canNew = RANK[schema.role] >= 1 && ent.fields.some(f => !f.readonly);
  const dragging = rows.find(r => r.id === dragId);
  const stepTo = (from: string, to: string) => wf?.transitions.find(t => t.from === from && t.to === to);

  const m = useMutation({
    mutationFn: ({ row, to }: { row: any; to: string }) => {
      const payload = to === 'assigned' ? { assigned_to: window.prompt('Assign to (name)') ?? '' } : undefined;
      return site.post(siteId, `/${entity}/${row.id}/transition`, { to, idempotencyKey: crypto.randomUUID(), ifVersion: row.row_version, payload });
    },
    onSuccess: () => { setErr(null); qc.invalidateQueries({ predicate: x => x.queryKey[1] === siteId }); },
    onError: e => setErr(errOf(e)),
  });

  function drop(col: string) {
    const row = dragging;
    setOver(null); setDragId(null);
    if (!row || String(row[groupBy]) === col) return;
    const t = stepTo(String(row[groupBy]), col);
    if (!t) return setErr({ message: `There is no step from '${row[groupBy]}' to '${col}' in this workflow.`, code: 'TRANSITION_NOT_ALLOWED' });
    if (!t.allowed) return setErr({ message: `Your role (${schema.role}) cannot ${t.label.toLowerCase()} here (transition ${t.id}).`, code: 'TRANSITION_NOT_ALLOWED' });
    m.mutate({ row, to: col });
  }

  return (
    <>
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">{page.title}</h1>
          <p className="text-xs text-slate-500">{q.data?.total ?? 0} records - drag cards between columns to move them through the workflow</p>
        </div>
        {canNew && <button onClick={() => setCreating(v => !v)} className={btn}>+ New</button>}
      </div>
      {creating && <RecordForm entity={entity} onDone={() => setCreating(false)} onCancel={() => setCreating(false)} />}
      {err && <Denial err={err} />}
      {q.isLoading && <div className="h-40 animate-pulse rounded-site bg-slate-200" />}
      {q.error && <Denial err={errOf(q.error)} />}
      {!q.isLoading && !q.error && (
        <div className="flex gap-3 overflow-x-auto pb-2">
          {states.map(s => {
            const inCol = rows.filter(r => String(r[groupBy]) === s);
            const t = dragging ? stepTo(String(dragging[groupBy]), s) : undefined;
            const ring = over === s ? (t?.allowed ? 'ring-2 ring-primary' : 'ring-2 ring-red-300') : dragging && t?.allowed ? 'ring-1 ring-primary/40' : '';
            return (
              <div key={s}
                onDragOver={e => { if (dragging) { e.preventDefault(); setOver(s); } }}
                onDragLeave={() => setOver(o => (o === s ? null : o))}
                onDrop={() => drop(s)}
                className={`w-72 shrink-0 rounded-site bg-slate-100 p-2 transition ${ring}`}>
                <div className="mb-2 flex items-center justify-between px-1">
                  <StateBadge state={s} />
                  <span className="text-xs text-slate-500">{inCol.length}</span>
                </div>
                <div className="min-h-12 space-y-2">
                  {inCol.map(r => (
                    <div key={r.id} draggable
                      onDragStart={() => { setErr(null); setDragId(r.id); }}
                      onDragEnd={() => { setDragId(null); setOver(null); }}
                      onClick={() => nav(`${base}/r/${entity}/${r.id}`)}
                      className={`cursor-grab rounded-site border-l-4 border-primary bg-white p-3 text-sm shadow-sm hover:shadow ${dragId === r.id ? 'opacity-40' : ''}`}>
                      <div className="font-medium">{labelOf(r)}</div>
                      {cols.slice(1).map(col => (
                        <div key={col.key} className="flex justify-between text-xs text-slate-500">
                          <span>{col.label}</span><span><Cell field={col} value={r[col.key]} /></span>
                        </div>
                      ))}
                    </div>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}
'@

W 'apps/web/src/renderer/RecordDetail.tsx' @'
import { useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { site, errOf, type ApiErr } from '../api';
import { useSite, RANK } from '../hooks';
import { Cell, Denial, StateBadge, labelOf, btn, btnGhost } from './fields';
import { RecordForm } from './RecordForm';

function StockBox({ id }: { id: string }) {
  const { siteId } = useSite();
  const qc = useQueryClient();
  const [qty, setQty] = useState('');
  const [err, setErr] = useState<ApiErr | null>(null);
  const m = useMutation({
    mutationFn: (kind: 'receive' | 'adjust') =>
      site.post(siteId, `/item/${id}/stock`, { kind, qty: Number(qty), idempotencyKey: crypto.randomUUID() }),
    onSuccess: () => { setQty(''); setErr(null); qc.invalidateQueries({ predicate: x => x.queryKey[1] === siteId }); },
    onError: e => setErr(errOf(e)),
  });
  return (
    <div className="space-y-2 rounded-site border bg-white p-4">
      <div className="text-sm font-medium">Stock movement (ledger)</div>
      <div className="flex gap-2">
        <input type="number" value={qty} onChange={e => setQty(e.target.value)} placeholder="Qty (negative to adjust down)" className="w-64 rounded-site border px-3 py-1.5 text-sm" />
        <button disabled={!qty || Number(qty) <= 0 || m.isPending} onClick={() => m.mutate('receive')} className={btn}>Receive</button>
        <button disabled={!qty || m.isPending} onClick={() => m.mutate('adjust')} className={btnGhost}>Adjust</button>
      </div>
      {err && <Denial err={err} />}
    </div>
  );
}

function EventLine({ e }: { e: any }) {
  const who = e.actor_name ? `${e.actor_name} (${e.actor_role})` : e.actor_role ?? 'system';
  switch (e.kind) {
    case 'create': return <span>Created by {who}</span>;
    case 'update': return <span>Edited by {who}</span>;
    case 'transition':
      return <span><b>{e.from_state}</b> &rarr; <b>{e.to_state}</b> by {who} <span className="font-mono text-xs text-slate-400">{e.transition_id}</span>{e.after?.assigned_to ? ` - assigned to ${e.after.assigned_to}` : ''}</span>;
    case 'reservation_expired':
      return <span className="text-amber-700">Reservation expired; {e.after?.released ?? ''} released. {e.to_state ? <>Back to <b>{e.to_state}</b> for re-approval.</> : null}</span>;
    default: return <span>{String(e.kind).replace(/_/g, ' ')} by {who}</span>;
  }
}

function MoveLine({ m }: { m: any }) {
  const sign = ({ receive: '+', return: '+', commit: '-', consume: '-', reserve: 'hold ', release: 'free ', adjust: '' } as Record<string, string>)[m.kind] ?? '';
  return (
    <span className="text-slate-600">
      Ledger: <b>{m.kind}</b> {sign}{m.qty}{m.reason ? ` (${m.reason})` : ''}
      {m.kind === 'reserve' && m.expires_at && !m.consumed_by ? ` - expires ${new Date(m.expires_at).toLocaleString()}` : ''}
    </span>
  );
}

function Timeline({ entity, id }: { entity: string; id: string }) {
  const { siteId } = useSite();
  const q = useQuery({ queryKey: [entity, siteId, 'timeline', id], queryFn: () => site.get(siteId, `/${entity}/${id}/timeline`), refetchInterval: 5000 });
  if (q.isLoading) return null;
  if (q.error) return <Denial err={errOf(q.error)} />;
  const items = [
    ...(q.data.events as any[]).map(e => ({ at: e.at, node: <EventLine e={e} /> })),
    ...(q.data.movements as any[]).map(m => ({ at: m.at, node: <MoveLine m={m} /> })),
  ].sort((a, b) => +new Date(a.at) - +new Date(b.at));
  return (
    <div className="rounded-site border bg-white p-4">
      <div className="mb-3 text-sm font-medium">Timeline</div>
      <ol className="space-y-3 border-l-2 border-primary/20 pl-4">
        {items.map((x, i) => (
          <li key={i} className="text-sm">
            {x.node}
            <div className="text-xs text-slate-400">{new Date(x.at).toLocaleString()}</div>
          </li>
        ))}
        {!items.length && <li className="text-sm text-slate-400">No history yet.</li>}
      </ol>
    </div>
  );
}

export function RecordDetail() {
  const { entity = '', id = '' } = useParams();
  const { siteId, schema } = useSite();
  const nav = useNavigate();
  const qc = useQueryClient();
  const ent = schema.entities[entity];
  const q = useQuery({ queryKey: [entity, siteId, 'one', id], queryFn: () => site.get(siteId, `/${entity}/${id}`), refetchInterval: 5000 });
  const [editing, setEditing] = useState(false);
  const [assignee, setAssignee] = useState('');
  const [err, setErr] = useState<ApiErr | null>(null);

  const tr = useMutation({
    mutationFn: (to: string) => site.post(siteId, `/${entity}/${id}/transition`, {
      to, idempotencyKey: crypto.randomUUID(), ifVersion: q.data?.row_version,
      payload: to === 'assigned' && assignee ? { assigned_to: assignee } : undefined,
    }),
    onSuccess: () => { setErr(null); qc.invalidateQueries({ predicate: x => x.queryKey[1] === siteId }); },
    onError: e => setErr(errOf(e)),
  });

  if (!ent) return <Denial err={{ message: 'This site has no such record type.' }} />;
  if (q.isLoading) return <div className="h-40 animate-pulse rounded-site bg-slate-200" />;
  if (q.error) return <Denial err={errOf(q.error)} />;
  const rec = q.data;
  const canEdit = ent.fields.some(f => !f.readonly);
  const transitions: any[] = rec.transitions ?? [];

  return (
    <div className="grid max-w-6xl gap-4 lg:grid-cols-[1fr_380px]">
      <div className="space-y-4">
        <button onClick={() => nav(-1)} className="text-sm text-slate-500 hover:text-slate-900">&lt; Back</button>
        <div className="flex items-start justify-between">
          <div>
            <div className="text-xs uppercase text-slate-400">{ent.label}</div>
            <h1 className="text-xl font-semibold">{labelOf(rec)}</h1>
            <div className="mt-1 flex items-center gap-2 text-xs text-slate-500">
              {rec.state && <StateBadge state={rec.state} />}<span>v{rec.row_version}</span>
            </div>
          </div>
          {canEdit && !editing && <button onClick={() => setEditing(true)} className={btnGhost}>Edit</button>}
        </div>

        {editing ? (
          <RecordForm entity={entity} initial={rec} onDone={() => setEditing(false)} onCancel={() => setEditing(false)} />
        ) : (
          <dl className="grid grid-cols-2 gap-x-6 gap-y-3 rounded-site border bg-white p-4 text-sm">
            {ent.fields.map(f => (
              <div key={f.key}>
                <dt className="text-xs text-slate-400">{f.label}</dt>
                <dd><Cell field={f} value={rec[f.key]} /></dd>
              </div>
            ))}
          </dl>
        )}

        {!!transitions.length && (
          <div className="space-y-2 rounded-site border bg-white p-4">
            <div className="text-sm font-medium">Next steps</div>
            {transitions.some(t => t.to === 'assigned' && t.allowed) && (
              <input value={assignee} onChange={e => setAssignee(e.target.value)} placeholder="Assign to (name)" className="w-64 rounded-site border px-3 py-1.5 text-sm" />
            )}
            <div className="flex flex-wrap gap-2">
              {transitions.map(t => (
                <button key={t.id} disabled={!t.allowed || tr.isPending} title={t.reason} onClick={() => tr.mutate(t.to)}
                  className={t.allowed ? btn : `${btnGhost} cursor-not-allowed`}>{t.label}</button>
              ))}
            </div>
            {transitions.filter(t => !t.allowed).map(t => <div key={t.id} className="text-xs text-slate-500">{t.reason}</div>)}
          </div>
        )}
        {err && <Denial err={err} />}
        {entity === 'item' && RANK[schema.role] >= 2 && <StockBox id={id} />}
      </div>
      <Timeline entity={entity} id={id} />
    </div>
  );
}
'@

W 'apps/web/src/pages/Chaos.tsx' @'
import { useState } from 'react';
import { useMutation } from '@tanstack/react-query';
import { http, errOf } from '../api';

export function ChaosCard() {
  const [res, setRes] = useState<any>(null);
  const [err, setErr] = useState('');
  const m = useMutation({
    mutationFn: () => http.post('/hub/chaos', { concurrency: 50, stock: 10 }).then(r => r.data),
    onSuccess: d => { setErr(''); setRes(d); },
    onError: e => setErr(errOf(e).message),
  });
  return (
    <div className="rounded-xl border bg-white p-5">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-xs font-medium uppercase text-slate-400">Chaos test</div>
          <div className="text-sm text-slate-600">Fire 50 concurrent approvals at an item with 10 in stock. Exactly 10 may succeed.</div>
        </div>
        <button onClick={() => m.mutate()} disabled={m.isPending} className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">
          {m.isPending ? 'Running...' : 'Run chaos'}
        </button>
      </div>
      {err && <div className="mt-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
      {res && (
        <div className="mt-4 grid gap-3 sm:grid-cols-4">
          <div className={`rounded-lg p-3 text-center ${res.passed ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-800'}`}>
            <div className="text-2xl font-bold">{res.passed ? 'PASS' : 'FAIL'}</div>
            <div className="text-xs">{res.site} - {res.durationMs} ms</div>
          </div>
          <div className="rounded-lg bg-slate-50 p-3 text-sm">
            <div className="text-xs text-slate-400">Outcomes</div>
            {Object.entries(res.outcomes).map(([k, v]) => <div key={k}>{k}: <b>{String(v)}</b></div>)}
          </div>
          <div className="rounded-lg bg-slate-50 p-3 text-sm">
            <div className="text-xs text-slate-400">Item after</div>
            <div>on hand: <b>{res.item.on_hand}</b></div>
            <div>reserved: <b>{res.item.reserved}</b></div>
          </div>
          <div className="rounded-lg bg-slate-50 p-3 text-sm">
            <div className="text-xs text-slate-400">Ledger recomputed</div>
            <div>on hand: <b>{res.ledger.on_hand}</b></div>
            <div>reserved: <b>{res.ledger.reserved}</b></div>
            <div>reserve rows: <b>{res.reserveMovements}</b></div>
          </div>
        </div>
      )}
    </div>
  );
}
'@

Write-Host ''
Write-Host 'Batch 3 done. Next: pnpm migrate, pnpm seed, restart pnpm dev:api, then pnpm test:workflow'

