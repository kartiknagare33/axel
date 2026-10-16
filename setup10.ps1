# Axel - batch 10 (Isolation Ledger, export zip, explain, board history). Run from the axel folder.
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

# ============================== PATCHES: scripts, deps, compiler, server ==============================
Patch 'package.json' @'
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel && pnpm test:api && pnpm test:gate && pnpm test:replay && pnpm test:infer"
'@ @'
    "test:stage": "pnpm --filter @axel/api test:stage",
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel && pnpm test:api && pnpm test:gate && pnpm test:replay && pnpm test:infer && pnpm test:stage"
'@

Patch 'apps/api/package.json' @'
    "test:infer": "tsx --env-file=../../.env --test test/infer.test.ts",
'@ @'
    "test:infer": "tsx --env-file=../../.env --test test/infer.test.ts",
    "test:stage": "tsx --env-file=../../.env --test test/stage.test.ts",
'@

Patch 'apps/api/package.json' @'
    "exceljs": "^4.4.0",
'@ @'
    "exceljs": "^4.4.0",
    "jszip": "^3.10.1",
'@

Patch 'packages/compiler/src/index.ts' @'
export * from './infer';
'@ @'
export * from './infer';
export * from './explain';
'@

Patch 'apps/api/src/server.ts' @'
import { membersRouter } from './members';
'@ @'
import { membersRouter } from './members';
import { exportRouter } from './export';
import { isolationRouter } from './isolation';
import { timeline } from './timeline';
'@

Patch 'apps/api/src/server.ts' @'
replayRouter, membersRouter);
'@ @'
replayRouter, membersRouter, exportRouter);
'@

Patch 'apps/api/src/server.ts' @'
app.use('/api/hub', hubRouter);
'@ @'
app.use('/api/hub', hubRouter);
app.use('/api/hub', isolationRouter);
'@

Patch 'apps/api/src/server.ts' @'
analytics, aliases, workflow, excel, resources);
'@ @'
analytics, aliases, timeline, workflow, excel, resources);
'@

# ============================== PATCHES: web ==============================
Patch 'apps/web/src/App.tsx' @'
import Builder from './builder/Builder';
'@ @'
import Builder from './builder/Builder';
import IsolationLedger from './pages/IsolationLedger';
'@

Patch 'apps/web/src/App.tsx' @'
      <Route path="/builder/:siteId"
'@ @'
      <Route path="/hub/ledger" element={token ? <IsolationLedger /> : <Navigate to="/login" replace />} />
      <Route path="/builder/:siteId"
'@

Patch 'apps/web/src/pages/Hub.tsx' @'
          <span>{user?.name}</span>
          <button onClick={logout} className="text-slate-500 hover:text-slate-900">Log out</button>
'@ @'
          {user?.hubAdmin && <Link to="/hub/ledger" className="text-slate-500 hover:text-slate-900">Isolation Ledger</Link>}
          <span>{user?.name}</span>
          <button onClick={logout} className="text-slate-500 hover:text-slate-900">Log out</button>
'@

Patch 'apps/web/src/renderer/SiteShell.tsx' @'
import { RecordDetail } from './RecordDetail';
'@ @'
import { RecordDetail } from './RecordDetail';
import { SerialTimeline } from './SerialTimeline';
'@

Patch 'apps/web/src/renderer/SiteShell.tsx' @'
  return <>{schema.nav.map(n => <NavLink key={n.path} to={base + n.path} className={cls}>{n.label}</NavLink>)}</>;
'@ @'
  const items = schema.modules.includes('pcb-repair') ? [...schema.nav, { label: 'Board history', path: '/timeline' }] : schema.nav;
  return <>{items.map(n => <NavLink key={n.path} to={base + n.path} className={cls}>{n.label}</NavLink>)}</>;
'@

Patch 'apps/web/src/renderer/SiteShell.tsx' @'
            <Route path="r/:entity/:id" element={<RecordDetail />} />
'@ @'
            <Route path="r/:entity/:id" element={<RecordDetail />} />
            <Route path="timeline" element={<SerialTimeline />} />
'@

Patch 'apps/web/src/renderer/RecordDetail.tsx' @'
import { useNavigate, useParams } from 'react-router-dom';
'@ @'
import { Link, useNavigate, useParams } from 'react-router-dom';
'@

Patch 'apps/web/src/renderer/RecordDetail.tsx' @'
  const { siteId, schema } = useSite();
'@ @'
  const { siteId, schema, base } = useSite();
'@

Patch 'apps/web/src/renderer/RecordDetail.tsx' @'
          {canEdit && !editing && <button onClick={() => setEditing(true)} className={btnGhost}>Edit</button>}
'@ @'
          <div className="flex gap-2">
            {rec.serial_no && <Link to={`${base}/timeline?serial=${encodeURIComponent(rec.serial_no)}`} className={btnGhost}>Board history</Link>}
            {canEdit && !editing && <button onClick={() => setEditing(true)} className={btnGhost}>Edit</button>}
          </div>
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
  async function runImpact(versionId?: string) {
'@ @'
  async function exportSite() {
    try {
      const r = await http.get(`/sites/${siteId}/export`, { ...H, responseType: 'blob' });
      const url = URL.createObjectURL(r.data);
      const a = document.createElement('a');
      a.href = url; a.download = `${site?.slug ?? 'site'}-export.zip`;
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (e) { setMsg({ kind: 'err', text: errOf(e).message }); }
  }

  async function explainSite() {
    try {
      const r = await http.get(`/sites/${siteId}/explain`, { ...H, responseType: 'text' });
      const w = window.open('', '_blank');
      if (!w) return;
      w.document.title = `${site?.name ?? 'Site'} - explained`;
      const pre = w.document.createElement('pre');
      pre.textContent = String(r.data);
      pre.style.cssText = 'white-space:pre-wrap;font:14px/1.6 ui-monospace,Consolas,monospace;padding:24px;max-width:960px;margin:auto';
      w.document.body.appendChild(pre);
    } catch (e) { setMsg({ kind: 'err', text: errOf(e).message }); }
  }

  async function runImpact(versionId?: string) {
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
          <a href={`/${site.slug}`} target="_blank" rel="noreferrer" className={ghost}>Open live</a>
'@ @'
          <button onClick={explainSite} className={ghost}>Explain</button>
          <button onClick={exportSite} className={ghost}>Export</button>
          <a href={`/${site.slug}`} target="_blank" rel="noreferrer" className={ghost}>Open live</a>
'@

# ============================== PATCHES: docs ==============================
Patch 'README.md' @'
Nobody can change their own role; the database enforces this too.
'@ @'
Nobody can change their own role; the database enforces this too.

## Proof and no lock-in

- **Isolation Ledger** (hub, hub admins): every business table with row-level security enabled and forced, its policies, composite foreign keys and site-scoped unique indexes; proof that the API's database role cannot bypass RLS and owns no tables; the last Release Gate per unit; and a **live isolation check** that tries every pair of units in front of you.
- **Export** (builder): a zip with `blueprint.json`, a generated plain-language `README.md`, `openapi.json`, all data as `data.xlsx`, and the deploy history with proofs.
- **Explain** (builder): the unit described in plain English, generated from its Blueprint.
- **Board history** (units with PCB Repair): every request, repair log, step and stock movement for one serial number on a single timeline.
'@

Patch 'README.md' @'
| `test:infer` (4) |
'@ @'
| `test:stage` (4) | Isolation Ledger shows RLS forced everywhere and its live check passes; the export zip has Blueprint, README, OpenAPI, data and history; Explain describes the unit; board history finds a serial and refuses other units |
| `test:infer` (4) |
'@

Patch 'README.md' @'
Run with Axel started: `pnpm test` (35 tests).
'@ @'
Run with Axel started: `pnpm test` (39 tests).
'@

Patch 'README.md' @'
404-not-403 for other sites. 35 automated tests.
'@ @'
404-not-403 for other sites. 39 automated tests.
'@

Patch 'README.md' @'
Possible next steps: Record mode (derive a workflow by acting it out), offline field consumption, serial-number scanning.
'@ @'
Possible next steps: Record mode (derive a workflow by acting it out), offline field consumption, camera scanning of serial labels.
'@

Patch 'docs/API.md' @'
| GET | `/api/sites/:siteId/members` |
'@ @'
| GET | `/api/sites/:siteId/explain` | Admin: plain-language description of the unit (markdown) |
| GET | `/api/sites/:siteId/openapi.json` | Admin: OpenAPI 3.1 for the unit's entities and steps |
| GET | `/api/sites/:siteId/export` | Admin: zip with Blueprint, README, OpenAPI, data.xlsx and deploy history |
| GET | `/api/hub/isolation-ledger` | hub admin: RLS, policies, keys and role facts for every table |
| POST | `/api/hub/isolation-ledger/check` | hub admin: live cross-unit read, write and pooled-connection checks |
| GET | `/api/sites/:siteId/members` |
'@

Patch 'docs/API.md' @'
| GET | `/api/:siteId/approvals` | decision history |
'@ @'
| GET | `/api/:siteId/timeline?serial=` | every record, step and stock movement for one serial number (units with serials) |
| GET | `/api/:siteId/approvals` | decision history |
'@

Patch 'docs/DEMO_SCRIPT.md' @'
## Close: prove isolation (1 min)
'@ @'
## Close: prove isolation and zero lock-in (1 min)

- Hub, **Isolation Ledger**: every table shows RLS enabled and forced, composite keys, and the API role cannot bypass RLS and owns no tables. Click **Run live isolation check**: every pair of units reads 0 rows of the other, writes across units are refused, 30 parallel pooled requests never mix.
- Any builder, **Export**: a zip with the Blueprint, a plain-language README, OpenAPI, all data as Excel and the deploy history with proofs. "You can leave any time."
- Service Centre, **Board history**: type a serial such as `PCB-24001` to see the whole life of one board.
'@

# ============================== COMPILER: explain + openapi ==============================
W 'packages/compiler/src/explain.ts' @'
import type { Blueprint, Field } from './types';
import { REGISTRY } from './registry';
import { lawSentence } from './laws';

const tick = '`';
const code = (s: string) => tick + s + tick;

function notes(f: Field) {
  return [
    f.required && 'required', f.unique && 'unique', f.expr && `calculated: ${f.expr}`, f.system && 'kept by the stock ledger',
    f.type === 'relation' && `links to ${f.to}`, f.options && `one of: ${f.options.join(', ')}`,
    f.roles?.read && `visible to ${f.roles.read.join(', ')}`,
  ].filter(Boolean).join('; ') || '-';
}
function effect(actions: string[]) {
  if (!actions.length) return '-';
  return actions.map(a =>
    a.startsWith('stock.reserve') ? 'reserves stock'
    : a.startsWith('stock.commit') ? 'takes stock out'
    : a.startsWith('stock.release') ? 'releases reserved stock'
    : a.startsWith('stock.return') ? 'puts stock back'
    : a.startsWith('repair.open') ? 'opens a repair log'
    : a.startsWith('repair.close') ? 'closes the repair log' : a).join(', ');
}

/** "Explain this site": the unit in plain language, generated from its Blueprint. */
export function explain(bp: Blueprint): string {
  const L: string[] = [`# ${bp.name}`, '', `This unit runs on Axel from one Blueprint (configuration version ${bp.configVersion}). Everything below is generated from that Blueprint; nothing is hand-written per unit.`, ''];
  L.push('## At a glance', '',
    `- Layout: **${bp.theme.layout}**, ${bp.theme.density} density, home page ${code(bp.theme.home)}.`,
    `- Modules (${bp.modules.length}): ${bp.modules.map(m => REGISTRY[m]?.name ?? m).join(', ')}.`,
    `- Roles: ${bp.roles.join(', ')}.`, '');
  L.push('## Data', '');
  for (const [ek, e] of Object.entries(bp.entities)) {
    L.push(`### ${e.label ?? ek}`, '', '| Field | Type | Notes |', '|---|---|---|');
    for (const f of e.fields) L.push(`| ${f.label ?? f.key} (${code(f.key)}) | ${f.type} | ${notes(f)} |`);
    L.push('');
  }
  for (const [ek, wf] of Object.entries(bp.workflows)) {
    L.push(`## Workflow: ${bp.entities[ek]?.label ?? ek}`, '',
      `A record starts as **${wf.initial}** and ends as ${wf.terminal.map(s => `**${s}**`).join(' or ')}.`, '',
      '| Step | From | To | Who may do it | Rule | Effect |', '|---|---|---|---|---|---|');
    for (const t of wf.transitions)
      L.push(`| ${t.label ?? t.to} | ${t.from} | ${t.to} | ${t.roles.filter(r => r !== 'Public').join(', ')} | ${t.guard ? code(t.guard) : '-'} | ${effect(t.actions ?? [])} |`);
    L.push('');
  }
  L.push('## Pages', '', ...bp.pages.map(p => `- **${p.title}** (${code(p.path)}): ${p.view}${p.entity ? ` of ${bp.entities[p.entity]?.label ?? p.entity}` : ''}${p.roles ? `; only ${p.roles.join(', ')}` : ''}.`), '');
  L.push('## Laws', '', 'The Release Gate proves these before every publish.', '', ...bp.laws.map(l => `- ${lawSentence(l, bp)}${l.locked ? ' (locked)' : ''}.`), '');
  return L.join('\n');
}

const schemaOf = (f: Field): Record<string, unknown> => {
  switch (f.type) {
    case 'number': case 'money': case 'formula': return { type: 'number' };
    case 'boolean': return { type: 'boolean' };
    case 'date': return { type: 'string', format: 'date' };
    case 'relation': return { type: 'string', format: 'uuid', description: `id of a ${f.to}` };
    case 'select': return { type: 'string', enum: f.options ?? [] };
    default: return { type: 'string' };
  }
};

/** OpenAPI 3.1 for one unit's entities and workflow steps. */
export function openapi(bp: Blueprint) {
  const paths: Record<string, unknown> = {};
  const schemas: Record<string, unknown> = {};
  const site = [
    { name: 'siteId', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
    { name: 'X-Site-Id', in: 'header', required: true, schema: { type: 'string', format: 'uuid' } },
  ];
  const id = { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } };
  const ok = (d: string) => ({ description: d });
  for (const [ek, e] of Object.entries(bp.entities)) {
    const name = ek[0].toUpperCase() + ek.slice(1);
    const label = e.label ?? ek;
    schemas[name] = {
      type: 'object',
      properties: Object.fromEntries([
        ['id', { type: 'string', format: 'uuid', readOnly: true }],
        ...e.fields.map(f => [f.key, { ...schemaOf(f), ...(f.type === 'formula' || f.system ? { readOnly: true } : {}), description: f.label ?? f.key }]),
      ]),
      required: e.fields.filter(f => f.required).map(f => f.key),
    };
    const ref = { $ref: `#/components/schemas/${name}` };
    paths[`/api/{siteId}/${ek}`] = {
      parameters: site,
      get: { summary: `List ${label}`, responses: { 200: ok('Rows visible to your role') } },
      post: { summary: `Create ${label}`, requestBody: { content: { 'application/json': { schema: ref } } }, responses: { 201: ok('Created'), 422: ok('Validation failed') } },
    };
    paths[`/api/{siteId}/${ek}/{id}`] = {
      parameters: [...site, id],
      get: { summary: `Read one ${label}`, responses: { 200: ok('Record with next steps'), 404: ok('Not found') } },
      patch: { summary: `Edit ${label}`, requestBody: { content: { 'application/json': { schema: ref } } }, responses: { 200: ok('Updated'), 409: ok('Stale record') } },
    };
    const wf = bp.workflows[ek];
    if (wf) paths[`/api/{siteId}/${ek}/{id}/transition`] = {
      parameters: [...site, id],
      post: {
        summary: `Move a ${label} to its next step`,
        requestBody: { content: { 'application/json': { schema: { type: 'object', required: ['to', 'idempotencyKey'], properties: { to: { type: 'string', enum: wf.states }, idempotencyKey: { type: 'string' }, ifVersion: { type: 'integer' } } } } } },
        responses: { 201: ok('Moved'), 200: ok('Repeat of an earlier request'), 403: ok('Role not allowed'), 409: ok('Not possible from the current state'), 422: ok('Blocked by a rule') },
      },
    };
  }
  return {
    openapi: '3.1.0',
    info: { title: `${bp.name} API (Axel)`, version: String(bp.configVersion) },
    security: [{ bearer: [] }],
    components: { schemas, securitySchemes: { bearer: { type: 'http', scheme: 'bearer' } } },
    paths,
  };
}
'@

# ============================== API: export, isolation ledger, timeline ==============================
W 'apps/api/src/export.ts' @'
import { Router } from 'express';
import ExcelJS from 'exceljs';
import JSZip from 'jszip';
import { explain, openapi } from '@axel/compiler';
import { withSite } from './db';
import { TABLES, toRecord } from './entities';
import { ah } from './errors';

// Mounted at /api/sites/:siteId (Admin only).
export const exportRouter = Router({ mergeParams: true });

exportRouter.get('/explain', (req, res) => {
  res.type('text/markdown').send(explain(req.site!.compiled.blueprint));
});

exportRouter.get('/openapi.json', (req, res) => {
  res.json(openapi(req.site!.compiled.blueprint));
});

exportRouter.get('/export', ah(async (req, res) => {
  const s = req.site!;
  const bp = s.compiled.blueprint;
  const zip = new JSZip();
  zip.file('blueprint.json', JSON.stringify(bp, null, 2));
  zip.file('README.md', explain(bp));
  zip.file('openapi.json', JSON.stringify(openapi(bp), null, 2));
  const wb = new ExcelJS.Workbook();
  wb.creator = 'Axel';
  const deployments = await withSite(s.ctx, async c => {
    const used = new Set<string>();
    for (const [ek, e] of Object.entries(bp.entities)) {
      const spec = TABLES[ek];
      if (!spec) continue;
      let sheet = (e.label ?? ek).replace(/[\[\]:*?\/\\]/g, ' ').slice(0, 28) || ek;
      while (used.has(sheet)) sheet = `${sheet}_`;
      used.add(sheet);
      const ws = wb.addWorksheet(sheet);
      const keys = ['id', ...e.fields.map(f => f.key), ...(bp.workflows[ek] ? ['state'] : [])];
      ws.addRow(keys);
      ws.getRow(1).font = { bold: true };
      const rows = (await c.query(`SELECT * FROM ${spec.table} ORDER BY created_at LIMIT 10000`)).rows;
      for (const r of rows) {
        const rec = s.compiled.computeFormulas(ek, toRecord(ek, r));
        ws.addRow(keys.map(k => {
          const v = rec[k];
          if (v instanceof Date || v == null || typeof v !== 'object') return v ?? null;
          return JSON.stringify(v);
        }));
      }
    }
    return (await c.query('SELECT id, version_id, proof, deployed_at, rollback_of FROM site_deployments ORDER BY deployed_at')).rows;
  });
  zip.file('data.xlsx', Buffer.from(await wb.xlsx.writeBuffer() as ArrayBuffer));
  zip.file('deployments.json', JSON.stringify(deployments, null, 2));
  const buf = await zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE' });
  res.setHeader('Content-Type', 'application/zip');
  res.setHeader('Content-Disposition', `attachment; filename="${s.slug}-export.zip"`);
  res.send(buf);
}));
'@

W 'apps/api/src/isolation.ts' @'
import { Router } from 'express';
import { pool, withSite } from './db';
import { requireAuth, requireHubAdmin, memberships } from './auth';
import { ah } from './errors';

// Mounted at /api/hub. Shows and proves the database-level isolation.
export const isolationRouter = Router();
const SCOPED = ['memberships', 'site_versions', 'site_deployments', 'recordings', 'law_runs', 'audit_events',
  'items', 'stock_movements', 'requests', 'approvals', 'assignments', 'consumptions', 'returns', 'repairs'];

isolationRouter.get('/isolation-ledger', requireAuth, requireHubAdmin, ah(async (req, res) => {
  const tables = (await pool.query(
    `SELECT c.relname AS "table", c.relrowsecurity AS rls, c.relforcerowsecurity AS forced,
            pg_get_userbyid(c.relowner) AS owner,
            (SELECT count(*)::int FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = c.relname) AS policies,
            (SELECT count(*)::int FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'f' AND array_length(k.conkey, 1) = 2) AS composite_fks
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname = ANY($1) ORDER BY c.relname`, [SCOPED])).rows;
  const role = (await pool.query(`SELECT current_user AS name, rolbypassrls AS bypass, rolsuper AS superuser FROM pg_roles WHERE rolname = current_user`)).rows[0];
  const owns = Number((await pool.query(
    `SELECT count(*) AS n FROM pg_class WHERE relowner = (SELECT oid FROM pg_roles WHERE rolname = current_user) AND relkind IN ('r', 'v')`)).rows[0].n);
  const uniques = (await pool.query(
    `SELECT tablename, indexname FROM pg_indexes WHERE schemaname = 'public' AND indexdef ILIKE 'CREATE UNIQUE%' AND indexdef ILIKE '%site_id%' ORDER BY tablename`)).rows;
  const sites = await memberships(req.user!.id);
  const gates = await Promise.all(sites.map(async (m: any) => ({
    id: m.site_id, name: m.name,
    lastGate: await withSite({ siteId: m.site_id, userId: req.user!.id, role: '' }, async c =>
      (await c.query('SELECT passed, steps, seed, ran_at FROM law_runs ORDER BY ran_at DESC LIMIT 1')).rows[0] ?? null),
  })));
  res.json({ role: { ...role, ownsTables: owns }, tables, uniques, sites: gates });
}));

isolationRouter.post('/isolation-ledger/check', requireAuth, requireHubAdmin, ah(async (req, res) => {
  const sites = (await memberships(req.user!.id)).map((m: any) => ({ id: m.site_id as string, name: m.name as string }));
  const checks: { name: string; passed: boolean; detail: string }[] = [];
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    const none = Number((await c.query('SELECT (SELECT count(*) FROM items) + (SELECT count(*) FROM requests) + (SELECT count(*) FROM audit_events) AS n')).rows[0].n);
    checks.push({ name: 'With no unit selected, nothing is visible', passed: none === 0, detail: `${none} rows visible without a unit context.` });
    for (const a of sites) for (const b of sites) {
      if (a.id === b.id) continue;
      await c.query(`SELECT set_config('app.site_id', $1, true)`, [a.id]);
      const leak = Number((await c.query(
        `SELECT (SELECT count(*) FROM items WHERE site_id = $1) + (SELECT count(*) FROM requests WHERE site_id = $1) + (SELECT count(*) FROM stock_movements WHERE site_id = $1) AS n`, [b.id])).rows[0].n);
      checks.push({ name: `${a.name} cannot read ${b.name}`, passed: leak === 0, detail: leak ? `${leak} rows leaked` : 'asked for every item, request and stock movement of the other unit: 0 rows' });
    }
    if (sites.length >= 2) {
      const [a, b] = sites;
      await c.query(`SELECT set_config('app.site_id', $1, true)`, [b.id]);
      const otherItem = (await c.query('SELECT id FROM items LIMIT 1')).rows[0]?.id;
      await c.query(`SELECT set_config('app.site_id', $1, true)`, [a.id]);
      await c.query('SAVEPOINT w');
      let refused = false;
      try { await c.query(`INSERT INTO items (site_id, name) VALUES ($1, 'smuggled')`, [b.id]); } catch { refused = true; }
      await c.query('ROLLBACK TO SAVEPOINT w');
      checks.push({ name: `${a.name} cannot write into ${b.name}`, passed: refused, detail: refused ? 'refused by row-level security' : 'the insert was accepted' });
      if (otherItem) {
        const myItem = (await c.query('SELECT id FROM items LIMIT 1')).rows[0]?.id;
        await c.query('SAVEPOINT f');
        let blocked = false;
        try { await c.query(`INSERT INTO requests (site_id, item_id, qty, state) VALUES ($1, $2, 1, 'draft')`, [a.id, otherItem]); } catch { blocked = true; }
        await c.query('ROLLBACK TO SAVEPOINT f');
        checks.push({ name: `${a.name} cannot point at ${b.name}'s items`, passed: blocked, detail: blocked ? 'refused by the composite foreign key (site_id, id)' : 'a cross-unit reference was accepted' });
        void myItem;
      }
    }
  } finally {
    await c.query('ROLLBACK').catch(() => {});
    c.release();
  }
  if (sites.length) {
    const counts = await Promise.all(Array.from({ length: 30 }, (_, i) => sites[i % sites.length]).map(s =>
      withSite({ siteId: s.id, userId: '', role: '' }, async x => Number((await x.query('SELECT count(*) AS n FROM items WHERE site_id <> $1', [s.id])).rows[0].n))));
    checks.push({ name: '30 parallel requests on pooled connections never mix units', passed: counts.every(n => n === 0), detail: `${counts.filter(n => n === 0).length} of 30 saw only their own unit` });
  }
  res.json({ passed: checks.every(x => x.passed), checks, ranAt: new Date().toISOString() });
}));
'@

W 'apps/api/src/timeline.ts' @'
import { Router } from 'express';
import { z } from 'zod';
import { withSite } from './db';
import { TABLES, toRecord } from './entities';
import { AxelError, ah } from './errors';

// GET /api/:siteId/timeline?serial=  - the whole life of one board, inside this unit only.
export const timeline = Router({ mergeParams: true });

timeline.get('/timeline', ah(async (req, res) => {
  const serial = z.string().trim().min(1).max(100).parse(req.query.serial);
  const s = req.site!;
  const bp = s.compiled.blueprint;
  const ents = Object.entries(bp.entities).filter(([k, e]) => TABLES[k] && e.fields.some(f => f.key === 'serial_no'));
  if (!ents.length) throw new AxelError('ENTITY_NOT_IN_SITE', 404, 'This unit does not track serial numbers.');
  const out = await withSite(s.ctx, async c => {
    const records: { entity: string; label: string; rec: Record<string, unknown> }[] = [];
    for (const [ek, e] of ents) {
      const spec = TABLES[ek];
      const col = spec.core.includes('serial_no') ? 'serial_no' : `data->>'serial_no'`;
      const rows = (await c.query(`SELECT * FROM ${spec.table} WHERE lower(${col}) = lower($1) ORDER BY created_at`, [serial])).rows;
      for (const r of rows) records.push({ entity: ek, label: e.label ?? ek, rec: s.compiled.mask(ek, s.role, s.compiled.computeFormulas(ek, toRecord(ek, r))) });
    }
    const ids = records.map(r => String(r.rec.id));
    const events = ids.length ? (await c.query(
      `SELECT e.entity, e.record_id, e.kind, e.from_state, e.to_state, e.actor_role, e.at, u.name AS actor_name
         FROM audit_events e LEFT JOIN users u ON u.id = e.actor_id WHERE e.record_id = ANY($1) ORDER BY e.at, e.id`, [ids])).rows : [];
    const moves = ids.length ? (await c.query(
      `SELECT m.kind, m.qty, m.reason, m.at, i.name AS item FROM stock_movements m JOIN items i ON i.id = m.item_id
        WHERE m.ref_id = ANY($1) ORDER BY m.id`, [ids])).rows : [];
    return { records, events, moves };
  });
  res.json({ serial, ...out });
}));
'@

W 'apps/api/test/stage.test.ts' @'
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import JSZip from 'jszip';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const SC = '22222222-2222-4222-8222-222222222222';
const DS = '33333333-3333-4333-8333-333333333333';

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  return (await r.json()).token as string;
}
let admin = '', scManager = '', csManager = '';
before(async () => { [admin, scManager, csManager] = await Promise.all(['admin@axel.dev', 'manager@sc.dev', 'manager@cs.dev'].map(login)); });
const H = (t: string, site?: string) => ({ authorization: `Bearer ${t}`, 'content-type': 'application/json', ...(site ? { 'x-site-id': site } : {}) });

test('Isolation Ledger: RLS forced everywhere, app role powerless, live check passes', async () => {
  const l = await (await fetch(`${API}/hub/isolation-ledger`, { headers: H(admin) })).json();
  assert.ok(l.tables.length >= 14);
  for (const t of l.tables) assert.ok(t.rls && t.forced && t.policies > 0, t.table);
  assert.equal(l.role.bypass, false);
  assert.equal(l.role.superuser, false);
  assert.equal(l.role.ownsTables, 0);
  const c = await (await fetch(`${API}/hub/isolation-ledger/check`, { method: 'POST', headers: H(admin) })).json();
  assert.equal(c.passed, true, JSON.stringify(c.checks.filter((x: any) => !x.passed)));
  assert.equal((await fetch(`${API}/hub/isolation-ledger`, { headers: H(scManager) })).status, 403);
});

test('export zip holds Blueprint, README, OpenAPI, data and history', async () => {
  const r = await fetch(`${API}/sites/${DS}/export`, { headers: H(admin, DS) });
  assert.equal(r.status, 200);
  const zip = await JSZip.loadAsync(Buffer.from(await r.arrayBuffer()));
  for (const f of ['blueprint.json', 'README.md', 'openapi.json', 'data.xlsx', 'deployments.json']) assert.ok(zip.file(f), f);
  const bp = JSON.parse(await zip.file('blueprint.json')!.async('string'));
  assert.equal(bp.slug, 'distribution');
  const api = JSON.parse(await zip.file('openapi.json')!.async('string'));
  assert.ok(Object.keys(api.paths).some(p => p.endsWith('/transition')));
});

test('Explain describes the unit in plain language', async () => {
  const t = await (await fetch(`${API}/sites/${SC}/explain`, { headers: H(admin, SC) })).text();
  assert.ok(t.includes('# Service Centre') && t.includes('## Workflow') && t.includes('## Laws'));
});

test('board history finds a serial and refuses other units', async () => {
  const list = await (await fetch(`${API}/${SC}/requests?limit=200`, { headers: H(scManager, SC) })).json();
  const withSerial = list.rows.find((r: any) => r.serial_no);
  assert.ok(withSerial, 'no request with a serial; run pnpm seed');
  const tl = await (await fetch(`${API}/${SC}/timeline?serial=${encodeURIComponent(withSerial.serial_no)}`, { headers: H(scManager, SC) })).json();
  assert.ok(tl.records.length >= 1 && tl.events.length >= 1);
  assert.equal((await fetch(`${API}/${SC}/timeline?serial=PCB-24001`, { headers: H(csManager, SC) })).status, 404);
});
'@

# ============================== WEB: pages ==============================
W 'apps/web/src/pages/IsolationLedger.tsx' @'
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { http, errOf } from '../api';

const Tick = ({ ok }: { ok: boolean }) => <span className={ok ? 'font-bold text-emerald-600' : 'font-bold text-red-600'}>{ok ? 'yes' : 'NO'}</span>;

export default function IsolationLedger() {
  const [data, setData] = useState<any>(null);
  const [check, setCheck] = useState<any>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  useEffect(() => { http.get('/hub/isolation-ledger').then(r => setData(r.data), e => setErr(errOf(e).message)); }, []);
  async function run() {
    setBusy(true); setCheck(null);
    try { setCheck((await http.post('/hub/isolation-ledger/check')).data); } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  return (
    <div className="min-h-screen bg-slate-50">
      <header className="flex items-center justify-between border-b bg-white px-6 py-3">
        <div className="text-lg font-bold">Axel <span className="font-normal text-slate-400">Isolation Ledger</span></div>
        <Link to="/" className="text-sm text-slate-500 hover:text-slate-900">Back to hub</Link>
      </header>
      <main className="mx-auto max-w-5xl space-y-6 p-6">
        <p className="text-sm text-slate-600">Every claim on this page is read live from PostgreSQL's own catalog, not from Axel's configuration.</p>
        {err && <div className="rounded-lg bg-red-50 p-3 text-sm text-red-700">{err}</div>}
        {data && (
          <>
            <div className="grid gap-3 sm:grid-cols-4">
              <div className="rounded-xl border bg-white p-4"><div className="text-xs uppercase text-slate-400">API database role</div><div className="font-mono text-lg">{data.role.name}</div></div>
              <div className="rounded-xl border bg-white p-4"><div className="text-xs uppercase text-slate-400">Can bypass RLS</div><div className="text-lg"><Tick ok={!data.role.bypass} /> <span className="text-sm text-slate-500">({data.role.bypass ? 'yes' : 'no'})</span></div></div>
              <div className="rounded-xl border bg-white p-4"><div className="text-xs uppercase text-slate-400">Superuser</div><div className="text-lg"><Tick ok={!data.role.superuser} /> <span className="text-sm text-slate-500">({data.role.superuser ? 'yes' : 'no'})</span></div></div>
              <div className="rounded-xl border bg-white p-4"><div className="text-xs uppercase text-slate-400">Tables it owns</div><div className="text-lg font-bold">{data.role.ownsTables}</div></div>
            </div>
            <div className="overflow-x-auto rounded-xl border bg-white">
              <table className="w-full text-left text-sm">
                <thead className="bg-slate-50 text-slate-500"><tr><th className="px-3 py-2">Table</th><th>RLS enabled</th><th>RLS forced</th><th>Policies</th><th>Composite keys</th><th>Owner</th></tr></thead>
                <tbody>
                  {data.tables.map((t: any) => (
                    <tr key={t.table} className="border-t">
                      <td className="px-3 py-1.5 font-mono">{t.table}</td><td><Tick ok={t.rls} /></td><td><Tick ok={t.forced} /></td>
                      <td>{t.policies}</td><td>{t.composite_fks}</td><td className="font-mono text-xs">{t.owner}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="rounded-xl border bg-white p-4">
                <div className="mb-2 text-xs uppercase text-slate-400">Unique values are scoped per unit</div>
                {data.uniques.map((u: any) => <div key={u.indexname} className="font-mono text-xs">{u.tablename}: {u.indexname}</div>)}
              </div>
              <div className="rounded-xl border bg-white p-4">
                <div className="mb-2 text-xs uppercase text-slate-400">Last Release Gate per unit</div>
                {data.sites.map((s: any) => (
                  <div key={s.id} className="flex justify-between text-sm">
                    <span>{s.name}</span>
                    <span className={s.lastGate ? (s.lastGate.passed ? 'text-emerald-700' : 'text-red-700') : 'text-slate-400'}>
                      {s.lastGate ? `${s.lastGate.passed ? 'passed' : 'blocked'}, ${s.lastGate.steps} steps` : 'not run yet'}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </>
        )}
        <div className="space-y-3 rounded-xl border bg-white p-5">
          <div className="flex items-center justify-between">
            <div>
              <div className="font-medium">Live isolation check</div>
              <div className="text-sm text-slate-500">Reads every unit as every other unit, tries a cross-unit write and a cross-unit reference, and fires 30 parallel pooled requests.</div>
            </div>
            <button onClick={run} disabled={busy} className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">{busy ? 'Checking...' : 'Run live isolation check'}</button>
          </div>
          {check && (
            <>
              <div className={`rounded-lg p-3 text-center text-xl font-bold ${check.passed ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-800'}`}>{check.passed ? 'ALL ISOLATED' : 'LEAK FOUND'}</div>
              <div className="space-y-1">
                {check.checks.map((c: any) => (
                  <div key={c.name} className="flex gap-3 text-sm">
                    <span className={`w-10 shrink-0 font-bold ${c.passed ? 'text-emerald-600' : 'text-red-600'}`}>{c.passed ? 'PASS' : 'FAIL'}</span>
                    <span className="w-72 shrink-0">{c.name}</span>
                    <span className="text-slate-500">{c.detail}</span>
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      </main>
    </div>
  );
}
'@

W 'apps/web/src/renderer/SerialTimeline.tsx' @'
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { site, errOf } from '../api';
import { useSite } from '../hooks';
import { Denial, StateBadge, btn } from './fields';

export function SerialTimeline() {
  const { siteId, base } = useSite();
  const [params, setParams] = useSearchParams();
  const serial = params.get('serial') ?? '';
  const [input, setInput] = useState(serial);
  const q = useQuery({ queryKey: ['timeline', siteId, serial], queryFn: () => site.get(siteId, '/timeline', { serial }), enabled: !!serial });
  const items = q.data ? [
    ...q.data.events.map((e: any) => ({ at: e.at, text: e.kind === 'transition' ? `${e.from_state} to ${e.to_state}` : String(e.kind).replace(/_/g, ' '), who: e.actor_name ? `${e.actor_name} (${e.actor_role})` : e.actor_role ?? 'system', kind: 'event' })),
    ...q.data.moves.map((m: any) => ({ at: m.at, text: `Stock ${m.kind} ${m.qty} of ${m.item}${m.reason ? ` (${m.reason})` : ''}`, who: 'ledger', kind: 'move' })),
  ].sort((a, b) => +new Date(a.at) - +new Date(b.at)) : [];

  return (
    <div className="max-w-4xl space-y-4">
      <h1 className="text-xl font-semibold">Board history</h1>
      <form onSubmit={e => { e.preventDefault(); setParams(input.trim() ? { serial: input.trim() } : {}); }} className="flex gap-2">
        <input value={input} onChange={e => setInput(e.target.value)} placeholder="Serial number, e.g. PCB-24001" className="w-72 rounded-site border px-3 py-2 text-sm" />
        <button className={btn}>Show history</button>
      </form>
      {q.isLoading && serial && <div className="h-24 animate-pulse rounded-site bg-slate-200" />}
      {q.error && <Denial err={errOf(q.error)} />}
      {q.data && !q.data.records.length && <div className="text-sm text-slate-500">No record in this unit has serial {serial}.</div>}
      {!!q.data?.records.length && (
        <div className="grid gap-4 md:grid-cols-[1fr_1.3fr]">
          <div className="space-y-2">
            {q.data.records.map((r: any) => (
              <Link key={String(r.rec.id)} to={`${base}/r/${r.entity}/${r.rec.id}`} className="block rounded-site border bg-white p-3 text-sm hover:shadow">
                <div className="flex items-center justify-between"><span className="font-medium">{r.label}</span>{r.rec.state && <StateBadge state={r.rec.state} />}</div>
                <div className="text-xs text-slate-500">{[r.rec.fault, r.rec.diagnosis].filter(Boolean).join(' - ') || String(r.rec.id).slice(0, 8)}</div>
              </Link>
            ))}
          </div>
          <ol className="space-y-3 rounded-site border-l-2 border-primary/30 bg-white p-4">
            {items.map((x, i) => (
              <li key={i} className="text-sm">
                <div className={x.kind === 'move' ? 'text-slate-600' : ''}>{x.text}</div>
                <div className="text-xs text-slate-400">{new Date(x.at).toLocaleString()} - {x.who}</div>
              </li>
            ))}
          </ol>
        </div>
      )}
    </div>
  );
}
'@

Write-Host ''
Write-Host 'Batch 10 done. Next: pnpm install, .\start.ps1, pnpm test'