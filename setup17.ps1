# Axel - Batch B: repair, refurbishment and diagnostics depth (general features). Run from the axel folder.
$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding $false
function W([string]$Path, [string]$Content) {
  $full = Join-Path $PSScriptRoot $Path
  New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
  [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n").TrimStart("`n") + "`n", $enc)
  Write-Host "created $Path"
}
function Patch([string]$Path, [string]$Old, [string]$New, [switch]$Soft) {
  $full = Join-Path $PSScriptRoot $Path
  $text = [System.IO.File]::ReadAllText($full).Replace("`r`n", "`n")
  $Old = $Old.Replace("`r`n", "`n"); $New = $New.Replace("`r`n", "`n")
  if ($text.Contains($New)) { Write-Host "already patched $Path"; return }
  if (-not $text.Contains($Old)) { if ($Soft) { Write-Host "skipped (not found) $Path" -ForegroundColor Yellow; return } else { throw "patch target not found in $Path" } }
  [System.IO.File]::WriteAllText($full, $text.Replace($Old, $New), $enc)
  Write-Host "patched $Path"
}

# ============================== scripts ==============================
Patch 'package.json' @'
    "test:stage": "pnpm --filter @axel/api test:stage",
'@ @'
    "test:stage": "pnpm --filter @axel/api test:stage",
    "test:repair": "pnpm --filter @axel/api test:repair",
'@
Patch 'package.json' @'
&& pnpm test:stage"
'@ @'
&& pnpm test:stage && pnpm test:repair"
'@
Patch 'apps/api/package.json' @'
    "test:stage": "tsx --env-file=../../.env --test test/stage.test.ts",
'@ @'
    "test:stage": "tsx --env-file=../../.env --test test/stage.test.ts",
    "test:repair": "tsx --env-file=../../.env --test test/repair.test.ts",
'@

# ============================== compiler ==============================
Patch 'packages/compiler/src/types.ts' @'
  canvas?: { positions: Record<string, { x: number; y: number }> };
'@ @'
  canvas?: { positions: Record<string, { x: number; y: number }> };
  publicTracking?: { entity: string; field: string };
'@
Patch 'packages/compiler/src/types.ts' @'
  entity: string; measure: 'count' | 'sum' | 'avg'; field?: string; by?: string;
'@ @'
  entity: string; measure: 'count' | 'sum' | 'avg'; field?: string; by?: string; where?: Record<string, string>;
'@
Patch 'packages/compiler/src/compile.ts' @'
'repair.open', 'repair.close', 'notify'
'@ @'
'repair.open', 'repair.close', 'repair.test', 'notify'
'@

# Law: records pass a check stage (for example testing) before they finish
Patch 'packages/compiler/src/laws.ts' @'
  { id: 'reserved_le_on_hand', label: 'Reserved stock never exceeds on-hand' },
'@ @'
  { id: 'reserved_le_on_hand', label: 'Reserved stock never exceeds on-hand' },
  { id: 'via_state', label: 'Records pass a check stage before they finish' },
'@
Patch 'packages/compiler/src/laws.ts' @'
    case 'reachable': return `'${l.state}' can be reached in the ${l.workflow ?? 'request'} workflow`;
'@ @'
    case 'via_state': return `Every ${entLabel(bp, e)} passes '${l.via}' before it is ${l.state}`;
    case 'reachable': return `'${l.state}' can be reached in the ${l.workflow ?? 'request'} workflow`;
'@
Patch 'packages/compiler/src/laws.ts' @'
      case 'requires_state': {
'@ @'
      case 'via_state': {
        const wf = bp.workflows[e];
        if (!wf || !wf.states.includes(String(l.state)) || !wf.states.includes(String(l.via)))
          return { ...base, passed: false, dynamic: false, detail: `The ${e} workflow needs both '${l.state}' and '${l.via}' stages.` };
        const shortcut = wf.transitions.find(t => t.to === l.state && t.from !== l.via);
        if (shortcut) return { ...base, passed: false, dynamic: false, detail: `Step '${shortcut.label ?? shortcut.id}' reaches '${l.state}' from '${shortcut.from}' without passing '${l.via}'.` };
        return { ...base, passed: true, dynamic: true };
      }
      case 'requires_state': {
'@

# Module effects and preset: testing stage for PCB Repair (general repair desks)
Patch -Soft 'packages/compiler/src/modules.ts' @'
    addState(wf, 'in_repair'); addState(wf, 'closed', true); unterminal(wf, 'approved');
'@ @'
    addState(wf, 'in_repair'); addState(wf, 'testing'); addState(wf, 'closed', true); unterminal(wf, 'approved');
'@
Patch -Soft 'packages/compiler/src/modules.ts' @'
    addT(wf, { from: 'in_repair', to: 'closed', label: 'Close', roles: MG, actions: ['repair.close()'], owner_module: 'pcb-repair' });
'@ @'
    addT(wf, { from: 'in_repair', to: 'testing', label: 'Send to testing', roles: MG, owner_module: 'pcb-repair' });
    addT(wf, { from: 'testing', to: 'closed', label: 'Pass test', roles: MG, actions: ["repair.test('pass')", 'repair.close()'], owner_module: 'pcb-repair' });
    addT(wf, { from: 'testing', to: 'in_repair', label: 'Fail test - rework', roles: MG, actions: ["repair.test('fail')"], owner_module: 'pcb-repair' });
'@
Patch -Soft 'packages/compiler/src/presets.ts' @'
    name: 'Repair Shop',
    description: 'Request, approve, repair, close, return.',
'@ @'
    name: 'Repair & Refurbishment',
    description: 'Receive, approve, repair, test, close, return.',
'@
Patch -Soft 'packages/compiler/src/presets.ts' @'
        initial: 'draft', states: ['draft', 'submitted', 'approved', 'in_repair', 'closed', 'returned', 'rejected'], terminal: ['returned', 'rejected'],
'@ @'
        initial: 'draft', states: ['draft', 'submitted', 'approved', 'in_repair', 'testing', 'closed', 'returned', 'rejected', 'scrapped'], terminal: ['returned', 'rejected', 'scrapped'],
'@
Patch -Soft 'packages/compiler/src/presets.ts' @'
          { id: 't5', from: 'in_repair', to: 'closed', label: 'Close', roles: MG, actions: ['repair.close()'] },
'@ @'
          { id: 't5', from: 'in_repair', to: 'testing', label: 'Send to testing', roles: MG },
          { id: 't7', from: 'testing', to: 'closed', label: 'Pass test', roles: MG, actions: ["repair.test('pass')", 'repair.close()'] },
          { id: 't8', from: 'testing', to: 'in_repair', label: 'Fail test - rework', roles: MG, actions: ["repair.test('fail')"] },
          { id: 't9', from: 'in_repair', to: 'scrapped', label: 'Beyond economical repair', roles: MG, actions: ["repair.close('Beyond economical repair')"] },
'@
Patch -Soft 'packages/compiler/src/presets.ts' @'
      modules: ['auth', 'users', 'dashboard', 'inventory', 'request', 'approval', 'pcb-repair', 'returns', 'analytics', 'excel'],
'@ @'
      publicTracking: { entity: 'request', field: 'serial_no' },
      modules: ['auth', 'users', 'dashboard', 'inventory', 'request', 'approval', 'pcb-repair', 'returns', 'analytics', 'excel'],
'@

# ============================== API ==============================
Patch 'apps/api/src/workflow.ts' @'
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
'@ @'
      case 'repair.open':
        await tx.query(
          `INSERT INTO repairs (site_id, request_id, serial_no, fault, data, created_under_version) VALUES ($1,$2,$3,$4,$5,$6)`,
          [ctx.siteId, id, rec.serial_no ?? null, rec.fault ?? null,
           { fault_category: rec.fault_category ?? null, board_model: rec.board_model ?? null, warranty_days: 90, reworks: 0 }, ctx.versionId ?? null]);
        break;
      case 'repair.test':
        await tx.query(
          `UPDATE repairs SET data = data || jsonb_build_object('test_result', $3::text,
                    'reworks', COALESCE((data->>'reworks')::int, 0) + CASE WHEN $3::text = 'Fail' THEN 1 ELSE 0 END),
                  row_version = row_version + 1, updated_at = now()
            WHERE site_id = $1 AND request_id = $2 AND state <> 'closed'`,
          [ctx.siteId, id, String(args[0] ?? '').toLowerCase() === 'fail' ? 'Fail' : 'Pass']);
        break;
      case 'repair.close':
        await tx.query(
          `UPDATE repairs SET state = 'closed', closed_at = now(), row_version = row_version + 1, updated_at = now(),
                  data = data || jsonb_build_object('outcome', COALESCE($3::text, data->>'outcome', 'Repaired'))
            WHERE site_id = $1 AND request_id = $2 AND state <> 'closed'`,
          [ctx.siteId, id, args[0] != null ? String(args[0]) : null]);
        break;
'@

Patch 'apps/api/src/laws.ts' @'
    case 'site_isolation': {
'@ @'
    case 'via_state': {
      if (raw?.entity !== 'request') return null;
      const r = (await c.query(
        `SELECT e.record_id FROM audit_events e
          WHERE e.entity = 'request' AND e.kind = 'transition' AND e.to_state = $1
            AND NOT EXISTS (SELECT 1 FROM audit_events v WHERE v.entity = 'request' AND v.record_id = e.record_id
                              AND v.kind = 'transition' AND v.to_state = $2 AND v.at <= e.at)
          LIMIT 1`, [raw.state, raw.via])).rows[0];
      return r ? `Request ${String(r.record_id).slice(0, 8)} reached '${raw.state}' without passing '${raw.via}'.` : null;
    }
    case 'site_isolation': {
'@

Patch 'apps/api/src/analytics.ts' @'
  for (const k of [widget.field, widget.by]) {
'@ @'
  for (const k of [widget.field, widget.by, ...Object.keys((widget as any).where ?? {})]) {
'@
Patch 'apps/api/src/analytics.ts' @'
    const rec = compiled.computeFormulas(widget.entity, toRecord(widget.entity, row));
'@ @'
    const rec = compiled.computeFormulas(widget.entity, toRecord(widget.entity, row));
    const where = (widget as any).where as Record<string, string> | undefined;
    if (where && Object.entries(where).some(([k, v]) => String(rec[k] ?? '') !== String(v))) continue;
    if (widget.measure === 'avg' && widget.field && (rec[widget.field] == null || rec[widget.field] === '')) continue;
'@

W 'apps/api/src/timeline.ts' @'
import { Router } from 'express';
import { z } from 'zod';
import { withSite } from './db';
import { TABLES, toRecord } from './entities';
import { AxelError, ah } from './errors';

// GET /api/:siteId/timeline?serial=  - the whole life of one board, inside this unit only, plus its passport.
export const timeline = Router({ mergeParams: true });
const DAY = 86400000;

timeline.get('/timeline', ah(async (req, res) => {
  const serial = z.string().trim().min(1).max(100).parse(req.query.serial);
  const s = req.site!;
  const bp = s.compiled.blueprint;
  const ents = Object.entries(bp.entities).filter(([k, e]) => TABLES[k] && e.fields.some(f => f.key === 'serial_no'));
  if (!ents.length) throw new AxelError('ENTITY_NOT_IN_SITE', 404, 'This unit does not track serial numbers.');
  const out = await withSite(s.ctx, async c => {
    const records: { entity: string; label: string; rec: Record<string, unknown> }[] = [];
    const repairRows: any[] = [];
    for (const [ek, e] of ents) {
      const spec = TABLES[ek];
      const col = spec.core.includes('serial_no') ? 'serial_no' : `data->>'serial_no'`;
      const rows = (await c.query(`SELECT * FROM ${spec.table} WHERE lower(${col}) = lower($1) ORDER BY created_at`, [serial])).rows;
      for (const r of rows) {
        records.push({ entity: ek, label: e.label ?? ek, rec: s.compiled.mask(ek, s.role, s.compiled.computeFormulas(ek, toRecord(ek, r))) });
        if (ek === 'repair') repairRows.push(r);
      }
    }
    const ids = records.map(r => String(r.rec.id));
    const events = ids.length ? (await c.query(
      `SELECT e.entity, e.record_id, e.kind, e.from_state, e.to_state, e.actor_role, e.at, u.name AS actor_name
         FROM audit_events e LEFT JOIN users u ON u.id = e.actor_id WHERE e.record_id = ANY($1) ORDER BY e.at, e.id`, [ids])).rows : [];
    const moves = ids.length ? (await c.query(
      `SELECT m.kind, m.qty, m.reason, m.at, i.name AS item FROM stock_movements m JOIN items i ON i.id = m.item_id
        WHERE m.ref_id = ANY($1) ORDER BY m.id`, [ids])).rows : [];
    return { records, events, moves, repairRows };
  });

  const history = out.repairRows
    .map(r => ({
      request_id: r.request_id, closed_at: r.closed_at, outcome: r.data?.outcome ?? null, reworks: Number(r.data?.reworks ?? 0),
      warranty_until: r.closed_at ? new Date(+new Date(r.closed_at) + Number(r.data?.warranty_days ?? 90) * DAY).toISOString() : null,
      parts: r.data?.parts_replaced ?? null,
    }))
    .sort((a, b) => +new Date(b.closed_at ?? 0) - +new Date(a.closed_at ?? 0));
  const last = history.find(h => h.closed_at);
  const passport = {
    requests: out.records.filter(r => r.entity === 'request').length,
    repairs: history.length,
    reworks: history.reduce((n, h) => n + h.reworks, 0),
    lastClosedAt: last?.closed_at ?? null,
    lastOutcome: last?.outcome ?? null,
    warrantyUntil: last?.warranty_until ?? null,
    underWarranty: !!last?.warranty_until && new Date(last.warranty_until) > new Date(),
    parts: history.map(h => h.parts).filter(Boolean),
    history: history.filter(h => h.closed_at),
  };
  res.json({ serial, records: out.records, events: out.events, moves: out.moves, passport });
}));
'@

W 'apps/api/src/public.ts' @'
import { Router } from 'express';
import { z } from 'zod';
import { pool, withSite } from './db';
import { getPublished } from './blueprints';
import { TABLES } from './entities';
import { AxelError, ah } from './errors';

// Public tracking (role: Public). Any unit can enable it with blueprint.publicTracking.
// Returns only the stage and dates: no names, prices or notes.
export const publicRouter = Router();
const KEY = /^[a-z_][a-z0-9_]*$/;

publicRouter.get('/track-units', ah(async (_req, res) => {
  const sites = (await pool.query('SELECT id, slug, name FROM sites ORDER BY name')).rows;
  const out: { slug: string; name: string; label: string }[] = [];
  for (const s of sites) {
    const pt = (await getPublished(s.id))?.compiled.blueprint;
    const t = pt?.publicTracking;
    if (t) out.push({ slug: s.slug, name: s.name, label: pt!.entities[t.entity]?.fields.find(f => f.key === t.field)?.label ?? 'Reference' });
  }
  res.json(out);
}));

publicRouter.get('/track/:slug', ah(async (req, res) => {
  const ref = z.string().trim().min(3).max(60).parse(req.query.ref);
  const none = new AxelError('NOT_FOUND', 404, 'Nothing found with that reference. Check it and try again.');
  const site = (await pool.query('SELECT id, name FROM sites WHERE slug = $1', [req.params.slug])).rows[0];
  if (!site) throw none;
  const bp = (await getPublished(site.id))?.compiled.blueprint;
  const pt = bp?.publicTracking;
  if (!bp || !pt || !KEY.test(pt.field)) throw none;
  const spec = TABLES[pt.entity];
  const wf = bp.workflows[pt.entity];
  if (!spec || !wf || !bp.entities[pt.entity]?.fields.some(f => f.key === pt.field)) throw none;
  const col = spec.core.includes(pt.field) ? pt.field : `data->>'${pt.field}'`;
  const out = await withSite({ siteId: site.id, userId: '', role: 'Public' }, async c => {
    const r = (await c.query(`SELECT id, state, created_at, updated_at FROM ${spec.table} WHERE lower(${col}) = lower($1) ORDER BY created_at DESC LIMIT 1`, [ref])).rows[0];
    if (!r) return null;
    const steps = (await c.query(
      `SELECT to_state, at FROM audit_events WHERE entity = $1 AND record_id = $2 AND kind = 'transition' ORDER BY at`, [pt.entity, r.id])).rows;
    return { state: r.state as string, received: r.created_at, updated: r.updated_at, steps };
  });
  if (!out) throw none;
  const states = wf.states.filter(st => !['rejected', 'scrapped'].includes(st) || st === out.state);
  res.json({ unit: site.name, ref, ...out, states });
}));
'@

Patch 'apps/api/src/server.ts' @'
import { timeline } from './timeline';
'@ @'
import { timeline } from './timeline';
import { publicRouter } from './public';
'@
Patch 'apps/api/src/server.ts' @'
app.use('/api/hub', hubRouter);
'@ @'
app.use('/api/public', publicRouter);
app.use('/api/hub', hubRouter);
'@

# ============================== seed: Service Centre as a repair desk ==============================
Patch 'apps/api/seed/blueprints.ts' @'
const R4 = ['Public', 'Member', 'Manager', 'Admin'] as Blueprint['roles'];
'@ @'
const FAULTS = ['No power', 'Short circuit', 'Component failure', 'Trace/pad damage', 'Solder joint', 'Firmware', 'Liquid damage', 'Other'];
const R4 = ['Public', 'Member', 'Manager', 'Admin'] as Blueprint['roles'];
'@
Patch 'apps/api/seed/blueprints.ts' @'
  configVersion: 3, siteId: SITE_IDS['service-centre'], slug: 'service-centre', name: 'Service Centre',
'@ @'
  configVersion: 3, siteId: SITE_IDS['service-centre'], slug: 'service-centre', name: 'Service Centre',
  publicTracking: { entity: 'request', field: 'serial_no' },
'@
Patch 'apps/api/seed/blueprints.ts' @'
      { key: 'serial_no', type: 'text', label: 'Board serial', unique: true, owner_module: 'pcb-repair', reason: 'board identity' },
      { key: 'fault', type: 'text', label: 'Fault reported', required: true },
'@ @'
      { key: 'serial_no', type: 'text', label: 'Board serial', owner_module: 'pcb-repair', reason: 'board identity' },
      { key: 'board_model', type: 'text', label: 'Board model' },
      { key: 'customer', type: 'text', label: 'Customer' },
      { key: 'fault', type: 'text', label: 'Fault reported', required: true },
      { key: 'fault_category', type: 'select', label: 'Fault category', options: FAULTS },
'@
Patch 'apps/api/seed/blueprints.ts' @'
    repair: { owner_module: 'pcb-repair', label: 'Repair log', fields: [
      { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
      { key: 'serial_no', type: 'text', label: 'Serial' },
      { key: 'fault', type: 'text', label: 'Fault' },
      { key: 'diagnosis', type: 'text', label: 'Diagnosis' },
    ] },
'@ @'
    repair: { owner_module: 'pcb-repair', label: 'Repair log', fields: [
      { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
      { key: 'serial_no', type: 'text', label: 'Serial' },
      { key: 'board_model', type: 'text', label: 'Board model' },
      { key: 'fault', type: 'text', label: 'Fault' },
      { key: 'fault_category', type: 'select', label: 'Fault category', options: FAULTS },
      { key: 'diagnosis', type: 'text', label: 'Diagnosis' },
      { key: 'root_cause', type: 'text', label: 'Root cause' },
      { key: 'parts_replaced', type: 'text', label: 'Parts replaced' },
      { key: 'firmware_version', type: 'text', label: 'Firmware version' },
      { key: 'technician', type: 'text', label: 'Technician' },
      { key: 'bench_hours', type: 'number', label: 'Bench hours', min: 0 },
      { key: 'test_result', type: 'select', label: 'Test result', options: ['Pass', 'Fail', 'Not tested'] },
      { key: 'reworks', type: 'number', label: 'Rework rounds', system: true },
      { key: 'outcome', type: 'select', label: 'Outcome', options: ['Repaired', 'Refurbished', 'Beyond economical repair', 'Scrapped'] },
      { key: 'warranty_days', type: 'number', label: 'Warranty (days)', min: 0, default: 90 },
    ] },
'@
Patch 'apps/api/seed/blueprints.ts' @'
      states: ['draft', 'submitted', 'approved', 'in_repair', 'closed', 'returned', 'rejected'],
'@ @'
      states: ['draft', 'submitted', 'approved', 'in_repair', 'testing', 'closed', 'returned', 'rejected', 'scrapped'],
'@
Patch 'apps/api/seed/blueprints.ts' @'
        { id: 't5', from: 'in_repair', to: 'closed', label: 'Close', roles: ['Manager', 'Admin'], actions: ['repair.close()'] },
'@ @'
        { id: 't5', from: 'in_repair', to: 'testing', label: 'Send to testing', roles: ['Manager', 'Admin'] },
        { id: 't7', from: 'testing', to: 'closed', label: 'Pass test', roles: ['Manager', 'Admin'], actions: ["repair.test('pass')", 'repair.close()'] },
        { id: 't8', from: 'testing', to: 'in_repair', label: 'Fail test - rework', roles: ['Manager', 'Admin'], actions: ["repair.test('fail')"] },
        { id: 't9', from: 'in_repair', to: 'scrapped', label: 'Beyond economical repair', roles: ['Manager', 'Admin'], actions: ["repair.close('Beyond economical repair')"] },
'@
Patch 'apps/api/seed/blueprints.ts' @'
        { id: 't6', from: 'closed', to: 'returned', label: 'Return to customer', roles: ['Member', 'Manager', 'Admin'], actions: ['stock.return(item_id, qty)'] },
'@ @'
        { id: 't6', from: 'closed', to: 'returned', label: 'Return to customer', roles: ['Member', 'Manager', 'Admin'], owner_module: 'returns' },
'@
Patch 'apps/api/seed/blueprints.ts' @'
      terminal: ['returned', 'rejected'],
'@ @'
      terminal: ['returned', 'rejected', 'scrapped'],
'@
Patch 'apps/api/seed/blueprints.ts' @'
    { id: 'l4', template: 'reachable', workflow: 'request', state: 'closed' }],
'@ @'
    { id: 'l4', template: 'reachable', workflow: 'request', state: 'closed' },
    { id: 'l6', template: 'via_state', entity: 'request', state: 'closed', via: 'testing' }],
'@
Patch 'apps/api/seed/blueprints.ts' @'
    { path: '/requests', title: 'Repair board', view: 'kanban', entity: 'request', groupBy: 'state', columns: ['serial_no', 'fault', 'priority', 'qty', 'total'] },
    { path: '/repairs', title: 'Repair logs', view: 'table', entity: 'repair', columns: ['serial_no', 'fault', 'diagnosis', 'state'], roles: ['Manager', 'Admin'] },
'@ @'
    { path: '/requests', title: 'Repair board', view: 'kanban', entity: 'request', groupBy: 'state', columns: ['serial_no', 'board_model', 'fault_category', 'priority', 'total'] },
    { path: '/repairs', title: 'Repair logs', view: 'table', entity: 'repair', columns: ['serial_no', 'board_model', 'fault_category', 'test_result', 'reworks', 'outcome', 'bench_hours', 'state'], roles: ['Manager', 'Admin'] },
'@
Patch 'apps/api/seed/blueprints.ts' @'
      { id: 'w1', type: 'bar', title: 'Requests by state', entity: 'request', measure: 'count', by: 'state' },
      { id: 'w2', type: 'pie', title: 'By priority', entity: 'request', measure: 'count', by: 'priority' },
'@ @'
      { id: 'w3', type: 'stat', title: 'Boards in repair', entity: 'request', measure: 'count', where: { state: 'in_repair' } },
      { id: 'w4', type: 'stat', title: 'Waiting for testing', entity: 'request', measure: 'count', where: { state: 'testing' } },
      { id: 'w5', type: 'stat', title: 'Passed test first time', entity: 'repair', measure: 'count', where: { test_result: 'Pass', reworks: '0' } },
      { id: 'w6', type: 'stat', title: 'Average bench hours', entity: 'repair', measure: 'avg', field: 'bench_hours' },
      { id: 'w1', type: 'bar', title: 'Requests by stage', entity: 'request', measure: 'count', by: 'state' },
      { id: 'w7', type: 'bar', title: 'Faults by category', entity: 'request', measure: 'count', by: 'fault_category' },
      { id: 'w8', type: 'pie', title: 'Repair outcomes', entity: 'repair', measure: 'count', by: 'outcome' },
      { id: 'w2', type: 'pie', title: 'By priority', entity: 'request', measure: 'count', by: 'priority' },
'@

Patch 'apps/api/seed/seed.ts' @'
        if (bp.slug === 'service-centre') Object.assign(data, { serial_no: `PCB-${24000 + i}`, fault: ['No power', 'Display dead', 'Relay chatter', 'Overheating'][i % 4], priority: ['low', 'normal', 'urgent'][i % 3] });
'@ @'
        if (bp.slug === 'service-centre') Object.assign(data, {
          serial_no: `PCB-${24000 + (i === 8 ? 7 : i)}`,
          fault: ['No power', 'Display dead', 'Relay chatter', 'Overheating'][i % 4],
          fault_category: ['No power', 'Component failure', 'Solder joint', 'Short circuit', 'Firmware'][i % 5],
          board_model: ['MCB-200 controller', 'PSU-48V', 'VFD drive card', 'HMI panel board'][i % 4],
          customer: ['Acme Pumps', 'Bharat Textiles', 'Metro Elevators', 'Sunrise Plastics'][i % 4],
          priority: ['low', 'normal', 'urgent'][i % 3],
        });
'@
Patch 'apps/api/seed/seed.ts' @'
await runLifecycle(blueprints, SITE_IDS, managerIds);
'@ @'
await runLifecycle(blueprints, SITE_IDS, managerIds);
// Service Centre: fill in diagnosis details on the repair logs the lifecycle opened.
await withSite({ siteId: SITE_IDS['service-centre'], userId: admin, role: 'Admin' }, async tx => {
  const reps = (await tx.query('SELECT id FROM repairs ORDER BY opened_at')).rows;
  for (const [k, r] of reps.entries())
    await tx.query('UPDATE repairs SET diagnosis = $2, data = data || $3 WHERE id = $1', [r.id,
      ['Dry solder joint on regulator', 'Failed MOSFET on output stage', 'Corroded trace near connector', 'Corrupt firmware image'][k % 4],
      { root_cause: ['Thermal cycling', 'Overcurrent event', 'Moisture ingress', 'Power loss during update'][k % 4],
        parts_replaced: ['U3 regulator', 'Q2 MOSFET, R14', 'Jumper wire on trace 7', 'None (reflashed)'][k % 4],
        firmware_version: `v2.${k + 1}.0`, technician: ['Ravi', 'Neha', 'Imran'][k % 3], bench_hours: 1.5 + (k % 4) }]);
});
'@
Patch 'apps/api/seed/lifecycle.ts' @'
      const steps = i === submitted.length - 1 && wf.transitions.some(t => t.to === 'rejected') ? ['rejected'] : path.slice(0, i % (path.length + 1));
'@ @'
      const closedAt = path.indexOf('closed');
      const depth = [0, 1, 2, closedAt >= 0 ? closedAt + 1 : path.length][i % 4] ?? 0;
      const steps = i === submitted.length - 1 && wf.transitions.some(t => t.to === 'rejected') ? ['rejected'] : path.slice(0, Math.min(depth, path.length));
'@

# Demo spreadsheet: board model, customer and fault category columns (added at the end)
Patch -Soft 'apps/api/scripts/gen-registers.ts' @'
  const flow = ['Pending', 'Sanctioned', 'Repairing', 'Closed', 'Returned', 'Rejected'];
'@ @'
  const flow = ['Pending', 'Sanctioned', 'Repairing', 'Testing', 'Closed', 'Returned', 'Rejected'];
'@
Patch -Soft 'apps/api/scripts/gen-registers.ts' @'
    { header: 'Unit Price', width: 12 }, { header: 'Total', width: 12 }, { header: 'Returned On', width: 12 },
'@ @'
    { header: 'Unit Price', width: 12 }, { header: 'Total', width: 12 }, { header: 'Returned On', width: 12 },
    { header: 'Board Model', width: 18 }, { header: 'Customer', width: 18 }, { header: 'Fault Category', width: 18 },
'@
Patch -Soft 'apps/api/scripts/gen-registers.ts' @'
      status, status === 'Pending' ? null : pick(['Priya', 'Rahul']), price, null, status === 'Returned' ? day(i % 25) : null]);
'@ @'
      status, status === 'Pending' ? null : pick(['Priya', 'Rahul']), price, null, status === 'Returned' ? day(i % 25) : null,
      pick(['MCB-200 controller', 'PSU-48V', 'VFD drive card', 'HMI panel board']), pick(['Acme Pumps', 'Bharat Textiles', 'Metro Elevators', 'Sunrise Plastics']),
      pick(['No power', 'Short circuit', 'Component failure', 'Trace/pad damage', 'Solder joint', 'Firmware'])]);
'@

# ============================== tests ==============================
W 'apps/api/test/repair.test.ts' @'
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { finishLogin } from './otp';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const SC = '22222222-2222-4222-8222-222222222222';
let admin = '', manager = '';

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  return (await finishLogin(r)) as string;
}
async function call(token: string, method: string, path: string, body?: unknown) {
  const r = await fetch(`${API}${path}`, {
    method, headers: { authorization: `Bearer ${token}`, 'x-site-id': SC, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}
before(async () => { [admin, manager] = await Promise.all(['admin@axel.dev', 'manager@sc.dev'].map(login)); });

test('a shortcut that skips testing is blocked by a Law', async () => {
  const b = await call(admin, 'GET', `/sites/${SC}/builder`);
  const bp = structuredClone(b.body.published.config);
  bp.workflows.request.transitions.push({ id: 't99', from: 'in_repair', to: 'closed', label: 'Quick close', roles: ['Manager', 'Admin'] });
  const d = await call(admin, 'POST', `/sites/${SC}/versions`, { config: bp, reason: 'repair test' });
  try {
    const g = await call(admin, 'POST', `/sites/${SC}/versions/${d.body.id}/gate`, { steps: 30 });
    assert.equal(g.body.passed, false);
    assert.ok(g.body.laws.some((l: any) => l.template === 'via_state' && !l.passed), JSON.stringify(g.body.laws));
  } finally { await call(admin, 'DELETE', `/sites/${SC}/versions/${d.body.id}`); }
});

test('fail test sends a board back for rework; pass test closes it with outcome', async t => {
  const req = (await call(manager, 'GET', `/${SC}/requests?filter%5Bstate%5D=approved`)).body.rows?.[0];
  if (!req) return t.skip('no approved requests; run pnpm seed');
  const go = async (to: string) => {
    const r = await call(manager, 'POST', `/${SC}/requests/${req.id}/transition`, { to, idempotencyKey: `rp-${req.id}-${to}-${Math.random()}` });
    assert.ok(r.status === 201, `${to}: ${JSON.stringify(r.body)}`);
  };
  for (const to of ['in_repair', 'testing', 'in_repair', 'testing', 'closed']) await go(to);
  const reps = (await call(manager, 'GET', `/${SC}/repairs?limit=200`)).body.rows;
  const rep = reps.find((r: any) => r.request_id === req.id);
  assert.ok(rep, 'repair log exists');
  assert.equal(rep.test_result, 'Pass');
  assert.equal(rep.reworks, 1);
  assert.equal(rep.outcome, 'Repaired');
  assert.equal(rep.state, 'closed');
});

test('public tracking shows only the stage, never private data', async () => {
  const r = await fetch(`${API}/public/track/service-centre?ref=PCB-24007`);
  const b: any = await r.json();
  assert.equal(r.status, 200, JSON.stringify(b));
  assert.ok(b.state && Array.isArray(b.states));
  for (const k of ['unit_price', 'total', 'customer', 'requested_by', 'id']) assert.ok(!(k in b), `leaked ${k}`);
  assert.equal((await fetch(`${API}/public/track/service-centre?ref=NOPE-000`)).status, 404);
  assert.equal((await fetch(`${API}/public/track/distribution?ref=PCB-24007`)).status, 404);
});

test('board passport counts repeat visits', async () => {
  const r = await call(manager, 'GET', `/${SC}/timeline?serial=PCB-24007`);
  assert.equal(r.status, 200);
  assert.ok(r.body.passport.requests >= 2, JSON.stringify(r.body.passport));
  assert.ok(r.body.passport.history.length >= 1);
});
'@

# ============================== web ==============================
Patch -Soft 'apps/web/src/renderer/fields.tsx' @'
  rejected: ['bg-rose-50 text-rose-700 ring-rose-600/20', 'bg-rose-500'],
'@ @'
  rejected: ['bg-rose-50 text-rose-700 ring-rose-600/20', 'bg-rose-500'],
  testing: ['bg-indigo-50 text-indigo-700 ring-indigo-600/20', 'bg-indigo-500'],
  scrapped: ['bg-zinc-100 text-zinc-600 ring-zinc-500/20', 'bg-zinc-500'],
'@

W 'apps/web/src/renderer/passport.tsx' @'
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { RotateCcw, ShieldAlert } from 'lucide-react';
import { site } from '../api';
import { useSite } from '../hooks';
import { card } from './fields';

const d = (v?: string | null) => (v ? new Date(v).toLocaleDateString() : '-');

export function Passport({ p }: { p: any }) {
  const cell = 'rounded-xl bg-slate-50 p-4 ring-1 ring-inset ring-slate-200';
  return (
    <div className={`${card} p-5`}>
      <div className="mb-4 text-sm font-semibold text-slate-900">Board passport</div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className={cell}><div className="text-xs text-slate-500">Visits</div><div className="mt-1 text-2xl font-semibold text-slate-900">{p.requests}</div><div className="text-xs text-slate-500">{p.repairs} repair log{p.repairs === 1 ? '' : 's'}</div></div>
        <div className={cell}><div className="text-xs text-slate-500">Rework rounds</div><div className="mt-1 text-2xl font-semibold text-slate-900">{p.reworks}</div><div className="text-xs text-slate-500">after a failed test</div></div>
        <div className={cell}><div className="text-xs text-slate-500">Last outcome</div><div className="mt-1 text-base font-semibold text-slate-900">{p.lastOutcome ?? '-'}</div><div className="text-xs text-slate-500">closed {d(p.lastClosedAt)}</div></div>
        <div className={`rounded-xl p-4 ring-1 ring-inset ${p.underWarranty ? 'bg-emerald-50 ring-emerald-200' : 'bg-slate-50 ring-slate-200'}`}>
          <div className="text-xs text-slate-500">Warranty</div>
          <div className={`mt-1 text-base font-semibold ${p.underWarranty ? 'text-emerald-700' : 'text-slate-900'}`}>{p.underWarranty ? 'Active' : p.warrantyUntil ? 'Expired' : '-'}</div>
          <div className="text-xs text-slate-500">{p.warrantyUntil ? `until ${d(p.warrantyUntil)}` : 'no completed repair yet'}</div>
        </div>
      </div>
      {!!p.parts?.length && (
        <div className="mt-4 flex flex-wrap items-center gap-1.5 text-xs">
          <span className="text-slate-500">Parts replaced:</span>
          {p.parts.map((x: string, i: number) => <span key={i} className="rounded-md bg-slate-100 px-1.5 py-0.5 text-slate-700">{x}</span>)}
        </div>
      )}
    </div>
  );
}

export function RepeatBanner({ serial, recId }: { serial: string; recId: string }) {
  const { siteId, base } = useSite();
  const q = useQuery({ queryKey: ['timeline', siteId, serial], queryFn: () => site.get(siteId, '/timeline', { serial }) });
  const prev = (q.data?.passport?.history ?? []).filter((h: any) => h.request_id !== recId);
  if (!prev.length) return null;
  const last = prev[0];
  const inW = !!last.warranty_until && new Date(last.warranty_until) > new Date();
  return (
    <div className={`flex gap-3 rounded-xl border px-4 py-3 text-sm ${inW ? 'border-rose-200 bg-rose-50 text-rose-900' : 'border-amber-200 bg-amber-50 text-amber-900'}`}>
      {inW ? <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0 text-rose-500" /> : <RotateCcw className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />}
      <div>
        <div className="font-semibold">{inW ? 'Repeat failure under warranty' : 'This board has been here before'}</div>
        <div className="mt-0.5">
          {prev.length} earlier repair{prev.length === 1 ? '' : 's'}. Last closed on {d(last.closed_at)} ({last.outcome ?? 'Repaired'}){inW ? `; warranty runs until ${d(last.warranty_until)}` : ''}.
        </div>
        <Link to={`${base}/timeline?serial=${encodeURIComponent(serial)}`} className="mt-1 inline-block font-medium underline underline-offset-4">See the board history</Link>
      </div>
    </div>
  );
}
'@

Patch 'apps/web/src/renderer/RecordDetail.tsx' @'
import { RecordForm } from './RecordForm';
'@ @'
import { RecordForm } from './RecordForm';
import { RepeatBanner } from './passport';
'@
Patch 'apps/web/src/renderer/RecordDetail.tsx' @'
        {!!transitions.length && (
'@ @'
        {rec.serial_no && entity === 'request' && <RepeatBanner serial={String(rec.serial_no)} recId={String(rec.id)} />}
        {!!transitions.length && (
'@

Patch 'apps/web/src/renderer/SerialTimeline.tsx' @'
import { Denial, StateBadge, btn } from './fields';
'@ @'
import { Denial, StateBadge, btn } from './fields';
import { Passport } from './passport';
'@
Patch 'apps/web/src/renderer/SerialTimeline.tsx' @'
      {q.data && !q.data.records.length && <div className="text-sm text-slate-500">No record in this unit has serial {serial}.</div>}
'@ @'
      {q.data && !q.data.records.length && <div className="text-sm text-slate-500">No record in this unit has serial {serial}.</div>}
      {!!q.data?.records.length && q.data.passport && <Passport p={q.data.passport} />}
'@

W 'apps/web/src/pages/Track.tsx' @'
import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Check, Search } from 'lucide-react';

const FRIENDLY: Record<string, [string, string]> = {
  draft: ['Registered', 'We have recorded your item.'],
  submitted: ['Received', 'Your item is with us and waiting for approval.'],
  approved: ['Approved', 'Approved for repair and waiting for a technician.'],
  assigned: ['Assigned', 'Assigned to a technician.'],
  in_repair: ['In repair', 'A technician is working on it.'],
  testing: ['Testing', 'The repair is being tested.'],
  closed: ['Ready', 'Repair complete and tested.'],
  returned: ['Returned', 'Sent back to you.'],
  rejected: ['Not accepted', 'This item was not accepted. Please contact us.'],
  scrapped: ['Beyond economical repair', 'A repair would cost more than it is worth. Please contact us.'],
};
const label = (s: string) => FRIENDLY[s]?.[0] ?? s.replace(/_/g, ' ');

export default function Track() {
  const { slug } = useParams();
  const [units, setUnits] = useState<{ slug: string; name: string; label: string }[]>([]);
  const [unit, setUnit] = useState(slug ?? '');
  const [ref, setRef] = useState('');
  const [res, setRes] = useState<any>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    fetch('/api/public/track-units').then(r => r.json()).then(u => { setUnits(u); if (!slug && u[0]) setUnit(u[0].slug); }).catch(() => {});
  }, [slug]);
  const current = units.find(u => u.slug === unit);

  async function search(e: React.FormEvent) {
    e.preventDefault();
    setErr(''); setRes(null); setBusy(true);
    try {
      const r = await fetch(`/api/public/track/${unit}?ref=${encodeURIComponent(ref.trim())}`);
      const j = await r.json();
      if (!r.ok) setErr(j.message ?? 'Nothing found.'); else setRes(j);
    } catch { setErr('Could not reach the server.'); } finally { setBusy(false); }
  }
  const reached = (s: string) => res?.steps?.filter((x: any) => x.to_state === s).slice(-1)[0]?.at;
  const idx = res ? res.states.indexOf(res.state) : -1;

  return (
    <div className="relative flex min-h-screen items-center justify-center overflow-hidden bg-slate-50 px-4 py-12">
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_top,rgba(13,148,136,0.12),transparent_60%)]" />
      <div className="relative w-full max-w-md space-y-6">
        <div className="flex flex-col items-center text-center">
          <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-slate-900 text-lg font-bold text-white shadow-lg">A</span>
          <h1 className="mt-5 text-2xl font-semibold tracking-tight text-slate-900">Track a repair</h1>
          <p className="mt-1 text-sm text-slate-500">No sign-in needed. Only the progress is shown.</p>
        </div>

        <form onSubmit={search} className="space-y-4 rounded-2xl border border-slate-200 bg-white p-6 shadow-xl shadow-slate-900/5">
          {units.length > 1 && !slug && (
            <label className="block">
              <span className="mb-1.5 block text-sm font-medium text-slate-700">Service desk</span>
              <select value={unit} onChange={e => setUnit(e.target.value)} className="w-full rounded-lg border border-slate-200 bg-white px-3 py-2.5 text-sm shadow-sm">
                {units.map(u => <option key={u.slug} value={u.slug}>{u.name}</option>)}
              </select>
            </label>
          )}
          <label className="block">
            <span className="mb-1.5 block text-sm font-medium text-slate-700">{current?.label ?? 'Serial number'}{current ? ` - ${current.name}` : ''}</span>
            <input value={ref} onChange={e => setRef(e.target.value)} placeholder="e.g. PCB-24007" autoFocus
              className="w-full rounded-lg border border-slate-200 bg-white px-3 py-2.5 text-sm shadow-sm outline-none focus:border-slate-400 focus:ring-4 focus:ring-slate-100" />
          </label>
          {!units.length && <div className="rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-500">No service desk has public tracking switched on.</div>}
          {err && <div className="rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700">{err}</div>}
          <button disabled={busy || !unit || ref.trim().length < 3} className="inline-flex w-full items-center justify-center gap-2 rounded-lg bg-slate-900 py-2.5 text-sm font-medium text-white shadow-sm transition hover:bg-slate-800 disabled:opacity-50">
            <Search className="h-4 w-4" />{busy ? 'Looking...' : 'Track'}
          </button>
        </form>

        {res && (
          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <div className="text-xs font-semibold uppercase tracking-wider text-slate-400">{res.unit}</div>
            <div className="mt-1 text-lg font-semibold text-slate-900">{res.ref}: {label(res.state)}</div>
            <div className="text-sm text-slate-500">{FRIENDLY[res.state]?.[1]}</div>
            <ol className="mt-5 space-y-3">
              {res.states.map((s: string, i: number) => {
                const done = i < idx, now = i === idx;
                const at = reached(s) ?? (i === 0 ? res.received : null);
                return (
                  <li key={s} className="flex items-center gap-3">
                    <span className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold ${done ? 'bg-slate-900 text-white' : now ? 'bg-white text-slate-900 ring-2 ring-slate-900' : 'bg-slate-100 text-slate-400'}`}>
                      {done ? <Check className="h-3.5 w-3.5" /> : i + 1}
                    </span>
                    <span className={`flex-1 text-sm ${now ? 'font-semibold text-slate-900' : done ? 'text-slate-700' : 'text-slate-400'}`}>{label(s)}</span>
                    <span className="text-xs text-slate-400">{(done || now) && at ? new Date(at).toLocaleDateString() : ''}</span>
                  </li>
                );
              })}
            </ol>
            <div className="mt-4 border-t border-slate-100 pt-3 text-xs text-slate-400">Last update: {new Date(res.updated).toLocaleString()}</div>
          </div>
        )}

        <div className="text-center"><Link to="/login" className="inline-flex items-center gap-1 text-sm text-slate-500 hover:text-slate-900"><ArrowLeft className="h-4 w-4" />Staff sign-in</Link></div>
      </div>
    </div>
  );
}
'@

Patch 'apps/web/src/App.tsx' @'
import Builder from './builder/Builder';
'@ @'
import Builder from './builder/Builder';
import Track from './pages/Track';
'@
Patch 'apps/web/src/App.tsx' @'
      <Route path="/builder/:siteId"
'@ @'
      <Route path="/track" element={<Track />} />
      <Route path="/track/:slug" element={<Track />} />
      <Route path="/builder/:siteId"
'@
Patch -Soft 'apps/web/src/pages/Login.tsx' @'
import { useNavigate } from 'react-router-dom';
'@ @'
import { Link, useNavigate } from 'react-router-dom';
'@
Patch -Soft 'apps/web/src/pages/Login.tsx' @'
          <span>PS 03 - Team Breaking Bytes</span>
        </div>
'@ @'
          <span>PS 03 - Team Breaking Bytes</span>
        </div>
        <div className="text-center"><Link to="/track" className="text-sm font-medium text-slate-600 underline-offset-4 hover:text-slate-900 hover:underline">Track a repair without signing in</Link></div>
'@

# ============================== docs ==============================
Patch -Soft 'README.md' @'
## How Axel compares
'@ @'
## Repair, refurbishment and diagnostics

Service units get the depth a repair business runs on, built as general Blueprint features any unit can switch on:

- **Check stage with a rework loop:** received, approved, in repair, **testing**, closed, returned. A failed test sends the job back for rework; "beyond economical repair" ends it. A Law (`via_state`) guarantees nothing closes without passing testing, and the Release Gate blocks any shortcut.
- **Diagnosis record:** fault category, board model, root cause, parts replaced, firmware version, technician, bench hours, test result, rework rounds, outcome and warranty. Test result, reworks and outcome are filled in by the workflow itself.
- **Repeat-failure and warranty warning** when a serial number comes back, and a **board passport** (visits, reworks, last outcome, warranty, parts) on the board history.
- **Repair analytics:** boards in repair, waiting for testing, first-time test passes, average bench hours, faults by category, outcomes. Dashboard widgets can now filter (`where`).
- **Public tracking:** any unit can set `publicTracking`; customers open `/track`, enter a serial number and see only the stage and dates, never names, prices or notes.

## How Axel compares
'@
Patch -Soft 'docs/API.md' @'
| GET | `/api/sites/:siteId/render-schema` |
'@ @'
| GET | `/api/public/track-units` | anyone | units that have public tracking switched on |
| GET | `/api/public/track/:slug?ref=` | anyone | stage and dates for one reference (Public role; no names, prices or notes) |
| GET | `/api/sites/:siteId/render-schema` |
'@

Write-Host ''
Write-Host 'Batch B done. Next: .\otp-mode.ps1 test, pnpm seed, pnpm set-phone, pnpm registers, .\backup.ps1, pnpm test'