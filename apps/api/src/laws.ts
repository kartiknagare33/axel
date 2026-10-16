import { compile, staticLaws, type Blueprint, type LawCheck, type Role } from '@axel/compiler';
import { pool, type Tx, type SiteCtx } from './db';
import { runTransition } from './workflow';
import * as ledger from './ledger';

export interface Step { i: number; text: string; outcome: string }
export interface GateReport {
  passed: boolean; seed: number; steps: number; durationMs: number;
  compileErrors: string[]; laws: LawCheck[];
  stats: { allowed: number; refused: number; skipped: number };
  counterExample?: { lawId: string; sentence: string; atStep: number; message: string; trace: Step[] };
  sample: Step[];
}

const BUSINESS = ['items', 'stock_movements', 'requests', 'approvals', 'assignments', 'consumptions', 'returns', 'repairs', 'audit_events', 'memberships', 'site_versions', 'site_deployments'];

function mulberry32(a: number) {
  return () => {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Dynamic Law checks, run against the sandbox transaction after every step.
async function checkLaw(c: Tx, law: LawCheck, raw: any): Promise<string | null> {
  switch (law.template) {
    case 'non_negative': {
      const r = (await c.query('SELECT name, on_hand FROM items WHERE on_hand < 0 LIMIT 1')).rows[0];
      return r ? `${r.name} has on-hand ${r.on_hand}.` : null;
    }
    case 'reserved_le_on_hand': {
      const r = (await c.query('SELECT name, on_hand, reserved FROM items WHERE reserved > on_hand LIMIT 1')).rows[0];
      return r ? `${r.name}: reserved ${r.reserved} is more than on-hand ${r.on_hand}.` : null;
    }
    case 'ledger_balanced': {
      const r = (await c.query(
        `SELECT i.name, i.on_hand, i.reserved, coalesce(b.on_hand, 0) AS l_on, coalesce(b.reserved, 0) AS l_res
           FROM items i LEFT JOIN v_ledger_balance b ON b.item_id = i.id
          WHERE coalesce(b.on_hand, 0) <> i.on_hand OR coalesce(b.reserved, 0) <> i.reserved LIMIT 1`)).rows[0];
      return r ? `${r.name} shows on-hand ${r.on_hand} / reserved ${r.reserved}, but the ledger adds up to ${r.l_on} / ${r.l_res}.` : null;
    }
    case 'requires_state': {
      if (raw?.entity !== 'assignment') return null;
      const r = (await c.query(
        `SELECT a.id, r.state FROM assignments a JOIN requests r ON r.id = a.request_id
          WHERE NOT EXISTS (SELECT 1 FROM audit_events e WHERE e.entity = 'request' AND e.record_id = r.id
                              AND e.kind = 'transition' AND e.to_state = $1) LIMIT 1`, [raw.state])).rows[0];
      return r ? `Assignment ${String(r.id).slice(0, 8)} was created for a request that never became '${raw.state}' (it is now '${r.state}').` : null;
    }
    case 'site_isolation': {
      const r = (await c.query(
        `SELECT relname FROM pg_class WHERE relname = ANY($1) AND relkind = 'r' AND NOT (relrowsecurity AND relforcerowsecurity) LIMIT 1`,
        [BUSINESS])).rows[0];
      return r ? `Row-level security is not forced on ${r.relname}.` : null;
    }
    default: return null;
  }
}

/** The Release Gate: compile, static Laws, then a seeded random walk inside a transaction that is always rolled back. */
export async function runGate(siteId: string, userId: string, versionId: string, bp: Blueprint, opts: { steps: number; seed?: number }): Promise<GateReport> {
  const started = Date.now();
  const seed = opts.seed ?? Math.floor(Math.random() * 2147483647);
  const rand = mulberry32(seed);
  const pick = <T,>(a: T[]): T => a[Math.floor(rand() * a.length)];
  const compiled = compile(bp);
  const compileErrors = compiled.diagnostics.filter(d => d.severity === 'error').map(d => d.message);
  const laws = staticLaws(bp);
  const raw = new Map<string, any>(bp.laws.map(l => [l.id, l]));
  const stats = { allowed: 0, refused: 0, skipped: 0 };
  const sample: Step[] = [];
  const trace: Step[] = [];
  let counterExample: GateReport['counterExample'];
  let done = 0;

  const finish = (): GateReport => {
    for (const l of laws) if (l.dynamic && l.passed && done > 0) l.detail = `Held after each of ${done} steps.`;
    const passed = !compileErrors.length && laws.every(l => l.passed) && !counterExample;
    return { passed, seed, steps: done, durationMs: Date.now() - started, compileErrors, laws, stats, counterExample, sample };
  };
  if (compileErrors.length || laws.some(l => !l.passed)) return finish();

  const dynamic = laws.filter(l => l.dynamic);
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    const setCtx = (role: string) => c.query(
      `SELECT set_config('app.site_id',$1,true), set_config('app.user_id',$2,true), set_config('app.role',$3,true)`, [siteId, userId, role]);
    const ctx = (role: Role): SiteCtx & { role: Role } => ({ siteId, userId, role, versionId });
    const check = async (i: number) => {
      for (const l of dynamic) {
        const why = await checkLaw(c, l, raw.get(l.id));
        if (!why) continue;
        l.passed = false; l.detail = why;
        counterExample = {
          lawId: l.id, sentence: l.sentence, atStep: i, trace: [...trace],
          message: i === 0 ? `The live data already breaks this Law before any step: ${why}` : `Law ${l.id} broken at step ${i}: ${why}`,
        };
        return true;
      }
      return false;
    };
    await setCtx('Admin');
    if (await check(0)) return finish();

    // Fixtures: a few items with random stock and fresh requests, on top of the site's real records.
    const items: string[] = [];
    if (bp.entities.item) {
      for (let k = 0; k < 4; k++) {
        const id = (await c.query(`INSERT INTO items (site_id, name, on_hand, data) VALUES ($1,$2,0,$3) RETURNING id`,
          [siteId, `Gate item ${k + 1}`, { sku: `GATE-${seed}-${k}` }])).rows[0].id;
        const q = Math.floor(rand() * 12);
        if (q > 0) await ledger.move(c, ctx('Admin'), { itemId: id, kind: 'receive', qty: q, key: `gate-${seed}-recv-${k}` });
        items.push(id);
      }
    }
    const wf = bp.workflows.request;
    const reqs: string[] = [];
    if (wf && bp.entities.request && items.length) {
      for (let k = 0; k < 8; k++)
        reqs.push((await c.query(
          `INSERT INTO requests (site_id, item_id, qty, state, requested_by, data) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
          [siteId, pick(items), 1 + Math.floor(rand() * 6), wf.initial, userId, { fault: 'gate', site_location: 'gate', note: 'gate' }])).rows[0].id);
      reqs.push(...(await c.query('SELECT id FROM requests WHERE NOT (id = ANY($1)) ORDER BY created_at DESC LIMIT 12', [reqs])).rows.map(r => r.id));
    }
    const roles: Role[] = ['Member', 'Manager', 'Admin'];

    for (let i = 1; i <= opts.steps; i++) {
      const roll = rand();
      let text = '';
      let outcome = '';
      await c.query('SAVEPOINT gate_step');
      try {
        if (reqs.length && roll < 0.75) {
          const id = pick(reqs);
          const cur = (await c.query('SELECT state FROM requests WHERE id = $1', [id])).rows[0];
          const options = wf!.transitions.filter(t => t.from === cur?.state);
          if (!cur || !options.length) { text = `request ${id.slice(0, 6)} is '${cur?.state}', nothing to do`; outcome = 'skipped'; }
          else {
            const t = pick(options);
            const role = pick(roles);
            text = `${role}: ${t.label ?? t.to} request ${id.slice(0, 6)} (${t.from} > ${t.to})`;
            await setCtx(role);
            await runTransition(c, ctx(role), compiled, bp.name, 'request', id, {
              to: t.to, idempotencyKey: `gate-${seed}-${i}`, payload: t.to === 'assigned' ? { assigned_to: 'gate' } : undefined,
            });
            await setCtx('Admin');
            outcome = 'allowed';
          }
        } else if (items.length && roll < 0.9) {
          const id = pick(items);
          const q = 1 + Math.floor(rand() * 8);
          const up = rand() < 0.5;
          text = `Manager: ${up ? 'receive' : 'adjust down'} ${q} on a gate item`;
          await ledger.move(c, ctx('Manager'), { itemId: id, kind: up ? 'receive' : 'adjust', qty: up ? q : -q, key: `gate-${seed}-${i}` });
          outcome = 'allowed';
        } else {
          text = 'probe: read this site as a different site';
          const other = `00000000-0000-4000-8000-${String(Math.floor(rand() * 1e12)).padStart(12, '0')}`;
          await c.query(`SELECT set_config('app.site_id', $1, true)`, [other]);
          const n = Number((await c.query('SELECT (SELECT count(*) FROM items) + (SELECT count(*) FROM requests) AS n')).rows[0].n);
          await setCtx('Admin');
          outcome = n === 0 ? 'isolated' : `LEAK: ${n} rows`;
          if (n > 0) {
            const iso = laws.find(l => l.template === 'site_isolation');
            if (iso) { iso.passed = false; iso.detail = `A different site context could read ${n} rows.`; }
            counterExample = { lawId: iso?.id ?? 'l0', sentence: iso?.sentence ?? 'Site isolation', atStep: i, message: `Isolation broken at step ${i}.`, trace: [...trace] };
          }
        }
        await c.query('RELEASE SAVEPOINT gate_step');
      } catch (e: any) {
        await c.query('ROLLBACK TO SAVEPOINT gate_step');
        await setCtx('Admin');
        outcome = `refused (${e?.code ?? 'error'})`;
      }
      if (outcome === 'allowed') stats.allowed++;
      else if (outcome === 'skipped') stats.skipped++;
      else if (outcome.startsWith('refused')) stats.refused++;
      const step = { i, text, outcome };
      trace.push(step);
      if (trace.length > 8) trace.shift();
      if (sample.length < 15) sample.push(step);
      done = i;
      if (counterExample) { counterExample.trace = [...trace]; break; }
      if (await check(i)) break;
    }
  } finally {
    await c.query('ROLLBACK').catch(() => {});
    c.release();
  }
  return finish();
}
