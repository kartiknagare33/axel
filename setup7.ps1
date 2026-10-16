# Axel - batch 7 (Release Gate, Laws, random-walk proof, counter-examples). Run from the axel folder.
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

# ============================== PATCHES: scripts, compiler, server ==============================
Patch 'package.json' @'
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel && pnpm test:api"
'@ @'
    "test:gate": "pnpm --filter @axel/api test:gate",
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel && pnpm test:api && pnpm test:gate"
'@

Patch 'apps/api/package.json' @'
    "test:api": "tsx --env-file=../../.env --test test/api.test.ts",
'@ @'
    "test:api": "tsx --env-file=../../.env --test test/api.test.ts",
    "test:gate": "tsx --env-file=../../.env --test test/gate.test.ts",
'@

Patch 'packages/compiler/src/index.ts' @'
export * from './presets';
'@ @'
export * from './presets';
export * from './laws';
'@

Patch 'apps/api/src/server.ts' @'
import { aliases } from './aliases';
'@ @'
import { aliases } from './aliases';
import { gateRouter } from './gate';
'@

Patch 'apps/api/src/server.ts' @'
requireRole('Admin'), versionsRouter);
'@ @'
requireRole('Admin'), versionsRouter, gateRouter);
'@

# versions.ts: publish needs a passing gate for this exact Blueprint; rollback runs a short gate
Patch 'apps/api/src/versions.ts' @'
import { invalidate } from './blueprints';
'@ @'
import { invalidate } from './blueprints';
import { runGate } from './laws';
'@

Patch 'apps/api/src/versions.ts' @'
async function deploy(req: any, c: Tx, targetId: string, o: { rollback: boolean; confirm: boolean; reason?: string }) {
'@ @'
async function deploy(req: any, c: Tx, targetId: string, o: { rollback: boolean; confirm: boolean; reason?: string; gate?: any }) {
'@

Patch 'apps/api/src/versions.ts' @'
  if (errors.length) throw new AxelError('GATE_NOT_PASSED', 422, `Fix ${errors.length} problem(s) first: ${errors[0].message}`, { diagnostics: errors });
'@ @'
  if (errors.length) throw new AxelError('GATE_NOT_PASSED', 422, `Fix ${errors.length} problem(s) first: ${errors[0].message}`, { diagnostics: errors });
  let gateProof: any = o.gate ?? null;
  if (!o.rollback) {
    const g = (await c.query(
      'SELECT passed, seed, steps, duration_ms FROM law_runs WHERE version_id = $1 AND content_hash = $2 ORDER BY ran_at DESC LIMIT 1',
      [v.id, hashBlueprint(bp)])).rows[0];
    if (!g?.passed) throw new AxelError('GATE_NOT_PASSED', 422, g
      ? 'The last Release Gate run on this draft failed. Fix the problem and run the gate again.'
      : 'Run the Release Gate on this draft before publishing.');
    gateProof = { passed: true, steps: g.steps, seed: Number(g.seed), durationMs: g.duration_ms };
  }
'@

Patch 'apps/api/src/versions.ts' @'
    changes, destructive, dataPreserved: true, kind: o.rollback ? 'rollback' : 'publish',
'@ @'
    changes, destructive, dataPreserved: true, kind: o.rollback ? 'rollback' : 'publish', gate: gateProof,
'@

Patch 'apps/api/src/versions.ts' @'
  const b = z.object({ versionId: z.string().uuid(), confirm: z.boolean().default(false) }).parse(req.body);
  const r = await withSite(req.site!.ctx, c => deploy(req, c, b.versionId, { rollback: true, confirm: b.confirm }));
'@ @'
  const b = z.object({ versionId: z.string().uuid(), confirm: z.boolean().default(false) }).parse(req.body);
  const s = req.site!;
  const target = await withSite(s.ctx, async c => (await c.query('SELECT config FROM site_versions WHERE id = $1', [b.versionId])).rows[0]);
  if (!target) throw notFound();
  const report = await runGate(s.siteId, s.ctx.userId, b.versionId, pin(req, target.config), { steps: 150 });
  if (!report.passed && !b.confirm)
    throw new AxelError('GATE_NOT_PASSED', 422,
      `That older version breaks a Law: ${report.counterExample?.message ?? report.laws.find(l => !l.passed)?.detail ?? report.compileErrors[0] ?? 'see the gate report'}`, { report });
  const gate = { passed: report.passed, steps: report.steps, seed: report.seed, durationMs: report.durationMs };
  const r = await withSite(s.ctx, c => deploy(req, c, b.versionId, { rollback: true, confirm: b.confirm, gate }));
'@

# ============================== PATCHES: builder UI ==============================
Patch 'apps/web/src/builder/Builder.tsx' @'
import { http, errOf } from '../api';
'@ @'
import { http, errOf } from '../api';
import { GatePanel } from './GatePanel';
import { LawsPanel, RoleToggle } from './LawsPanel';
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
  const [tab, setTab] = useState<'problems' | 'module' | 'theme' | 'json' | 'versions'>('problems');
'@ @'
  const [tab, setTab] = useState<'problems' | 'module' | 'laws' | 'gate' | 'theme' | 'json' | 'versions'>('problems');
  const [gate, setGate] = useState<any>(null);
  const [gating, setGating] = useState(false);
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
  async function publish(confirm = false) {
    const id = dirty || !draft ? await save() : draft.id;
    if (!id) return;
    setBusy(true);
'@ @'
  async function runGate(steps = 300, versionId?: string) {
    const id = versionId ?? (dirty || !draft ? await save() : draft.id);
    if (!id) return null;
    setTab('gate'); setGating(true); setGate(null);
    try {
      const r = await http.post(`/sites/${siteId}/versions/${id}/gate`, { steps }, H);
      setGate(r.data);
      return r.data;
    } catch (e) { setMsg({ kind: 'err', text: errOf(e).message }); return null; }
    finally { setGating(false); }
  }

  async function publish(confirm = false) {
    const id = dirty || !draft ? await save() : draft.id;
    if (!id) return;
    if (!confirm) {
      const g = await runGate(300, id);
      if (!g?.passed) { setMsg({ kind: 'err', text: 'The Release Gate blocked this draft, so nothing was published. See the Gate tab.' }); return; }
    }
    setBusy(true);
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
          <button onClick={() => publish()} disabled={busy || !!errors.length || (!dirty && !draft)} className={btn}
'@ @'
          <button onClick={() => runGate()} disabled={busy || gating || !!errors.length} className={ghost}>Run gate</button>
          <button onClick={() => publish()} disabled={busy || !!errors.length || (!dirty && !draft)} className={btn}
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
          <nav className="flex border-b text-sm">
'@ @'
          <nav className="flex border-b text-xs">
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
['module', 'Module'], ['theme', 'Theme'],
'@ @'
['module', 'Module'], ['laws', 'Laws'], ['gate', 'Gate'], ['theme', 'Theme'],
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
            {tab === 'theme' && <ThemePanel bp={bp} update={update} />}
'@ @'
            {tab === 'laws' && <LawsPanel bp={bp} update={update} />}
            {tab === 'gate' && <GatePanel gate={gate} gating={gating} onRun={steps => runGate(steps)} />}
            {tab === 'theme' && <ThemePanel bp={bp} update={update} />}
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
            <span><span className="font-mono">{x.key}</span> <span className="text-slate-400">{x.type}{x.expr ? ` = ${x.expr}` : ''}{x.roles?.read ? ` - visible to ${x.roles.read.join(', ')}` : ''}</span></span>
'@ @'
            <span><span className="font-mono">{x.key}</span> <span className="text-slate-400">{x.type}{x.expr ? ` = ${x.expr}` : ''}{x.roles?.read ? ` - visible to ${x.roles.read.join(', ')}` : ''}</span></span>
            <RoleToggle bp={bp} entity={entity} field={x} update={update} />
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
      if (er.code === 'DESTRUCTIVE_CHANGE_UNPLANNED') onChanged(
'@ @'
      if (er.code === 'DESTRUCTIVE_CHANGE_UNPLANNED' || er.code === 'GATE_NOT_PASSED') onChanged(
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
          {!!d.proof?.changes?.length && <ul
'@ @'
          {d.proof?.gate && <div className="text-xs text-emerald-700">Release Gate: {d.proof.gate.passed ? 'passed' : 'overridden'}, {d.proof.gate.steps} steps, seed {d.proof.gate.seed}</div>}
          {!!d.proof?.changes?.length && <ul
'@

# ============================== PATCHES: docs ==============================
Patch 'README.md' @'
## Quick start
'@ @'
## Release Gate and Laws

Nothing is published without evidence. Each site declares **Laws** as plain sentences, for example "Members never see Unit price", "Every Assignment comes from a request that was approved", "Reserved stock never exceeds on-hand stock". Before a draft goes live, the **Release Gate**:

1. compiles the Blueprint (zero errors allowed);
2. checks each Law against the Blueprint itself (for example, a calculated field that would reveal a hidden price);
3. performs hundreds of random actions as Members, Managers and Admins on the site's real data, inside a transaction that is always rolled back, and checks every Law after each step.

If a Law breaks, publish is blocked and the builder shows the counter-example: the exact steps that broke it, with a seed to replay. The proof (steps, seed, duration) is stored on every deployment; rollbacks run a short gate too.

## Quick start
'@

Patch 'README.md' @'
| `test:api` (4) | Every brief endpoint works for its site and refuses other sites |
'@ @'
| `test:api` (4) | Every brief endpoint works for its site and refuses other sites |
| `test:gate` (4) | Unchanged sites pass the gate, a leaked price is blocked by a Law, a shortcut that skips approval is caught with a counter-example, publishing without a passing gate is refused |
'@

Patch 'README.md' @'
Run with Axel started: `pnpm test` (23 tests).
'@ @'
Run with Axel started: `pnpm test` (27 tests).
'@

Patch 'README.md' @'
404-not-403 for other sites. 23 automated tests.
'@ @'
404-not-403 for other sites. 27 automated tests.
'@

Patch 'README.md' @'
The Blueprint and compiler are designed for these next steps: a Release Gate that runs declared Laws as property-based tests before publish, a Replay Report that runs real history through a proposed version, and a Sheet Inferencer that derives a site from a unit's existing spreadsheets.
'@ @'
Built: the Release Gate with Laws (above). Next: a Replay Report that runs real history through a proposed version, and a Sheet Inferencer that derives a site from a unit's existing spreadsheets.
'@

Patch 'docs/API.md' @'
| GET | `/api/sites/:siteId/deployments` | history with proof records |
'@ @'
| GET | `/api/sites/:siteId/deployments` | history with proof records |
| POST | `/api/sites/:siteId/versions/:v/gate` | `{ steps?, seed? }` runs the Release Gate; returns Laws, counter-example and a sample of the walk. Publish requires a passing run for the exact Blueprint. |
'@

Patch 'docs/DEMO_SCRIPT.md' @'
## Brief step 4: Excel with role rules (1.5 min)
'@ @'
## The Release Gate (1.5 min)

- Central Stores builder: click the **Inventory** node. On **unit_price**, click **Member: hidden** so it says **Member: sees**.
- Click **Run gate**: **BLOCKED**, "Law l3: Members never see Unit price". Click **Undo**, run again: **PASSED**.
- Distribution builder, **JSON** tab: inside `"transitions"` of `request`, add
  `{ "id": "t99", "from": "submitted", "to": "assigned", "label": "Fast-track", "roles": ["Manager", "Admin"] },`
  then **Apply JSON**, **Gate** tab, choose **1000 steps**, **Run gate**: BLOCKED with a counter-example such as "Law l2 broken at step 37: Assignment ... was created for a request that never became 'approved'", and the steps that led there.
- Undo or Discard.

*Say:* "Nobody tests by hand. The gate acts out hundreds of random sessions on real data, rolls everything back, and refuses to publish anything that breaks a rule."

## Brief step 4: Excel with role rules (1.5 min)
'@

# ============================== NEW FILES ==============================
W 'apps/api/migrations/003_gate.sql' @'
ALTER TABLE law_runs ADD COLUMN content_hash text;
ALTER TABLE law_runs ADD COLUMN report jsonb NOT NULL DEFAULT '{}';
CREATE INDEX ix_law_runs_version ON law_runs (site_id, version_id, ran_at DESC);
'@

W 'packages/compiler/src/laws.ts' @'
import type { Blueprint, Field, Law } from './types';
import { parse, refs } from './expr';

export const LAW_TEMPLATES: { id: string; label: string }[] = [
  { id: 'hidden_from', label: 'A role never sees a field' },
  { id: 'requires_state', label: 'Assignments only come from requests in a state' },
  { id: 'reachable', label: 'A workflow state can be reached' },
  { id: 'non_negative', label: 'On-hand stock never goes below zero' },
  { id: 'reserved_le_on_hand', label: 'Reserved stock never exceeds on-hand' },
];

const entLabel = (bp: Blueprint, e: string) => bp.entities[e]?.label ?? e;
const fieldLabel = (bp: Blueprint, e: string, k: string) => bp.entities[e]?.fields.find(f => f.key === k)?.label ?? k;

export function lawSentence(l: Law, bp: Blueprint): string {
  const e = String(l.entity ?? '');
  switch (l.template) {
    case 'site_isolation': return `${bp.name || 'This site'} never reads or writes another site's data`;
    case 'non_negative': return `${fieldLabel(bp, e, String(l.field))} of ${entLabel(bp, e)} never goes below zero`;
    case 'reserved_le_on_hand': return 'Reserved stock never exceeds on-hand stock';
    case 'ledger_balanced': return 'Stock figures always equal the sum of the stock ledger';
    case 'requires_state': return `Every ${entLabel(bp, e)} comes from a request that was ${l.state}`;
    case 'hidden_from': return `${l.role}s never see ${fieldLabel(bp, e, String(l.field))} (${entLabel(bp, e)})`;
    case 'reachable': return `'${l.state}' can be reached in the ${l.workflow ?? 'request'} workflow`;
    default: return l.template;
  }
}

export interface LawCheck { id: string; template: string; sentence: string; passed: boolean; dynamic: boolean; detail?: string }

/** Checks every Law that can be decided from the Blueprint alone; marks the rest as dynamic (checked by the gate's walk). */
export function staticLaws(bp: Blueprint): LawCheck[] {
  const laws: Law[] = [...bp.laws];
  if (bp.entities.item && !laws.some(l => l.template === 'ledger_balanced')) laws.push({ id: 'l-ledger', template: 'ledger_balanced', locked: true });
  return laws.map(l => {
    const base = { id: l.id, template: l.template, sentence: lawSentence(l, bp) };
    const e = String(l.entity ?? '');
    switch (l.template) {
      case 'hidden_from': {
        const ent = bp.entities[e];
        const role = String(l.role);
        const f = ent?.fields.find(x => x.key === l.field);
        if (!ent || !f) return { ...base, passed: false, dynamic: false, detail: `There is no field '${l.field}' on '${e}'.` };
        const sees = (x: Field) => !x.roles?.read || (x.roles.read as string[]).includes(role);
        if (sees(f)) return { ...base, passed: false, dynamic: false, detail: `${role}s can currently see ${f.label ?? f.key}.` };
        const leak = ent.fields.find(x => {
          if (x.type !== 'formula' || !x.expr || !sees(x)) return false;
          try { return refs(parse(x.expr)).fields.has(f.key); } catch { return false; }
        });
        if (leak) return { ...base, passed: false, dynamic: false, detail: `${leak.label ?? leak.key} (= ${leak.expr}) is visible to ${role}s and reveals ${f.label ?? f.key}.` };
        return { ...base, passed: true, dynamic: false, detail: `${role}s cannot read it, and no visible calculated field reveals it.` };
      }
      case 'reachable': {
        const wf = bp.workflows[String(l.workflow ?? 'request')];
        if (!wf) return { ...base, passed: false, dynamic: false, detail: 'That workflow does not exist.' };
        const seen = new Set([wf.initial]);
        const q = [wf.initial];
        while (q.length) {
          const s = q.shift()!;
          for (const t of wf.transitions) if (t.from === s && !seen.has(t.to)) { seen.add(t.to); q.push(t.to); }
        }
        return seen.has(String(l.state))
          ? { ...base, passed: true, dynamic: false, detail: 'A path exists from the first state.' }
          : { ...base, passed: false, dynamic: false, detail: `No sequence of steps leads from '${wf.initial}' to '${l.state}'.` };
      }
      case 'requires_state': {
        if (!bp.entities[e]) return { ...base, passed: true, dynamic: false, detail: `Not active: this site has no ${e}.` };
        if (!bp.workflows.request?.states.includes(String(l.state)))
          return { ...base, passed: false, dynamic: false, detail: `The request workflow has no '${l.state}' state.` };
        return { ...base, passed: true, dynamic: true };
      }
      default:
        return { ...base, passed: true, dynamic: true };
    }
  });
}
'@

W 'apps/api/src/laws.ts' @'
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
'@

W 'apps/api/src/gate.ts' @'
import { Router } from 'express';
import { z } from 'zod';
import { withSite, UUID } from './db';
import { ah, notFound } from './errors';
import { hashBlueprint } from './sites';
import { runGate } from './laws';

// Mounted at /api/sites/:siteId (Admin only).
export const gateRouter = Router({ mergeParams: true });

gateRouter.post('/versions/:v/gate', ah(async (req, res) => {
  if (!UUID.test(req.params.v)) throw notFound();
  const b = z.object({ steps: z.number().int().min(20).max(3000).default(300), seed: z.number().int().optional() }).parse(req.body ?? {});
  const s = req.site!;
  const v = await withSite(s.ctx, async c => (await c.query('SELECT id, config FROM site_versions WHERE id = $1', [req.params.v])).rows[0]);
  if (!v) throw notFound();
  const bp = { ...v.config, siteId: s.siteId, slug: s.slug };
  const report = await runGate(s.siteId, s.ctx.userId, v.id, bp, { steps: b.steps, seed: b.seed });
  const hash = hashBlueprint(bp);
  await withSite(s.ctx, c => c.query(
    `INSERT INTO law_runs (site_id, version_id, seed, steps, passed, failures, duration_ms, content_hash, report)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
    [s.siteId, v.id, report.seed, report.steps, report.passed, JSON.stringify(report.laws.filter(l => !l.passed)), report.durationMs, hash, report]));
  res.json({ ...report, versionHash: hash });
}));
'@

W 'apps/api/test/gate.test.ts' @'
import { test, before } from 'node:test';
import assert from 'node:assert/strict';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const SC = '22222222-2222-4222-8222-222222222222';
const DS = '33333333-3333-4333-8333-333333333333';

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  assert.equal(r.status, 200);
  return (await r.json()).token as string;
}
let admin = '';
async function call(method: string, path: string, site: string, body?: unknown) {
  const r = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${admin}`, 'x-site-id': site, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}
async function withDraft(site: string, mutate: (bp: any) => void, fn: (id: string) => Promise<void>) {
  const b = await call('GET', `/sites/${site}/builder`, site);
  assert.equal(b.status, 200);
  const bp = structuredClone(b.body.published.config);
  mutate(bp);
  const d = await call('POST', `/sites/${site}/versions`, site, { config: bp, reason: 'gate test' });
  assert.equal(d.status, 201, JSON.stringify(d.body));
  try { await fn(d.body.id); } finally { await call('DELETE', `/sites/${site}/versions/${d.body.id}`, site); }
}

before(async () => { admin = await login('admin@axel.dev'); });

test('an unchanged site passes the gate', () => withDraft(DS, () => {}, async id => {
  const g = await call('POST', `/sites/${DS}/versions/${id}/gate`, DS, { steps: 200, seed: 42 });
  assert.equal(g.status, 200);
  assert.equal(g.body.passed, true, JSON.stringify(g.body.counterExample ?? g.body.laws.filter((l: any) => !l.passed)));
}));

test('making unit price visible to Members is blocked by a Law', () => withDraft(SC, bp => {
  bp.entities.request.fields.find((f: any) => f.key === 'unit_price').roles.read.push('Member');
}, async id => {
  const g = await call('POST', `/sites/${SC}/versions/${id}/gate`, SC, { steps: 50 });
  assert.equal(g.body.passed, false);
  assert.ok(g.body.laws.some((l: any) => l.template === 'hidden_from' && !l.passed));
}));

test('a shortcut that skips approval is caught with a counter-example', () => withDraft(DS, bp => {
  bp.workflows.request.transitions.push({ id: 't99', from: 'submitted', to: 'assigned', label: 'Fast-track', roles: ['Manager', 'Admin'] });
}, async id => {
  const g = await call('POST', `/sites/${DS}/versions/${id}/gate`, DS, { steps: 1500, seed: 7 });
  assert.equal(g.body.passed, false, 'gate should block the shortcut');
  assert.equal(g.body.counterExample?.lawId, 'l2', JSON.stringify(g.body.counterExample));
  assert.ok(g.body.counterExample.trace.length > 0);
}));

test('publishing without a passing gate is refused', () => withDraft(DS, bp => { bp.theme.tokens.primary = '#123456'; }, async id => {
  const p = await call('POST', `/sites/${DS}/publish`, DS, { versionId: id });
  assert.equal(p.status, 422);
  assert.equal(p.body.code, 'GATE_NOT_PASSED');
}));
'@

W 'apps/web/src/builder/GatePanel.tsx' @'
import { useState } from 'react';

export function GatePanel({ gate, gating, onRun }: { gate: any; gating: boolean; onRun: (steps: number) => void }) {
  const [steps, setSteps] = useState(300);
  return (
    <div className="space-y-4 text-sm">
      <div className="text-slate-600">
        The Release Gate proves a draft before it goes live. It compiles the draft, checks every Law, then acts out
        hundreds of random actions as Members, Managers and Admins on this site's real data, inside a transaction
        that is always rolled back, checking every Law after each step. Publish runs it automatically.
      </div>
      <div className="flex items-center gap-2">
        <select value={steps} onChange={e => setSteps(Number(e.target.value))} className="rounded border px-2 py-1.5">
          {[150, 300, 1000, 2000].map(n => <option key={n} value={n}>{n} steps</option>)}
        </select>
        <button onClick={() => onRun(steps)} disabled={gating} className="rounded-md bg-slate-900 px-3 py-1.5 text-white disabled:opacity-40">
          {gating ? 'Running...' : 'Run gate'}
        </button>
      </div>
      {gating && <div className="h-2 w-full animate-pulse rounded bg-slate-300" />}
      {!gate && !gating && <div className="text-slate-400">No run yet for this draft.</div>}
      {gate && (
        <>
          <div className={`rounded-lg p-3 ${gate.passed ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-800'}`}>
            <div className="text-lg font-bold">{gate.passed ? 'PASSED' : 'BLOCKED'}</div>
            <div className="text-xs">
              {gate.steps} steps in {gate.durationMs} ms, seed {gate.seed}
              {gate.stats ? ` - ${gate.stats.allowed} allowed, ${gate.stats.refused} refused, ${gate.stats.skipped} idle` : ''}
            </div>
          </div>

          {!!gate.compileErrors?.length && (
            <div className="rounded-lg border border-red-200 bg-red-50 p-3">
              <div className="font-medium">Compile</div>
              {gate.compileErrors.map((m: string) => <div key={m} className="text-xs">{m}</div>)}
            </div>
          )}

          <div>
            <div className="mb-1 text-xs font-medium uppercase text-slate-400">Laws</div>
            {gate.laws.map((l: any) => (
              <div key={l.id} className="flex gap-2 border-b py-1.5 last:border-0">
                <span className={`w-10 shrink-0 text-xs font-bold ${l.passed ? 'text-emerald-600' : 'text-red-600'}`}>{l.passed ? 'PASS' : 'FAIL'}</span>
                <div>
                  <div>{l.sentence}</div>
                  {l.detail && <div className="text-xs text-slate-500">{l.detail}</div>}
                  <div className="text-[10px] uppercase text-slate-400">{l.dynamic ? 'checked after every step' : 'checked on the Blueprint'}</div>
                </div>
              </div>
            ))}
          </div>

          {gate.counterExample && (
            <div className="rounded-lg border border-red-200 bg-red-50 p-3">
              <div className="font-medium text-red-800">Counter-example</div>
              <div className="text-red-800">{gate.counterExample.message}</div>
              <ol className="mt-2 space-y-0.5 font-mono text-xs">
                {gate.counterExample.trace.map((s: any) => <li key={s.i}>#{s.i} {s.text} - {s.outcome}</li>)}
              </ol>
              <div className="mt-2 text-xs text-slate-600">Run again with seed {gate.seed} to replay the same walk.</div>
            </div>
          )}

          {!!gate.sample?.length && (
            <details>
              <summary className="cursor-pointer text-xs text-slate-500">First {gate.sample.length} steps of the walk</summary>
              <ol className="mt-1 space-y-0.5 font-mono text-xs">
                {gate.sample.map((s: any) => <li key={s.i}>#{s.i} {s.text} - {s.outcome}</li>)}
              </ol>
            </details>
          )}
        </>
      )}
    </div>
  );
}
'@

W 'apps/web/src/builder/LawsPanel.tsx' @'
import { useState } from 'react';
import { lawSentence, LAW_TEMPLATES, type Blueprint, type Field } from '@axel/compiler';

const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v));

export function LawsPanel({ bp, update }: { bp: Blueprint; update: (b: Blueprint) => void }) {
  const [t, setT] = useState('hidden_from');
  const [entity, setEntity] = useState(Object.keys(bp.entities)[0] ?? 'item');
  const [field, setField] = useState('');
  const [role, setRole] = useState('Member');
  const [state, setState] = useState('approved');
  const states = bp.workflows.request?.states ?? [];
  const fields = bp.entities[entity]?.fields.filter(f => !f.system) ?? [];
  const nextId = () => `l${Math.max(0, ...bp.laws.map(l => Number(String(l.id).replace(/\D/g, '')) || 0)) + 1}`;

  const add = () => {
    let law: Record<string, unknown>;
    switch (t) {
      case 'hidden_from': law = { template: t, entity, field: field || fields[0]?.key, role }; break;
      case 'requires_state': law = { template: t, entity: bp.entities.assignment ? 'assignment' : 'repair', ref: 'request_id', state }; break;
      case 'reachable': law = { template: t, workflow: 'request', state }; break;
      case 'non_negative': law = { template: t, entity: 'item', field: 'on_hand' }; break;
      default: law = { template: t, entity: 'item' };
    }
    update({ ...bp, laws: [...bp.laws, { id: nextId(), ...law } as any] });
  };

  return (
    <div className="space-y-4 text-sm">
      <div className="text-slate-600">Laws are rules this site must never break. The Release Gate proves them before every publish.</div>
      <div className="space-y-1.5">
        {bp.laws.map(l => (
          <div key={l.id} className="flex items-start justify-between gap-2 rounded border p-2">
            <div>
              <div>{lawSentence(l, bp)}</div>
              <div className="font-mono text-[10px] text-slate-400">{l.id} - {l.template}</div>
            </div>
            {l.locked
              ? <span className="text-[10px] uppercase text-slate-400">locked</span>
              : <button onClick={() => update({ ...bp, laws: bp.laws.filter(x => x.id !== l.id) })} className="text-xs text-red-600">remove</button>}
          </div>
        ))}
      </div>
      <div className="space-y-2 rounded-lg border p-3">
        <div className="font-medium">Add a Law</div>
        <select value={t} onChange={e => setT(e.target.value)} className="w-full rounded border px-2 py-1.5">
          {LAW_TEMPLATES.map(x => <option key={x.id} value={x.id}>{x.label}</option>)}
        </select>
        {t === 'hidden_from' && (
          <div className="grid grid-cols-3 gap-2">
            <select value={role} onChange={e => setRole(e.target.value)} className="rounded border px-2 py-1">
              {['Public', 'Member', 'Manager'].map(r => <option key={r}>{r}</option>)}
            </select>
            <select value={entity} onChange={e => { setEntity(e.target.value); setField(''); }} className="rounded border px-2 py-1">
              {Object.keys(bp.entities).map(k => <option key={k}>{k}</option>)}
            </select>
            <select value={field} onChange={e => setField(e.target.value)} className="rounded border px-2 py-1">
              {fields.map(f => <option key={f.key} value={f.key}>{f.label ?? f.key}</option>)}
            </select>
          </div>
        )}
        {(t === 'requires_state' || t === 'reachable') && (
          <select value={state} onChange={e => setState(e.target.value)} className="w-full rounded border px-2 py-1">
            {states.map(s => <option key={s}>{s}</option>)}
          </select>
        )}
        <button onClick={add} className="rounded-md bg-slate-900 px-3 py-1 text-xs text-white">Add Law</button>
      </div>
    </div>
  );
}

/** One-click toggle: can Members read this field? Used in the field list to demonstrate Laws. */
export function RoleToggle({ bp, entity, field, update }: { bp: Blueprint; entity: string; field: Field; update: (b: Blueprint) => void }) {
  if (field.system) return null;
  const hidden = !!field.roles?.read && !(field.roles.read as string[]).includes('Member');
  const toggle = () => {
    const next = clone(bp);
    const f = next.entities[entity].fields.find(x => x.key === field.key)!;
    if (hidden) f.roles = { ...f.roles, read: [...(f.roles?.read ?? []), 'Member'] };
    else f.roles = { ...(f.roles ?? {}), read: ['Manager', 'Admin'] };
    update(next);
  };
  return (
    <button onClick={toggle} title="Can Members see this field?"
      className={`ml-2 shrink-0 rounded px-1.5 text-[10px] ${hidden ? 'bg-slate-200 text-slate-600' : 'bg-amber-100 text-amber-800'}`}>
      {hidden ? 'Member: hidden' : 'Member: sees'}
    </button>
  );
}
'@

Write-Host ''
Write-Host 'Batch 7 done. Next: .\start.ps1, pnpm migrate, pnpm test'