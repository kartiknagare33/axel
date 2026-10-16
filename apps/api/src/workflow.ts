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
