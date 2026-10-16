# Axel - batch 8 (Replay Report, Impact Report with plans, workflow editor). Run from the axel folder.
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

# ============================== PATCHES: scripts and server ==============================
Patch 'package.json' @'
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel && pnpm test:api && pnpm test:gate"
'@ @'
    "test:replay": "pnpm --filter @axel/api test:replay",
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel && pnpm test:api && pnpm test:gate && pnpm test:replay"
'@

Patch 'apps/api/package.json' @'
    "test:gate": "tsx --env-file=../../.env --test test/gate.test.ts",
'@ @'
    "test:gate": "tsx --env-file=../../.env --test test/gate.test.ts",
    "test:replay": "tsx --env-file=../../.env --test test/replay.test.ts",
'@

Patch 'apps/api/src/server.ts' @'
import { gateRouter } from './gate';
'@ @'
import { gateRouter } from './gate';
import { replayRouter } from './replay';
'@

Patch 'apps/api/src/server.ts' @'
versionsRouter, gateRouter);
'@ @'
versionsRouter, gateRouter, replayRouter);
'@

# ============================== PATCHES: versions.ts (plans) ==============================
Patch 'apps/api/src/versions.ts' @'
import { runGate } from './laws';
'@ @'
import { runGate } from './laws';
import { impactReport } from './impact';
'@

Patch 'apps/api/src/versions.ts' @'
o: { rollback: boolean; confirm: boolean; reason?: string; gate?: any }) {
'@ @'
o: { rollback: boolean; confirm: boolean; reason?: string; gate?: any; plans?: Record<string, string>; replay?: any }) {
'@

Patch 'apps/api/src/versions.ts' @'
  const changes = cur ? summarize(cur.config, bp) : [];
  const destructive = cur ? await stranded(c, cur.config, bp) : [];
  if (destructive.length && !o.confirm) throw new AxelError('DESTRUCTIVE_CHANGE_UNPLANNED', 409, destructive.join(' '), { destructive, changes });
'@ @'
  const changes = cur ? summarize(cur.config, bp) : [];
  const impact = cur ? await impactReport(c, cur.config, bp) : [];
  const strandedStates = impact.filter(i => i.kind === 'state_removed' && (i.count ?? 0) > 0);
  const unplanned = strandedStates.filter(i => !o.plans?.[`${i.entity}.${i.state}`] && !o.confirm);
  if (unplanned.length)
    throw new AxelError('DESTRUCTIVE_CHANGE_UNPLANNED', 409, `${unplanned.map(i => i.detail).join(' ')} Choose a plan for each in the Impact list.`, { impact, changes });
  const destructive: string[] = [];
  const planned: Record<string, string> = {};
  for (const i of strandedStates) {
    const key = `${i.entity}.${i.state}`;
    const p = o.plans?.[key] ?? 'keep';
    planned[key] = p;
    if (p.startsWith('map:')) {
      const target = p.slice(4);
      if (!bp.workflows[i.entity!]?.states.includes(target)) throw new AxelError('VALIDATION_FAILED', 422, `'${target}' is not a state in the version being deployed.`);
      const moved = (await c.query(
        `UPDATE ${TABLES[i.entity!].table} SET state = $2, row_version = row_version + 1, updated_at = now() WHERE state = $1 RETURNING id`,
        [i.state, target])).rows;
      for (const m of moved)
        await c.query(
          `INSERT INTO audit_events (site_id, entity, record_id, kind, from_state, to_state, actor_id, actor_role, after, version_id)
           VALUES ($1,$2,$3,'rollback_map',$4,$5,$6,$7,$8,$9)`,
          [s.siteId, i.entity, m.id, i.state, target, s.ctx.userId, s.role, { plan: p }, v.id]);
      destructive.push(`${moved.length} ${i.entity}(s) moved from '${i.state}' to '${target}'.`);
    } else destructive.push(`${i.count} ${i.entity}(s) stay in '${i.state}' (read-only, data kept).`);
  }
'@

Patch 'apps/api/src/versions.ts' @'
kind: o.rollback ? 'rollback' : 'publish', gate: gateProof,
'@ @'
kind: o.rollback ? 'rollback' : 'publish', gate: gateProof, plans: planned, replay: o.replay ?? null,
'@

Patch 'apps/api/src/versions.ts' @'
  const b = z.object({ versionId: z.string().uuid(), reason: z.string().max(200).optional(), confirm: z.boolean().default(false) }).parse(req.body);
  const r = await withSite(req.site!.ctx, c => deploy(req, c, b.versionId, { rollback: false, confirm: b.confirm, reason: b.reason }));
'@ @'
  const b = z.object({
    versionId: z.string().uuid(), reason: z.string().max(200).optional(), confirm: z.boolean().default(false),
    plans: z.record(z.string()).optional(), replay: z.record(z.unknown()).optional(),
  }).parse(req.body);
  const r = await withSite(req.site!.ctx, c => deploy(req, c, b.versionId, { rollback: false, confirm: b.confirm, reason: b.reason, plans: b.plans, replay: b.replay }));
'@

Patch 'apps/api/src/versions.ts' @'
  const b = z.object({ versionId: z.string().uuid(), confirm: z.boolean().default(false) }).parse(req.body);
  const s = req.site!;
'@ @'
  const b = z.object({ versionId: z.string().uuid(), confirm: z.boolean().default(false), plans: z.record(z.string()).optional() }).parse(req.body);
  const s = req.site!;
'@

Patch 'apps/api/src/versions.ts' @'
deploy(req, c, b.versionId, { rollback: true, confirm: b.confirm, gate }));
'@ @'
deploy(req, c, b.versionId, { rollback: true, confirm: b.confirm, gate, plans: b.plans }));
'@

# ============================== PATCHES: builder ==============================
Patch 'apps/web/src/builder/Builder.tsx' @'
import { LawsPanel, RoleToggle } from './LawsPanel';
'@ @'
import { LawsPanel, RoleToggle } from './LawsPanel';
import { WorkflowPanel } from './WorkflowPanel';
import { ImpactPanel } from './ImpactPanel';
import { ReleasesPanel } from './ReleasesPanel';
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
useState<'problems' | 'module' | 'laws' | 'gate' | 'theme' | 'json' | 'versions'>('problems');
'@ @'
useState<'problems' | 'module' | 'workflow' | 'laws' | 'gate' | 'impact' | 'theme' | 'json' | 'versions'>('problems');
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
  const [gating, setGating] = useState(false);
'@ @'
  const [gating, setGating] = useState(false);
  const [impact, setImpact] = useState<any>(null);
  const [impacting, setImpacting] = useState(false);
  const [plans, setPlans] = useState<Record<string, string>>({});
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
  async function publish(confirm = false) {
    const id = dirty || !draft ? await save() : draft.id;
    if (!id) return;
    if (!confirm) {
      const g = await runGate(300, id);
      if (!g?.passed) { setMsg({ kind: 'err', text: 'The Release Gate blocked this draft, so nothing was published. See the Gate tab.' }); return; }
    }
'@ @'
  async function runImpact(versionId?: string) {
    const id = versionId ?? (dirty || !draft ? await save() : draft.id);
    if (!id) return null;
    setTab('impact'); setImpacting(true); setImpact(null);
    try {
      const r = await http.post(`/sites/${siteId}/versions/${id}/replay`, { sample: 50 }, H);
      setImpact(r.data);
      return r.data;
    } catch (e) { setMsg({ kind: 'err', text: errOf(e).message }); return null; }
    finally { setImpacting(false); }
  }

  async function publish(confirm = false, reviewed = false) {
    const id = dirty || !draft ? await save() : draft.id;
    if (!id) return;
    let rep = impact;
    if (!confirm && !reviewed) {
      const g = await runGate(300, id);
      if (!g?.passed) { setMsg({ kind: 'err', text: 'The Release Gate blocked this draft, so nothing was published. See the Gate tab.' }); return; }
      rep = await runImpact(id);
      if (!rep) return;
      const strandedStates = (rep.impact ?? []).filter((i: any) => i.kind === 'state_removed' && i.count > 0);
      if (rep.divergent?.length || strandedStates.length) {
        setMsg({
          kind: 'warn',
          text: `Review before publishing: ${rep.divergent?.length ?? 0} of ${rep.sampled} past requests would go differently${strandedStates.length ? `, and ${strandedStates.length} removed state(s) still hold records (choose a plan in the Impact tab)` : ''}.`,
          action: { label: 'Reviewed - publish', run: () => publish(false, true) },
        });
        return;
      }
    }
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
      const r = await http.post(`/sites/${siteId}/publish`, { versionId: id, confirm }, H);
'@ @'
      const r = await http.post(`/sites/${siteId}/publish`, {
        versionId: id, confirm, plans,
        replay: rep ? { sampled: rep.sampled, identical: rep.identical, divergent: rep.divergent?.length ?? 0, reviewed } : undefined,
      }, H);
      setPlans({});
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
          <nav className="flex border-b text-xs">
'@ @'
          <nav className="flex flex-wrap border-b text-xs">
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
['module', 'Module'], ['laws', 'Laws'], ['gate', 'Gate'], ['theme', 'Theme'],
'@ @'
['module', 'Module'], ['workflow', 'Workflow'], ['laws', 'Laws'], ['gate', 'Gate'], ['impact', 'Impact'], ['theme', 'Theme'],
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
            {tab === 'laws' && <LawsPanel bp={bp} update={update} />}
'@ @'
            {tab === 'workflow' && <WorkflowPanel bp={bp} update={update} />}
            {tab === 'impact' && <ImpactPanel report={impact} running={impacting} onRun={() => runImpact()} plans={plans} setPlans={setPlans} />}
            {tab === 'laws' && <LawsPanel bp={bp} update={update} />}
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
{tab === 'versions' && <VersionsPanel siteId=
'@ @'
{tab === 'versions' && <ReleasesPanel siteId=
'@

# ============================== PATCHES: docs ==============================
Patch 'README.md' @'
If a Law breaks, publish is blocked and the builder shows the counter-example: the exact steps that broke it, with a seed to replay. The proof (steps, seed, duration) is stored on every deployment; rollbacks run a short gate too.
'@ @'
If a Law breaks, publish is blocked and the builder shows the counter-example: the exact steps that broke it, with a seed to replay. The proof (steps, seed, duration) is stored on every deployment; rollbacks run a short gate too.

## Replay Report and Impact Report

- **Replay.** Before publishing, Axel takes the last 50 real requests and runs their recorded history (same steps, same roles) through both the live version and the draft, inside a transaction that is rolled back. It reports exactly which requests would now go differently and at which step, for example "3 of 50: submitted > approved would be blocked by a rule".
- **Impact.** Every change is classified as additive, behavioural or destructive. When a removed state still holds records, publishing or rolling back requires a plan per state: keep those records read-only, or move them to another state (recorded in the audit trail). Fields that disappear are hidden, never dropped.
- Publish runs Gate, then Replay and Impact; anything that differs must be reviewed first. The replay summary and the chosen plans are stored with the deployment.
'@

Patch 'README.md' @'
| `test:gate` (4) | Unchanged sites pass the gate, a leaked price is blocked by a Law, a shortcut that skips approval is caught with a counter-example, publishing without a passing gate is refused |
'@ @'
| `test:gate` (4) | Unchanged sites pass the gate, a leaked price is blocked by a Law, a shortcut that skips approval is caught with a counter-example, publishing without a passing gate is refused |
| `test:replay` (4) | An unchanged draft replays identically, a stricter rule shows which past requests it would block, a removed state with records is reported with plans, publishing it without a plan is refused |
'@

Patch 'README.md' @'
Run with Axel started: `pnpm test` (27 tests).
'@ @'
Run with Axel started: `pnpm test` (31 tests).
'@

Patch 'README.md' @'
404-not-403 for other sites. 27 automated tests.
'@ @'
404-not-403 for other sites. 31 automated tests.
'@

Patch 'README.md' @'
Built: the Release Gate with Laws (above). Next: a Replay Report that runs real history through a proposed version, and a Sheet Inferencer that derives a site from a unit's existing spreadsheets.
'@ @'
Built: the Release Gate with Laws, the Replay Report and the Impact Report (above). Next: a Sheet Inferencer that derives a site from a unit's existing spreadsheets.
'@

Patch 'docs/API.md' @'
| POST | `/api/sites/:siteId/versions/:v/gate` |
'@ @'
| POST | `/api/sites/:siteId/versions/:v/replay` | `{ sample? }` replays the last N real requests through the live version and the draft; returns divergences, a summary and the Impact Report |
| GET | `/api/sites/:siteId/versions/:v/impact` | Impact Report of a version against live (additive, behavioural, destructive; plan options for removed states) |
| POST | `/api/sites/:siteId/versions/:v/gate` |
'@

Patch 'docs/API.md' @'
| POST | `/api/sites/:siteId/publish` | `{ versionId, confirm? }`
'@ @'
| POST | `/api/sites/:siteId/publish` | `{ versionId, plans?, replay?, confirm? }`; `plans` maps `entity.state` to `keep` or `map:<state>`;
'@

Patch 'docs/DEMO_SCRIPT.md' @'
## Brief step 4: Excel with role rules (1.5 min)
'@ @'
## Replay and Impact (1.5 min)

- Service Centre builder, **Workflow** tab: on **Approve**, type the rule `qty <= 1` and click elsewhere.
- **Impact** tab, **Run replay and impact**: "N of 50 past requests go exactly the same way", plus the requests the new rule would block and at which step. Click **Undo**.
- Distribution (after enabling Returns and returning one request): **Versions** tab, **Roll back to this version** on the version before Returns. The Impact list shows "1 request(s) are in 'returned', which this version removes". Choose **Move these records to 'closed'** and **Roll back now**. The record moves, the timeline records it, nothing is deleted.

*Say:* "We test changes against what actually happened, not against what we imagine. And no rollback ever loses data."

## Brief step 4: Excel with role rules (1.5 min)
'@

# ============================== API: impact + replay ==============================
W 'apps/api/src/impact.ts' @'
import { REGISTRY, type Blueprint } from '@axel/compiler';
import type { Tx } from './db';
import { TABLES } from './entities';

export interface ImpactItem {
  kind: string; class: 'additive' | 'behavioural' | 'destructive'; detail: string;
  entity?: string; state?: string; field?: string; count?: number; options?: string[];
}

const count = async (c: Tx, sql: string, args: unknown[] = []) => Number((await c.query(sql, args)).rows[0].n);

/** Classifies every difference between the live Blueprint (a) and a candidate (b), with record counts from live data. */
export async function impactReport(c: Tx, a: Blueprint, b: Blueprint): Promise<ImpactItem[]> {
  const out: ImpactItem[] = [];
  for (const m of b.modules) if (!a.modules.includes(m)) out.push({ kind: 'module_added', class: 'additive', detail: `Adds ${REGISTRY[m]?.name ?? m}.` });
  for (const m of a.modules) if (!b.modules.includes(m)) out.push({ kind: 'module_removed', class: 'destructive', detail: `Removes ${REGISTRY[m]?.name ?? m}. Its records are kept and hidden.` });

  for (const [ek, e] of Object.entries(a.entities)) {
    const spec = TABLES[ek];
    const ne = b.entities[ek];
    if (!ne) {
      const n = spec ? await count(c, `SELECT count(*) AS n FROM ${spec.table}`) : 0;
      out.push({ kind: 'entity_removed', class: 'destructive', entity: ek, count: n, detail: `${e.label ?? ek} is no longer shown; its ${n} record(s) are kept.` });
      continue;
    }
    for (const f of e.fields) {
      if (ne.fields.some(x => x.key === f.key)) continue;
      let n = 0;
      if (spec && f.type !== 'formula' && !f.system)
        n = spec.core.includes(f.key)
          ? await count(c, `SELECT count(*) AS n FROM ${spec.table} WHERE ${f.key} IS NOT NULL`)
          : await count(c, `SELECT count(*) AS n FROM ${spec.table} WHERE data ? $1`, [f.key]);
      out.push({ kind: 'field_removed', class: 'destructive', entity: ek, field: f.key, count: n,
        detail: `${f.label ?? f.key} is removed from ${e.label ?? ek}: hidden, not deleted (${n} value(s) stay in the database).` });
    }
    for (const f of ne.fields) {
      const o = e.fields.find(x => x.key === f.key);
      if (!o) { out.push({ kind: 'field_added', class: 'additive', detail: `Adds ${f.label ?? f.key} to ${ne.label ?? ek}.` }); continue; }
      if (o.type !== f.type) out.push({ kind: 'field_type', class: 'destructive', entity: ek, field: f.key, detail: `${f.label ?? f.key} changes from ${o.type} to ${f.type}; existing values are kept as they are.` });
      if (JSON.stringify(o.roles ?? null) !== JSON.stringify(f.roles ?? null)) out.push({ kind: 'field_access', class: 'behavioural', detail: `Who can see or edit ${f.label ?? f.key} changes.` });
      if ((o.expr ?? '') !== (f.expr ?? '')) out.push({ kind: 'field_formula', class: 'behavioural', detail: `${f.label ?? f.key} is now calculated as ${f.expr}.` });
    }
  }
  for (const [ek, e] of Object.entries(b.entities)) if (!a.entities[ek]) out.push({ kind: 'entity_added', class: 'additive', detail: `Adds ${e.label ?? ek}.` });

  for (const [ek, wf] of Object.entries(a.workflows)) {
    const nw = b.workflows[ek];
    const spec = TABLES[ek];
    for (const s of wf.states) {
      if (nw?.states.includes(s)) continue;
      const n = spec ? await count(c, `SELECT count(*) AS n FROM ${spec.table} WHERE state = $1`, [s]) : 0;
      out.push({
        kind: 'state_removed', class: 'destructive', entity: ek, state: s, count: n,
        options: ['keep', ...(nw?.states ?? []).map(x => `map:${x}`)],
        detail: n ? `${n} ${ek}(s) are in '${s}', which this version removes.` : `State '${s}' is removed (no records are in it).`,
      });
    }
    for (const s of nw?.states ?? []) if (!wf.states.includes(s)) out.push({ kind: 'state_added', class: 'additive', detail: `Adds state '${s}'.` });
    for (const t of wf.transitions) {
      const label = t.label ?? t.to;
      const nt = nw?.transitions.find(x => x.from === t.from && x.to === t.to);
      if (!nt) {
        if (nw?.states.includes(t.from) && nw.states.includes(t.to)) out.push({ kind: 'step_removed', class: 'behavioural', detail: `Step ${label} (${t.from} to ${t.to}) is removed.` });
        continue;
      }
      const lost = t.roles.filter(r => !nt.roles.includes(r) && r !== 'Public');
      const gained = nt.roles.filter(r => !t.roles.includes(r) && r !== 'Public');
      if (lost.length) out.push({ kind: 'step_roles', class: 'behavioural', detail: `${lost.join(', ')} can no longer ${label.toLowerCase()}.` });
      if (gained.length) out.push({ kind: 'step_roles', class: 'behavioural', detail: `${gained.join(', ')} can now ${label.toLowerCase()}.` });
      if ((t.guard ?? '') !== (nt.guard ?? '')) out.push({ kind: 'step_guard', class: 'behavioural', detail: `The rule for ${label} changes from "${t.guard ?? 'none'}" to "${nt.guard ?? 'none'}".` });
      if (JSON.stringify(t.actions ?? []) !== JSON.stringify(nt.actions ?? [])) out.push({ kind: 'step_actions', class: 'behavioural', detail: `What ${label} does to stock or repairs changes.` });
    }
    for (const t of nw?.transitions ?? []) if (!wf.transitions.some(x => x.from === t.from && x.to === t.to)) out.push({ kind: 'step_added', class: 'additive', detail: `Adds step ${t.label ?? t.to} (${t.from} to ${t.to}).` });
  }
  for (const ek of Object.keys(b.workflows)) if (!a.workflows[ek]) out.push({ kind: 'workflow_added', class: 'additive', detail: `Adds a ${ek} workflow.` });

  for (const p of b.pages) if (!a.pages.some(x => x.path === p.path)) out.push({ kind: 'page_added', class: 'additive', detail: `Adds page ${p.title}.` });
  for (const p of a.pages) if (!b.pages.some(x => x.path === p.path)) out.push({ kind: 'page_removed', class: 'behavioural', detail: `Page ${p.title} is removed.` });
  for (const l of b.laws) if (!a.laws.some(x => x.id === l.id)) out.push({ kind: 'law_added', class: 'additive', detail: `Adds Law ${l.id} (${l.template}).` });
  for (const l of a.laws) if (!b.laws.some(x => x.id === l.id)) out.push({ kind: 'law_removed', class: 'behavioural', detail: `Removes Law ${l.id} (${l.template}).` });
  if (JSON.stringify(a.theme) !== JSON.stringify(b.theme)) out.push({ kind: 'theme', class: 'behavioural', detail: 'The look or layout changes.' });
  return out;
}
'@

W 'apps/api/src/replay.ts' @'
import { Router } from 'express';
import { z } from 'zod';
import { compile, type Blueprint, type Compiled, type Role } from '@axel/compiler';
import { pool, withSite, UUID, type Tx } from './db';
import { ah, notFound } from './errors';
import { runTransition } from './workflow';
import { impactReport } from './impact';

// Mounted at /api/sites/:siteId (Admin only).
export const replayRouter = Router({ mergeParams: true });

type Outcome = 'allowed' | 'blocked_by_guard' | 'blocked_by_role' | 'step_missing' | 'insufficient_stock' | 'no_reservation' | 'refused';
const TEXT: Record<Outcome, string> = {
  allowed: 'allowed', blocked_by_guard: 'blocked by a rule', blocked_by_role: 'blocked because the role may not do it',
  step_missing: 'impossible (the step no longer exists)', insufficient_stock: 'blocked by stock', no_reservation: 'blocked (nothing reserved)', refused: 'refused',
};
const classify = (e: any): Outcome => {
  switch (e?.code) {
    case 'GUARD_FAILED': return 'blocked_by_guard';
    case 'TRANSITION_NOT_ALLOWED': return e.status === 403 ? 'blocked_by_role' : 'step_missing';
    case 'INSUFFICIENT_STOCK': return 'insufficient_stock';
    case 'NO_RESERVATION': return 'no_reservation';
    default: return 'refused';
  }
};
const pin = (req: any, config: any): Blueprint => ({ ...config, siteId: req.site.siteId, slug: req.site.slug });

interface Ev { from_state: string; to_state: string; actor_role: string; after: any }

/** Re-creates a request as it was before its first recorded step, then applies its real history step by step. */
async function replayOne(c: Tx, siteId: string, userId: string, versionId: string, compiled: Compiled, name: string, rec: any, events: Ev[], tag: string) {
  const outs: { step: number; transition: string; outcome: Outcome; detail?: string }[] = [];
  const id = (await c.query(
    `INSERT INTO requests (site_id, item_id, qty, state, requested_by, data) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
    [siteId, rec.item_id, rec.qty, events[0].from_state, rec.requested_by, rec.data])).rows[0].id;
  for (const [k, ev] of events.entries()) {
    const role = (['Member', 'Manager', 'Admin'].includes(ev.actor_role) ? ev.actor_role : 'Admin') as Role;
    const transition = `${ev.from_state} > ${ev.to_state}`;
    await c.query('SAVEPOINT rp');
    try {
      await runTransition(c, { siteId, userId, role, versionId }, compiled, name, 'request', id, {
        to: ev.to_state, idempotencyKey: `replay-${tag}-${k}`,
        payload: ev.after?.assigned_to ? { assigned_to: ev.after.assigned_to } : undefined,
      });
      await c.query('RELEASE SAVEPOINT rp');
      outs.push({ step: k + 1, transition, outcome: 'allowed' });
    } catch (e: any) {
      await c.query('ROLLBACK TO SAVEPOINT rp');
      outs.push({ step: k + 1, transition, outcome: classify(e), detail: e?.message });
      break;
    }
  }
  const final = (await c.query('SELECT state FROM requests WHERE id = $1', [id])).rows[0]?.state as string;
  return { outs, final };
}

// POST /api/sites/:siteId/versions/:v/replay { sample? }
replayRouter.post('/versions/:v/replay', ah(async (req, res) => {
  if (!UUID.test(req.params.v)) throw notFound();
  const b = z.object({ sample: z.number().int().min(5).max(300).default(50) }).parse(req.body ?? {});
  const s = req.site!;
  const v = await withSite(s.ctx, async c => (await c.query('SELECT id, config FROM site_versions WHERE id = $1', [req.params.v])).rows[0]);
  if (!v) throw notFound();
  const draftBp = pin(req, v.config);
  const draft = compile(draftBp);
  const live = s.compiled;

  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query(`SELECT set_config('app.site_id',$1,true), set_config('app.user_id',$2,true), set_config('app.role','Admin',true)`, [s.siteId, s.ctx.userId]);
    const impact = await impactReport(c, live.blueprint, draftBp);
    if (!live.blueprint.workflows.request || !live.blueprint.entities.request) {
      return res.json({ sampled: 0, identical: 0, divergent: [], summary: ['This site has no request history to replay.'], impact });
    }
    const recs = (await c.query(
      `SELECT r.* FROM requests r
        WHERE EXISTS (SELECT 1 FROM audit_events e WHERE e.entity = 'request' AND e.record_id = r.id AND e.kind = 'transition')
        ORDER BY r.created_at DESC LIMIT $1`, [b.sample])).rows;
    const evs = (await c.query(
      `SELECT record_id, from_state, to_state, actor_role, after FROM audit_events
        WHERE entity = 'request' AND kind = 'transition' AND record_id = ANY($1) ORDER BY at, id`, [recs.map(r => r.id)])).rows;
    const byRec = new Map<string, Ev[]>();
    for (const e of evs) { if (!byRec.has(e.record_id)) byRec.set(e.record_id, []); byRec.get(e.record_id)!.push(e); }

    const divergent: any[] = [];
    let identical = 0;
    for (const [n, rec] of recs.entries()) {
      const events = byRec.get(rec.id) ?? [];
      if (!events.length) { identical++; continue; }
      await c.query('SAVEPOINT rec');
      const a = await replayOne(c, s.siteId, s.ctx.userId, s.versionId, live, s.name, rec, events, `L${n}`);
      await c.query('ROLLBACK TO SAVEPOINT rec');
      const d = await replayOne(c, s.siteId, s.ctx.userId, v.id, draft, s.name, rec, events, `D${n}`);
      await c.query('ROLLBACK TO SAVEPOINT rec');
      const firstDiff = d.outs.findIndex((o, i) => o.outcome !== a.outs[i]?.outcome);
      if (firstDiff === -1 && d.outs.length === a.outs.length && d.final === a.final) { identical++; continue; }
      const i = firstDiff === -1 ? Math.min(a.outs.length, d.outs.length) : firstDiff;
      const at = d.outs[i] ?? a.outs[i];
      divergent.push({
        recordId: rec.id, label: rec.data?.serial_no ?? rec.data?.site_location ?? String(rec.id).slice(0, 8),
        step: at?.step, transition: at?.transition, live: a.outs[i]?.outcome ?? 'n/a', draft: d.outs[i]?.outcome ?? 'n/a',
        detail: d.outs[i]?.detail, liveFinal: a.final, draftFinal: d.final,
      });
    }

    const groups = new Map<string, number>();
    for (const d of divergent) { const k = `${d.transition}|${d.draft}|${d.live}`; groups.set(k, (groups.get(k) ?? 0) + 1); }
    const summary = [...groups].map(([k, n]) => {
      const [tr, dr, lv] = k.split('|');
      return `${n} of ${recs.length}: ${tr} would be ${TEXT[dr as Outcome] ?? dr} (today: ${TEXT[lv as Outcome] ?? lv}).`;
    });
    if (!divergent.length) summary.push(`All ${recs.length} replayed requests behave exactly as they do today.`);
    res.json({ sampled: recs.length, identical, divergent, summary, impact });
  } finally {
    await c.query('ROLLBACK').catch(() => {});
    c.release();
  }
}));

// GET /api/sites/:siteId/versions/:v/impact - used before a rollback
replayRouter.get('/versions/:v/impact', ah(async (req, res) => {
  if (!UUID.test(req.params.v)) throw notFound();
  const s = req.site!;
  const impact = await withSite(s.ctx, async c => {
    const v = (await c.query('SELECT config FROM site_versions WHERE id = $1', [req.params.v])).rows[0];
    if (!v) throw notFound();
    return impactReport(c, s.compiled.blueprint, pin(req, v.config));
  });
  res.json({ impact });
}));
'@

W 'apps/api/test/replay.test.ts' @'
import { test, before } from 'node:test';
import assert from 'node:assert/strict';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const SC = '22222222-2222-4222-8222-222222222222';
let admin = '';

async function call(method: string, path: string, site: string, body?: unknown) {
  const r = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${admin}`, 'x-site-id': site, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}
async function withDraft(mutate: (bp: any) => void, fn: (id: string) => Promise<void>) {
  const b = await call('GET', `/sites/${SC}/builder`, SC);
  const bp = structuredClone(b.body.published.config);
  mutate(bp);
  const d = await call('POST', `/sites/${SC}/versions`, SC, { config: bp, reason: 'replay test' });
  assert.equal(d.status, 201, JSON.stringify(d.body));
  try { await fn(d.body.id); } finally { await call('DELETE', `/sites/${SC}/versions/${d.body.id}`, SC); }
}
const dropRejected = (bp: any) => {
  const w = bp.workflows.request;
  w.states = w.states.filter((s: string) => s !== 'rejected');
  w.transitions = w.transitions.filter((t: any) => t.to !== 'rejected');
  w.terminal = w.terminal.filter((s: string) => s !== 'rejected');
};

before(async () => {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: 'admin@axel.dev', password: 'demo1234' }) });
  admin = (await r.json()).token;
});

test('an unchanged draft replays identically', () => withDraft(() => {}, async id => {
  const r = await call('POST', `/sites/${SC}/versions/${id}/replay`, SC, { sample: 30 });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.sampled > 0, 'no history to replay; run pnpm seed');
  assert.equal(r.body.divergent.length, 0, JSON.stringify(r.body.divergent.slice(0, 3)));
}));

test('a stricter rule on Approve shows which past requests it would block', () => withDraft(bp => {
  bp.workflows.request.transitions.find((t: any) => t.to === 'approved').guard = 'qty <= 1';
}, async id => {
  const r = await call('POST', `/sites/${SC}/versions/${id}/replay`, SC, { sample: 50 });
  assert.equal(r.status, 200);
  assert.ok(r.body.divergent.some((d: any) => d.draft === 'blocked_by_guard'), JSON.stringify(r.body.summary));
  assert.ok(r.body.impact.some((i: any) => i.kind === 'step_guard'));
}));

test('a removed state that holds records is reported with plan options', () => withDraft(dropRejected, async id => {
  const r = await call('GET', `/sites/${SC}/versions/${id}/impact`, SC);
  assert.equal(r.status, 200);
  const item = r.body.impact.find((i: any) => i.kind === 'state_removed' && i.state === 'rejected');
  assert.ok(item, 'state_removed for rejected');
  assert.equal(item.class, 'destructive');
  assert.ok(item.options.includes('keep') && item.options.includes('map:closed'));
}));

test('publishing that removal without a plan is refused', t => withDraft(dropRejected, async id => {
  const imp = await call('GET', `/sites/${SC}/versions/${id}/impact`, SC);
  if (!imp.body.impact.find((i: any) => i.kind === 'state_removed' && i.state === 'rejected')?.count) return t.skip('no rejected requests; run pnpm seed');
  const g = await call('POST', `/sites/${SC}/versions/${id}/gate`, SC, { steps: 30 });
  assert.equal(g.body.passed, true, JSON.stringify(g.body.laws?.filter((l: any) => !l.passed)));
  const p = await call('POST', `/sites/${SC}/publish`, SC, { versionId: id });
  assert.equal(p.status, 409);
  assert.equal(p.body.code, 'DESTRUCTIVE_CHANGE_UNPLANNED');
}));
'@

# ============================== WEB: workflow, impact, releases ==============================
W 'apps/web/src/builder/WorkflowPanel.tsx' @'
import { useEffect, useState } from 'react';
import { parse, type Blueprint, type Role, type Workflow } from '@axel/compiler';

const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v));
const ROLES: Role[] = ['Member', 'Manager', 'Admin'];

function GuardInput({ value, onCommit }: { value?: string; onCommit: (g?: string) => void }) {
  const [v, setV] = useState(value ?? '');
  useEffect(() => { setV(value ?? ''); }, [value]);
  let err = '';
  if (v.trim()) { try { parse(v); } catch (e) { err = (e as Error).message; } }
  return (
    <div>
      <input value={v} onChange={e => setV(e.target.value)} placeholder="Rule (optional), e.g. qty <= 50"
        onBlur={() => { if (!err && v.trim() !== (value ?? '')) onCommit(v.trim() || undefined); }}
        onKeyDown={e => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur(); }}
        className={`w-full rounded border px-2 py-1 font-mono text-xs ${err ? 'border-red-400' : ''}`} />
      {err && <div className="text-[10px] text-red-600">{err}</div>}
    </div>
  );
}

export function WorkflowPanel({ bp, update }: { bp: Blueprint; update: (b: Blueprint) => void }) {
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [label, setLabel] = useState('');
  const wf = bp.workflows.request;
  if (!wf) return <div className="text-sm text-slate-500">This site has no request workflow. Add the Request module first.</div>;
  const set = (fn: (w: Workflow) => void) => { const next = clone(bp); fn(next.workflows.request); update(next); };
  const nextId = `t${Math.max(0, ...wf.transitions.map(t => Number(t.id.replace(/\D/g, '')) || 0)) + 1}`;
  const addStep = () => {
    const target = to.trim().toLowerCase().replace(/[^a-z0-9_]+/g, '_');
    if (!from || !target) return;
    set(w => {
      if (!w.states.includes(target)) { w.states.push(target); w.terminal.push(target); }
      w.transitions.push({ id: nextId, from, to: target, label: label || target, roles: ['Manager', 'Admin'] });
    });
    setLabel(''); setTo('');
  };

  return (
    <div className="space-y-3 text-sm">
      <div className="text-slate-600">Steps of the request workflow. Choose who may take each step, or add a rule such as <code className="font-mono">qty &lt;= 50</code>. Run Impact to see how past requests would be affected.</div>
      <div className="flex flex-wrap gap-1 text-xs">
        {wf.states.map(s => (
          <span key={s} className={`rounded px-1.5 py-0.5 ${s === wf.initial ? 'bg-sky-100' : wf.terminal.includes(s) ? 'bg-slate-200' : 'bg-slate-100'}`}>{s}</span>
        ))}
      </div>
      {wf.transitions.map((t, idx) => (
        <div key={t.id} className="space-y-1.5 rounded-lg border p-2">
          <div className="flex items-center gap-2">
            <input value={t.label ?? ''} onChange={e => set(w => { w.transitions[idx].label = e.target.value; })} className="w-28 rounded border px-1.5 py-0.5 text-xs font-medium" />
            <span className="font-mono text-xs text-slate-500">{t.from} &rarr; {t.to}</span>
            <span className="ml-auto font-mono text-[10px] text-slate-400">{t.id}</span>
            <button onClick={() => set(w => { w.transitions.splice(idx, 1); })} className="text-xs text-red-600">remove</button>
          </div>
          <div className="flex gap-3 text-xs">
            {ROLES.map(r => (
              <label key={r} className="flex items-center gap-1">
                <input type="checkbox" checked={t.roles.includes(r)} onChange={() => set(w => {
                  const x = w.transitions[idx];
                  x.roles = x.roles.includes(r) ? x.roles.filter(y => y !== r) : [...x.roles, r];
                })} />{r}
              </label>
            ))}
          </div>
          <GuardInput value={t.guard} onCommit={g => set(w => { if (g) w.transitions[idx].guard = g; else delete w.transitions[idx].guard; })} />
          {!!t.actions?.length && <div className="font-mono text-[10px] text-slate-500">does: {t.actions.join('; ')}</div>}
        </div>
      ))}
      <div className="space-y-2 rounded-lg border border-dashed p-2">
        <div className="text-xs font-medium">Add a step</div>
        <div className="grid grid-cols-3 gap-2">
          <select value={from} onChange={e => setFrom(e.target.value)} className="rounded border px-1 py-1 text-xs">
            <option value="">from...</option>
            {wf.states.map(s => <option key={s}>{s}</option>)}
          </select>
          <input list="axel-states" value={to} onChange={e => setTo(e.target.value)} placeholder="to (state)" className="rounded border px-1 py-1 text-xs" />
          <input value={label} onChange={e => setLabel(e.target.value)} placeholder="Label" className="rounded border px-1 py-1 text-xs" />
        </div>
        <datalist id="axel-states">{wf.states.map(s => <option key={s} value={s} />)}</datalist>
        <button onClick={addStep} disabled={!from || !to.trim()} className="rounded-md bg-slate-900 px-3 py-1 text-xs text-white disabled:opacity-40">Add step</button>
      </div>
    </div>
  );
}
'@

W 'apps/web/src/builder/ImpactPanel.tsx' @'
const CLASS_STYLE: Record<string, string> = {
  additive: 'bg-emerald-100 text-emerald-800',
  behavioural: 'bg-amber-100 text-amber-800',
  destructive: 'bg-red-100 text-red-800',
};
const OUTCOME: Record<string, string> = {
  allowed: 'allowed', blocked_by_guard: 'blocked by rule', blocked_by_role: 'role not allowed',
  step_missing: 'step removed', insufficient_stock: 'not enough stock', no_reservation: 'nothing reserved', refused: 'refused', 'n/a': '-',
};

export function ImpactList({ items, plans, setPlans }: { items: any[]; plans: Record<string, string>; setPlans: (p: Record<string, string>) => void }) {
  if (!items?.length) return <div className="text-sm text-slate-400">No changes compared to live.</div>;
  return (
    <div className="space-y-1.5">
      {items.map((i, n) => {
        const key = `${i.entity}.${i.state}`;
        return (
          <div key={n} className="rounded border p-2 text-sm">
            <div className="flex items-start gap-2">
              <span className={`shrink-0 rounded px-1.5 text-[10px] uppercase ${CLASS_STYLE[i.class]}`}>{i.class}</span>
              <span>{i.detail}</span>
            </div>
            {i.kind === 'state_removed' && i.count > 0 && (
              <select value={plans[key] ?? ''} onChange={e => setPlans({ ...plans, [key]: e.target.value })} className="mt-1 w-full rounded border px-2 py-1 text-xs">
                <option value="">Choose a plan...</option>
                {i.options.map((o: string) => (
                  <option key={o} value={o}>{o === 'keep' ? 'Keep these records read-only' : `Move these records to '${o.slice(4)}'`}</option>
                ))}
              </select>
            )}
          </div>
        );
      })}
    </div>
  );
}

export function ImpactPanel({ report, running, onRun, plans, setPlans }: {
  report: any; running: boolean; onRun: () => void; plans: Record<string, string>; setPlans: (p: Record<string, string>) => void;
}) {
  return (
    <div className="space-y-4 text-sm">
      <div className="text-slate-600">
        Axel replays the last 50 real requests (same steps, same roles) through both the live version and this draft,
        and lists every difference. Publish runs this automatically after the gate.
      </div>
      <button onClick={onRun} disabled={running} className="rounded-md bg-slate-900 px-3 py-1.5 text-white disabled:opacity-40">
        {running ? 'Replaying...' : 'Run replay and impact'}
      </button>
      {running && <div className="h-2 w-full animate-pulse rounded bg-slate-300" />}
      {report && (
        <>
          <div className={`rounded-lg p-3 ${report.divergent.length ? 'bg-amber-50 text-amber-900' : 'bg-emerald-50 text-emerald-800'}`}>
            <div className="font-semibold">Replay: {report.identical} of {report.sampled} past requests go exactly the same way</div>
            {report.summary.map((s: string) => <div key={s} className="text-xs">{s}</div>)}
          </div>
          {!!report.divergent.length && (
            <table className="w-full text-xs">
              <thead className="text-left text-slate-500"><tr><th className="py-1">Request</th><th>Step</th><th>Today</th><th>With draft</th></tr></thead>
              <tbody>
                {report.divergent.slice(0, 25).map((d: any) => (
                  <tr key={d.recordId} className="border-t" title={d.detail}>
                    <td className="py-1">{d.label}</td><td className="font-mono">{d.transition}</td>
                    <td>{OUTCOME[d.live] ?? d.live}</td><td className="text-red-700">{OUTCOME[d.draft] ?? d.draft}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          <div>
            <div className="mb-1 text-xs font-medium uppercase text-slate-400">Impact on data and behaviour</div>
            <ImpactList items={report.impact} plans={plans} setPlans={setPlans} />
          </div>
        </>
      )}
    </div>
  );
}
'@

W 'apps/web/src/builder/ReleasesPanel.tsx' @'
import { useEffect, useState } from 'react';
import { http, errOf } from '../api';
import { ImpactList } from './ImpactPanel';

type Msg = { kind: 'ok' | 'err' | 'warn'; text: string; action?: { label: string; run: () => void } } | null;

export function ReleasesPanel({ siteId, H, refreshKey, onChanged }: { siteId: string; H: any; refreshKey: number; onChanged: (m: Msg) => void }) {
  const [deps, setDeps] = useState<any[] | null>(null);
  const [err, setErr] = useState('');
  const [target, setTarget] = useState<{ versionId: string; impact: any[]; plans: Record<string, string> } | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    http.get(`/sites/${siteId}/deployments`, H).then(r => setDeps(r.data), e => setErr(errOf(e).message));
  }, [siteId, H, refreshKey]);

  async function prepare(versionId: string) {
    setBusy(true);
    try {
      const r = await http.get(`/sites/${siteId}/versions/${versionId}/impact`, H);
      setTarget({ versionId, impact: r.data.impact, plans: {} });
    } catch (e) { onChanged({ kind: 'err', text: errOf(e).message }); }
    finally { setBusy(false); }
  }

  async function rollback(confirm = false) {
    if (!target) return;
    setBusy(true);
    try {
      const r = await http.post(`/sites/${siteId}/rollback`, { versionId: target.versionId, plans: target.plans, confirm }, H);
      setTarget(null);
      onChanged({ kind: 'ok', text: `Rolled back. ${[...(r.data.destructive ?? []), ...(r.data.changes ?? [])].join(' ')} No data was deleted.` });
    } catch (e) {
      const er = errOf(e);
      if (er.code === 'GATE_NOT_PASSED' || er.code === 'DESTRUCTIVE_CHANGE_UNPLANNED')
        onChanged({ kind: 'warn', text: er.message, action: { label: 'Roll back anyway (keep records)', run: () => rollback(true) } });
      else onChanged({ kind: 'err', text: er.message });
    } finally { setBusy(false); }
  }

  if (err) return <div className="text-sm text-red-700">{err}</div>;
  if (!deps) return <div className="text-sm text-slate-500">Loading...</div>;
  const liveVersion = deps[0]?.version_id;
  const needsPlan = (target?.impact ?? []).filter(i => i.kind === 'state_removed' && i.count > 0);
  const planned = needsPlan.every(i => target?.plans[`${i.entity}.${i.state}`]);

  return (
    <div className="space-y-3">
      <div className="text-xs text-slate-500">Every publish and rollback, newest first. Rolling back shows its impact first and never deletes data.</div>
      {deps.map((d, i) => (
        <div key={d.id} className={`rounded-lg border p-3 text-sm ${i === 0 ? 'border-emerald-300 bg-emerald-50' : ''}`}>
          <div className="flex items-center justify-between">
            <span className="font-medium">
              {d.proof?.kind === 'rollback' || d.rollback_of ? 'Rollback' : d.proof?.seeded ? 'Seeded' : 'Publish'}
              {i === 0 && <span className="ml-2 rounded bg-emerald-600 px-1.5 text-xs text-white">LIVE</span>}
            </span>
            <span className="text-xs text-slate-500">{new Date(d.deployed_at).toLocaleString()}</span>
          </div>
          <div className="text-xs text-slate-500">by {d.deployed_by_name ?? 'system'} - version {String(d.version_id).slice(0, 8)}</div>
          {d.proof?.gate && <div className="text-xs text-emerald-700">Release Gate {d.proof.gate.passed ? 'passed' : 'overridden'}: {d.proof.gate.steps} steps, seed {d.proof.gate.seed}</div>}
          {d.proof?.replay && <div className="text-xs text-sky-700">Replay: {d.proof.replay.identical} of {d.proof.replay.sampled} past requests unchanged{d.proof.replay.reviewed ? ', reviewed' : ''}</div>}
          {d.proof?.plans && Object.keys(d.proof.plans).length > 0 && <div className="text-xs text-amber-700">Plans: {Object.entries(d.proof.plans).map(([k, v]) => `${k} ${v}`).join(', ')}</div>}
          {!!d.proof?.changes?.length && <ul className="mt-1 font-mono text-[11px]">{d.proof.changes.map((c: string) => <li key={c}>{c}</li>)}</ul>}
          {!!d.proof?.destructive?.length && <ul className="mt-1 text-[11px] text-amber-800">{d.proof.destructive.map((c: string) => <li key={c}>{c}</li>)}</ul>}

          {d.version_id !== liveVersion && target?.versionId !== d.version_id && (
            <button disabled={busy} onClick={() => prepare(d.version_id)} className="mt-2 rounded-md border px-2 py-1 text-xs">Roll back to this version</button>
          )}
          {target?.versionId === d.version_id && (
            <div className="mt-2 space-y-2 rounded border bg-white p-2">
              <div className="text-xs font-medium uppercase text-slate-400">What this rollback changes</div>
              <ImpactList items={target.impact} plans={target.plans} setPlans={p => setTarget({ ...target, plans: p })} />
              <div className="flex gap-2">
                <button disabled={busy || !planned} onClick={() => rollback()} className="rounded-md bg-slate-900 px-3 py-1 text-xs text-white disabled:opacity-40">
                  {busy ? 'Rolling back...' : 'Roll back now'}
                </button>
                <button onClick={() => setTarget(null)} className="rounded-md border px-3 py-1 text-xs">Cancel</button>
              </div>
              {!planned && <div className="text-xs text-amber-700">Choose a plan for each removed state first.</div>}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
'@

Write-Host ''
Write-Host 'Batch 8 done. Next: .\start.ps1, then pnpm test'