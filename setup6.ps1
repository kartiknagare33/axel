# Axel - batch 6 (submission pack: docs, brief endpoints, backup/restore, first-run). Run from the axel folder.
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
Patch 'package.json' @'
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel"
'@ @'
    "test:api": "pnpm --filter @axel/api test:api",
    "docs": "pnpm --filter @axel/api docs",
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel && pnpm test:api"
'@

Patch 'apps/api/package.json' @'
"test:excel": "tsx --env-file=../../.env --test test/excel.test.ts"
'@ @'
"test:excel": "tsx --env-file=../../.env --test test/excel.test.ts",
    "test:api": "tsx --env-file=../../.env --test test/api.test.ts",
    "docs": "tsx scripts/gen-docs.ts"
'@

Patch 'apps/api/src/server.ts' @'
import { excel } from './excel';
'@ @'
import { excel } from './excel';
import { aliases } from './aliases';
'@

Patch 'apps/api/src/server.ts' @'
analytics, workflow, excel, resources);
'@ @'
analytics, aliases, workflow, excel, resources);
'@

# ============================== API: brief endpoints ==============================
W 'apps/api/src/aliases.ts' @'
import { Router } from 'express';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { withSite } from './db';
import { toRecord } from './entities';
import { AxelError, ah } from './errors';
import { runTransition } from './workflow';
import { bus } from './blueprints';

// Endpoints named in PS 03. They are thin wrappers: approvals and assignments run through
// the same workflow engine, guards, roles, ledger and audit trail as the generic transition route.
export const aliases = Router({ mergeParams: true });

const needModule = (req: any, id: string) => {
  if (!req.site.compiled.blueprint.modules.includes(id)) throw new AxelError('ENTITY_NOT_IN_SITE', 404, 'Not found.');
};
const present = (req: any, row: any) =>
  req.site.compiled.mask('request', req.site.role, req.site.compiled.computeFormulas('request', toRecord('request', row)));

// GET /api/:siteId/approvals - decision history
aliases.get('/approvals', ah(async (req, res) => {
  needModule(req, 'approval');
  const rows = await withSite(req.site!.ctx, async c => (await c.query(
    `SELECT a.id, a.request_id, a.decision, a.note, a.at, u.name AS decided_by
       FROM approvals a LEFT JOIN users u ON u.id = a.decided_by ORDER BY a.at DESC LIMIT 200`)).rows);
  res.json({ total: rows.length, rows });
}));

// POST /api/:siteId/approvals { requestId, decision: approved|rejected, note?, idempotencyKey? }
aliases.post('/approvals', ah(async (req, res) => {
  needModule(req, 'approval');
  const b = z.object({
    requestId: z.string().uuid(), decision: z.enum(['approved', 'rejected']),
    note: z.string().max(500).optional(), idempotencyKey: z.string().min(8).max(100).optional(),
  }).parse(req.body);
  const s = req.site!;
  const r = await withSite(s.ctx, tx => runTransition(tx, { ...s.ctx, role: s.role }, s.compiled, s.name, 'request', b.requestId, {
    to: b.decision, idempotencyKey: b.idempotencyKey ?? randomUUID(), payload: b.note ? { note: b.note } : undefined,
  }));
  if (!r.replay) bus.emit('record_changed', { siteId: s.siteId, entity: 'request' });
  res.status(r.replay ? 200 : 201).json({ replay: r.replay, record: present(req, r.row) });
}));

// POST /api/:siteId/assignments { requestId, assignedTo?, idempotencyKey? }
// (GET /api/:siteId/assignments is served by the generic resource route.)
aliases.post('/assignments', ah(async (req, res) => {
  needModule(req, 'material-assignment');
  const b = z.object({
    requestId: z.string().uuid(), assignedTo: z.string().max(100).optional(),
    idempotencyKey: z.string().min(8).max(100).optional(),
  }).parse(req.body);
  const s = req.site!;
  const r = await withSite(s.ctx, tx => runTransition(tx, { ...s.ctx, role: s.role }, s.compiled, s.name, 'request', b.requestId, {
    to: 'assigned', idempotencyKey: b.idempotencyKey ?? randomUUID(), payload: { assigned_to: b.assignedTo ?? null },
  }));
  if (!r.replay) bus.emit('record_changed', { siteId: s.siteId, entity: 'assignment' });
  res.status(r.replay ? 200 : 201).json({ replay: r.replay, record: present(req, r.row) });
}));
'@

W 'apps/api/test/api.test.ts' @'
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
async function call(token: string, method: string, path: string, site?: string, body?: unknown) {
  const headers: Record<string, string> = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
  if (site) headers['x-site-id'] = site;
  const r = await fetch(`${API}${site ? `/${site}` : ''}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}

let admin = '', scManager = '', csManager = '';
before(async () => { [admin, scManager, csManager] = await Promise.all(['admin@axel.dev', 'manager@sc.dev', 'manager@cs.dev'].map(login)); });

test('brief endpoints respond for the right site', async () => {
  assert.ok((await call(admin, 'GET', '/sites')).body.length >= 3, 'list sites');
  assert.ok((await call(scManager, 'GET', '/components', SC)).body.some((m: any) => m.id === 'approval'), 'components');
  assert.equal((await call(scManager, 'GET', '/requests', SC)).status, 200, 'requests');
  assert.equal((await call(scManager, 'GET', '/approvals', SC)).status, 200, 'approvals');
  assert.equal((await call(admin, 'GET', '/assignments', DS)).status, 200, 'assignments');
  const x = await fetch(`${API}/${SC}/excel/export/request`, { headers: { authorization: `Bearer ${scManager}`, 'x-site-id': SC } });
  assert.equal(x.status, 200, 'excel export');
});

test('create site validates input and is limited to hub admins', async () => {
  assert.equal((await call(admin, 'POST', '/sites', undefined, { name: 'X', slug: 'Bad Slug!' })).status, 422);
  assert.equal((await call(scManager, 'POST', '/sites', undefined, { name: 'Sneaky', slug: 'sneaky' })).status, 403);
});

test('POST /approvals runs the real workflow engine', async t => {
  const req = (await call(scManager, 'GET', '/requests?filter%5Bstate%5D=submitted', SC)).body.rows?.[0];
  if (!req) return t.skip('no submitted requests; run pnpm seed');
  const r = await call(scManager, 'POST', '/approvals', SC, { requestId: req.id, decision: 'rejected', note: 'api test' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.record.state, 'rejected');
});

test('every brief endpoint refuses another site (404 to read, 403 to write)', async () => {
  for (const p of ['/components', '/requests', '/approvals', '/excel/export/request'])
    assert.equal((await call(csManager, 'GET', p, SC)).status, 404, `GET ${p}`);
  assert.equal((await call(csManager, 'GET', '/assignments', DS)).status, 404, 'GET /assignments');
  const fake = '00000000-0000-4000-8000-000000000000';
  assert.equal((await call(csManager, 'POST', '/approvals', SC, { requestId: fake, decision: 'approved' })).status, 403);
  assert.equal((await call(csManager, 'POST', '/assignments', DS, { requestId: fake })).status, 403);
});
'@

# ============================== docs generator ==============================
W 'apps/api/scripts/gen-docs.ts' @'
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { REGISTRY, MODULE_IDS, compile, type Blueprint } from '@axel/compiler';
import { centralStores, serviceCentre, distribution } from '../seed/blueprints';

const out = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'docs');
mkdirSync(out, { recursive: true });
const sites: Blueprint[] = [centralStores, serviceCentre, distribution];
const tick = '`';
const code = (s: string) => tick + s + tick;

const DESC: Record<string, string> = {
  auth: 'Global JWT login, bcrypt password hashing, role checks (Public, Member, Manager, Admin).',
  users: 'Per-site memberships and roles. Only Admins change roles; nobody changes their own.',
  dashboard: 'App shell, navigation, generic forms, tables, kanban, queue and detail views.',
  inventory: 'Items plus the append-only stock ledger (receive, adjust, reserve, commit, release, return).',
  request: 'Members ask for material; guard checks available stock before submit.',
  approval: 'Managers approve or reject; approval reserves stock with an expiry.',
  'material-assignment': 'Approved stock is issued to a person; the reservation is committed.',
  'assignment-frontend': 'Queue page for assignments.',
  consumption: 'Field teams record what they used against an assignment.',
  returns: 'Material or boards come back; stock is returned to the ledger.',
  'pcb-repair': 'Board repairs with serial numbers; repair log opened and closed by the workflow.',
  analytics: 'Per-site dashboard widgets (Recharts) that respect column masks.',
  excel: 'Templates, dry-run import (Manager+), role-masked export.',
};

let reg = `# Module registry\n\nGenerated from ${code('packages/compiler/src/registry.ts')} by ${code('pnpm docs')}. `
  + 'Every module is a typed node in the builder. A connection is only allowed when the output type matches the input type, '
  + 'and a module cannot be published without the modules it requires.\n\n'
  + '| # | Module (node id) | Kind | Inputs | Outputs | Requires | What it does | Used by |\n|---|---|---|---|---|---|---|---|\n';
MODULE_IDS.forEach((id, i) => {
  const m = REGISTRY[id];
  const ins = m.in.map(p => `${p.name}${p.required ? '*' : ''}: ${p.types.join(' or ')}`).join('<br>') || '-';
  const outs = m.out.map(p => `${p.name}: ${p.types.join(' or ')}`).join('<br>') || '-';
  const req = m.requires.map(g => g.map(r => REGISTRY[r].name).join(' or ')).join(', ') || '-';
  const used = sites.filter(s => s.modules.includes(id)).map(s => s.name).join(', ') || '-';
  reg += `| ${i + 1} | ${m.name} (${code(id)}) | ${m.kind} | ${ins} | ${outs} | ${req} | ${DESC[id]} | ${used} |\n`;
});
const instances = sites.reduce((n, s) => n + s.modules.length, 0);
reg += `\n\\* required input.\n\n**Reuse:** the three seeded units use ${instances} module instances backed by 13 implementations.\n\n`
  + '## Port types\n\n| Port type | Carries |\n|---|---|\n'
  + '| Identity | The signed-in user |\n| Membership | The user\'s role in a site |\n| Page[] | Pages rendered by the shell |\n'
  + '| ItemStream | Items in the site |\n| StockLedger | Stock movements |\n| RequestStream | Requests |\n'
  + '| ApprovedStream | Approved requests |\n| AssignmentStream | Issued material |\n| RepairLog | Repair records |\n'
  + '| File | Spreadsheet output |\n| Any | Accepts any stream (analytics, Excel) |\n\n'
  + '## Rules the builder and compiler enforce\n\n'
  + `- ${code('MODULE_DEP')}: e.g. "Approval requires Request."\n`
  + `- ${code('PORT_MISSING')}: a required input has no connection.\n`
  + `- ${code('PORT_TYPE')}: the connected output type does not match the input type.\n`
  + `- ${code('STATE_UNREACHABLE')} / ${code('STATE_DEAD_END')}: workflow states nothing leads to, or with no way out.\n`
  + `- ${code('FORMULA_REF')}: a calculated field uses an unknown field (with a "did you mean" suggestion).\n`
  + `- ${code('LAW_ISOLATION_MISSING')}: the site isolation law is locked and cannot be removed.\n`;
writeFileSync(path.join(out, 'MODULE_REGISTRY.md'), reg);

function explain(bp: Blueprint) {
  const L: string[] = [`## ${bp.name} (/${bp.slug})`, ''];
  L.push(`Layout **${bp.theme.layout}**, ${bp.theme.density} density, home page ${code(bp.theme.home)}, primary colour ${bp.theme.tokens.primary}.`, '');
  L.push(`Modules (${bp.modules.length}): ${bp.modules.map(m => REGISTRY[m].name).join(', ')}.`, '');
  for (const [ek, e] of Object.entries(bp.entities)) {
    L.push(`### ${e.label ?? ek} (${code(ek)})`, '', '| Field | Type | Notes |', '|---|---|---|');
    for (const f of e.fields) {
      const notes = [
        f.required && 'required', f.unique && 'unique per site', f.expr && `= ${code(f.expr)}`,
        f.system && 'maintained by the ledger', f.type === 'relation' && `links to ${f.to}`,
        f.options && f.options.join(' / '), f.roles?.read && `visible only to ${f.roles.read.join(', ')}`,
      ].filter(Boolean).join('; ');
      L.push(`| ${f.label ?? f.key} (${code(f.key)}) | ${f.type} | ${notes} |`);
    }
    L.push('');
  }
  for (const [ek, wf] of Object.entries(bp.workflows)) {
    L.push(`### Workflow: ${ek}`, '', `States: ${wf.states.join(' > ')}. Starts at ${code(wf.initial)}; ends at ${wf.terminal.map(code).join(', ')}.`, '',
      '| Step | From | To | Who | Guard | Actions |', '|---|---|---|---|---|---|');
    for (const t of wf.transitions)
      L.push(`| ${t.id} ${t.label ?? ''} | ${t.from} | ${t.to} | ${t.roles.filter(r => r !== 'Public').join(', ')} | ${t.guard ? code(t.guard) : ''} | ${(t.actions ?? []).map(code).join(' ')} |`);
    L.push('');
  }
  L.push('### Pages', '', ...bp.pages.map(p => `- **${p.title}** (${code(p.path)}): ${p.view}${p.entity ? ` of ${p.entity}` : ''}${p.roles ? `, for ${p.roles.join(', ')}` : ''}`), '');
  L.push('### Laws', '', ...bp.laws.map(l => `- ${l.id}: ${l.template}${l.locked ? ' (locked)' : ''}`), '');
  const d = compile(bp).diagnostics.filter(x => x.severity === 'error');
  L.push(`Compiler result: ${d.length ? `${d.length} error(s)` : 'no errors'}.`, '');
  return L.join('\n');
}
writeFileSync(path.join(out, 'SITES.md'),
  `# Seeded sites\n\nGenerated by ${code('pnpm docs')} from ${code('apps/api/seed/blueprints.ts')}. `
  + 'Each unit below is a Blueprint (JSON) rendered by the same code. Nothing here is hand-coded per site.\n\n'
  + sites.map(explain).join('\n'));
console.log(`wrote ${path.join(out, 'MODULE_REGISTRY.md')} and SITES.md`);
'@

# ============================== scripts: backup, restore, first run ==============================
W 'backup.ps1' @'
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force -Path backups | Out-Null
docker compose exec -T db pg_dump -U postgres -d axel -Fc -f /tmp/axel.dump
docker compose cp db:/tmp/axel.dump backups/axel-demo.dump
Write-Host 'Saved backups/axel-demo.dump. Use .\restore.ps1 to go back to this exact state.'
'@

W 'restore.ps1' @'
Set-Location $PSScriptRoot
if (-not (Test-Path backups/axel-demo.dump)) { Write-Host 'No backup found. Run .\backup.ps1 first.'; exit 1 }
Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
  Where-Object { $_.CommandLine -like "*$PSScriptRoot*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
docker compose up -d db
do { Start-Sleep 2; docker compose exec -T db pg_isready -U postgres *> $null } until ($LASTEXITCODE -eq 0)
docker compose cp backups/axel-demo.dump db:/tmp/axel.dump
docker compose exec -T db pg_restore -U postgres -d axel --clean --if-exists /tmp/axel.dump
Write-Host 'Restored the demo database. Now run .\start.ps1 and log in again.'
'@

W 'first-run.ps1' @'
# Fresh machine setup: Docker Desktop, Node 20+ and pnpm must be installed.
Set-Location $PSScriptRoot
if (-not (Test-Path .env)) { Copy-Item .env.example .env; Write-Host 'Created .env from .env.example' }
docker info *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'Starting Docker Desktop...'
  Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
  do { Start-Sleep 3; docker info *> $null } until ($LASTEXITCODE -eq 0)
}
docker compose up -d db
Write-Host 'Waiting for the database to finish its first-time setup...'
do { Start-Sleep 3; $ok = docker compose exec -T db psql -U postgres -d axel -tAc "select 1 from pg_roles where rolname='axel_app'" 2>$null } until ("$ok" -match '1')
Start-Sleep 3
pnpm install
pnpm migrate
if (Test-Path backups/axel-demo.dump) { .\restore.ps1 } else { pnpm seed }
.\start.ps1
'@

W '.env.example' @'
DATABASE_URL_APP=postgres://axel_app:app_pw@localhost:5432/axel
DATABASE_URL_OWNER=postgres://axel_owner:owner_pw@localhost:5432/axel
JWT_SECRET=change-me-to-a-long-random-string-32chars-min
JWT_TTL=12h
PORT=4000
# Uncomment for the stage demo so approved reservations expire quickly:
# DEMO_RESERVATION_TTL=45 seconds
'@

# ============================== README and docs ==============================
W 'README.md' @'
# Axel - Attested Multi-Site Execution Layer

**PS 03 OpsHub submission.** *Axel. Every site proven before it runs.*

Axel runs many completely different operations sites from one codebase. Each unit (Central Stores, Service Centre, Distribution, and any unit you add) is a **Blueprint**: a JSON document that declares its theme, layout, modules, fields, workflow, pages and roles. One compiler turns a Blueprint into validators, masks and a render schema; one renderer draws every site; one API serves every site; PostgreSQL row-level security keeps every site's data apart.

## What you can see it do

- **One login, one hub, many products.** Switch between three units that look and behave differently: a dense analytics stock register, a repair kanban, an assignment queue.
- **Build without code.** Drag modules onto a canvas with typed ports. The builder explains problems in plain English ("Approval requires Request") and fixes most of them in one click.
- **Publish live, roll back safely.** Preview a draft on real data, publish with no restart, and every open window updates by itself. Roll back to any earlier version; data is never deleted.
- **Transactional stock.** Approve reserves stock, assign or repair commits it, return gives it back. 50 concurrent approvals against 10 units: exactly 10 succeed (Chaos test on the hub).
- **Isolation you can prove.** FORCE row-level security, composite foreign keys, transaction-local site context, 404-not-403 for other sites. 23 automated tests.
- **Excel with role rules.** Templates with dropdowns, dry-run imports with row-by-row errors, all-or-nothing commits, exports that leave out what your role cannot see.

## Quick start

**Needs:** Docker Desktop, Node.js 20+, pnpm (`npm i -g pnpm`).

**Windows (one command on a fresh machine):**
```powershell
powershell -ExecutionPolicy Bypass -File .\first-run.ps1
```
Day to day: `.\start.ps1` and `.\stop.ps1`.

**macOS / Linux:**
```bash
cp .env.example .env
pnpm install
docker compose up -d db      # wait ~10 s the first time
pnpm migrate && pnpm seed
pnpm dev:api                 # terminal 1
pnpm dev:web                 # terminal 2, then open http://localhost:5173
```

## Demo accounts (password `demo1234`)

| Email | Role |
|---|---|
| admin@axel.dev | Hub admin, Admin of every unit |
| manager@cs.dev / member@cs.dev | Central Stores manager / member |
| manager@sc.dev / member@sc.dev | Service Centre manager / member |
| manager@dist.dev / field@dist.dev | Distribution manager / field member |

The login page has one-click buttons for each.

## How Axel meets PS 03

| Requirement | Where |
|---|---|
| Hub layer: global JWT login, bcrypt, roles, user management, site switcher (Ctrl+K), theme engine, module catalogue | `apps/api/src/auth.ts`, `apps/web/src/pages/Hub.tsx`, `apps/web/src/renderer/SiteShell.tsx` |
| Site layer: `{ siteId, slug, theme, modules, pages, roles }` | `packages/compiler/src/types.ts` (Blueprint), [docs/SITES.md](docs/SITES.md) |
| Module and node layer: 13 typed nodes | `packages/compiler/src/registry.ts`, [docs/MODULE_REGISTRY.md](docs/MODULE_REGISTRY.md) |
| Visual builder (React Flow), drag, connect, presets, field and workflow config | `apps/web/src/builder/Builder.tsx`, `packages/compiler/src/{ports,modules,presets}.ts` |
| Config saved as JSONB; one renderer for every site | `site_versions.config`, `apps/web/src/renderer/` |
| `/api/:siteId/:resource` with `site_id` on every business table | `apps/api/src/resources.ts`, `apps/api/migrations/001_core.sql` |
| Isolation at ORM/API and database level, tested per endpoint | `apps/api/src/site.ts`, RLS in `001_core.sql`, `apps/api/test/isolation.test.ts`, `api.test.ts` |
| Request, approval, assignment with transactional stock | `apps/api/src/workflow.ts`, `ledger.ts`, `test/workflow.test.ts` (chaos) |
| Calculated fields (TOTAL = QTY x PRICE) with schema validation | `formula` fields, `packages/compiler/src/expr.ts` |
| Preview, publish, versioned releases, rollback, deploy history | `apps/api/src/versions.ts`, builder Versions tab |
| Per-site analytics (Recharts) | `apps/api/src/analytics.ts`, dashboard view |
| Bulk Excel import and export with role restrictions | `apps/api/src/excel.ts`, `test/excel.test.ts` |
| Scoped REST APIs incl. login, sites, components, requests, approvals, assignments, Excel export | [docs/API.md](docs/API.md) |
| Architecture diagram, registry, data model, API design, README | [docs/](docs/) |
| Seeded demo data plus offline backup | `pnpm seed`, `backups/axel-demo.dump`, `restore.ps1` |

## Project layout

```text
axel/
  packages/compiler/   Blueprint types, expression DSL, diagnostics, validators, render schema,
                       typed ports, module effects, presets (shared by browser and server)
  apps/api/            Express API: auth, site scope, resources, workflow engine, stock ledger,
                       versions/publish/rollback, Excel, analytics, live events, jobs
    migrations/        PostgreSQL schema with FORCE RLS
    seed/              Three demo units, run through the real workflow engine
    test/              isolation, workflow (chaos), excel, api
  apps/web/            React app: hub, builder (React Flow), renderer with four layouts
  docs/                Architecture, module registry, sites, data model, API, demo script
  db/init/             Database roles (owner for migrations, app role without BYPASSRLS)
```

## Tests

Run with Axel started: `pnpm test` (23 tests).

| Suite | Proves |
|---|---|
| `test:isolation` (11) | Cross-site reads are 404, writes refused, header must match URL, masked fields never sent or written, other sites' ids look nonexistent, 60 interleaved pooled requests never mix, no context means zero rows, RLS forced on every table |
| `test:workflow` (4) | 50 concurrent approvals vs 10 units, role on transition, stale versions refused, double-click idempotent |
| `test:excel` (4) | Dry-run row errors, all-or-nothing commit, Member cannot import, export follows the role mask |
| `test:api` (4) | Every brief endpoint works for its site and refuses other sites |

## Docs

- [Architecture](docs/ARCHITECTURE.md): Hub, Builder, API, PostgreSQL; request and publish flows
- [Module registry](docs/MODULE_REGISTRY.md): all 13 modules as builder nodes (generated)
- [Seeded sites](docs/SITES.md): each unit explained from its Blueprint (generated)
- [Data model](docs/DATA_MODEL.md)
- [API](docs/API.md)
- [Demo script](docs/DEMO_SCRIPT.md)

Regenerate the generated docs with `pnpm docs`.

## Offline backup

- Everything runs locally; no internet is needed during the demo.
- `.\backup.ps1` saves the database to `backups/axel-demo.dump`; `.\restore.ps1` brings it back in seconds.
- Keep a screen recording of the demo script as the last fallback.

## What comes next

The Blueprint and compiler are designed for these next steps: a Release Gate that runs declared Laws as property-based tests before publish, a Replay Report that runs real history through a proposed version, and a Sheet Inferencer that derives a site from a unit's existing spreadsheets.
'@

W 'docs/ARCHITECTURE.md' @'
# Architecture

Axel has one codebase. The only thing that differs between sites is the **Blueprint**, a JSON document stored per version in `site_versions.config`. The compiler is a shared TypeScript package, so the problems an admin sees on the builder canvas are exactly what the API would reject.

## Hub, Builder, API, PostgreSQL

```mermaid
flowchart TB
  HUB["Hub<br/>one login, site switcher, theme engine, module catalogue, chaos test"]
  BUILDER["Builder (Forge)<br/>React Flow canvas, typed ports, presets, fields, theme, JSON, versions"]
  API["API (Node / Express)<br/>/api/:siteId/:resource, workflow engine, stock ledger, publish, Excel"]
  PG["PostgreSQL 16<br/>FORCE RLS on site_id, composite FKs, ledger, versions, audit"]
  HUB --> BUILDER --> API --> PG
```

## Components

```mermaid
flowchart LR
  subgraph Browser["Browser (React, one app)"]
    H["Hub shell"]
    F["Builder"]
    R["Renderer<br/>4 layouts, table, kanban, queue, dashboard, forms"]
  end
  subgraph Shared["@axel/compiler (shared TypeScript)"]
    C["Blueprint to diagnostics, validators,<br/>render schema, masks, formulas, typed ports"]
  end
  subgraph Server["API"]
    MW["JWT, membership, Blueprint, transaction with site context"]
    WF["Workflow engine"]
    LG["Stock ledger"]
    VR["Versions, publish, rollback"]
    XL["Excel"]
    EV["Live events (SSE)"]
  end
  subgraph DB["PostgreSQL"]
    T["Business tables (RLS)"]
    SM["stock_movements"]
    V["site_versions, site_deployments"]
    A["audit_events"]
  end
  H --> MW
  R --> MW
  F --> VR
  F -.-> C
  MW -.-> C
  MW --> WF --> LG --> SM
  MW --> T
  MW --> XL --> T
  WF --> A
  VR --> V
  VR -- "NOTIFY site_published" --> EV --> R
```

## The three layers from the brief

| Brief layer | In Axel |
|---|---|
| Hub layer | JWT login (bcrypt), memberships per site, roles Public/Member/Manager/Admin, site switcher with cache wipe, theme engine (CSS variables plus four layout shells), module catalogue in the builder palette |
| Site layer | Blueprint `{ siteId, slug, name, theme, modules, entities, workflows, laws, pages, roles, nav, edges }` |
| Module and node layer | 13 registry entries with typed input/output ports and dependencies; adding a module applies its effects (states, steps, entities, pages) to the Blueprint |

## A request that changes stock

```mermaid
sequenceDiagram
  participant U as Manager (browser)
  participant A as API
  participant P as PostgreSQL
  U->>A: POST /api/:siteId/requests/:id/transition (to approved)
  A->>A: verify JWT, read role from memberships, load published Blueprint
  A->>P: BEGIN and set_config app.site_id (transaction-local)
  A->>P: SELECT request FOR UPDATE
  A->>P: check idempotency key and row_version
  A->>P: SELECT item FOR UPDATE, evaluate guard
  A->>P: INSERT stock_movements reserve, UPDATE items reserved
  A->>P: UPDATE request state, INSERT approvals and audit_events
  A->>P: COMMIT
  A-->>U: 201 with the record and its next steps
```

Two approvals for the same request serialise on the request row lock; the second sees the new state and is refused. Approvals for different requests on the same item serialise on the item row lock, so reserved stock can never exceed on-hand stock.

## Publishing a change

```mermaid
sequenceDiagram
  participant B as Builder
  participant A as API
  participant P as PostgreSQL
  participant W as Open site windows
  B->>A: POST /api/sites/:id/publish (draft version)
  A->>A: compile Blueprint, refuse if any error
  A->>P: count records in states the new version removes
  A->>P: archive old version, publish new, INSERT site_deployments with proof
  A->>P: NOTIFY site_published
  P-->>A: notification
  A->>A: drop cached Blueprint
  A-->>W: server-sent event site_published
  W->>A: refetch render schema, re-render (no reload)
```

Rollback is the same path pointed at an earlier version. Data is never deleted: fields a version does not know are hidden, not dropped.

## Isolation in three layers

1. **Database.** Every business table has `site_id`, `ENABLE` and `FORCE ROW LEVEL SECURITY`, and a policy comparing it to `app.site_id`. The API connects as `axel_app`, which owns nothing and cannot bypass RLS. Context is set with `set_config(..., true)` inside each transaction, so pooled connections never carry a stale site; with no context, queries return zero rows. Foreign keys are composite `(site_id, id)`, so a row cannot reference another site's row, and another site's id looks exactly like a missing id.
2. **API.** Middleware checks the JWT, the membership for that site and that `X-Site-Id` matches the URL. Reads of other sites return 404 so existence is not leaked. Bodies are validated against the Blueprint's per-role write mask; responses are filtered by the read mask.
3. **Client.** Every query key starts with the entity and site id; switching sites removes cached queries and discards any response that started before the switch.

## Design decisions

- **Shared tables with RLS, not a schema per site.** One codebase and hot publish need shared tables; FORCE RLS plus composite keys gives isolation without per-site migrations.
- **Compile first.** The same compiler runs in the browser (instant feedback) and the server (source of truth).
- **Ledger, not counters.** On-hand and reserved stock are only changed by ledger operations under row locks, with idempotency keys, and can be recomputed from `stock_movements`.
- **Server-sent events for live updates.** One direction is all that is needed; no extra dependency.
'@

W 'docs/DATA_MODEL.md' @'
# Data model

PostgreSQL 16. All ids are UUIDs. Every business table has `site_id uuid NOT NULL`, FORCE row-level security and a policy `site_id = app_site()`. Entities keep typed core columns plus `data jsonb` for Blueprint-defined fields (GIN indexed).

```mermaid
erDiagram
  USERS ||--o{ MEMBERSHIPS : has
  SITES ||--o{ MEMBERSHIPS : has
  SITES ||--o{ SITE_VERSIONS : versions
  SITE_VERSIONS ||--o{ SITE_DEPLOYMENTS : deployed_as
  SITES ||--o{ ITEMS : owns
  ITEMS ||--o{ STOCK_MOVEMENTS : ledger
  ITEMS ||--o{ REQUESTS : requested
  REQUESTS ||--o{ APPROVALS : decided
  REQUESTS ||--o{ ASSIGNMENTS : issued
  ASSIGNMENTS ||--o{ CONSUMPTIONS : used
  REQUESTS ||--o{ REPAIRS : repaired
  ITEMS ||--o{ RETURNS : returned
  SITES ||--o{ AUDIT_EVENTS : records
```

## Hub tables (not site-scoped)

| Table | Purpose |
|---|---|
| `users` | email (citext, unique), bcrypt `password_hash`, `is_hub_admin` |
| `sites` | `slug` (unique), `name`, `published_version_id` |

## Site-scoped platform tables

| Table | Purpose |
|---|---|
| `memberships` | `(site_id, user_id)` to role. A user may read their own rows across sites; role changes need Admin and nobody changes their own (trigger). |
| `site_versions` | Blueprint `config` (JSONB), `content_hash` (sha256 of canonical JSON), `status` draft/published/archived, `updated_rev` for draft conflicts |
| `site_deployments` | Every publish and rollback with its `proof` (hash, changes, warnings), `deployed_by`, `rollback_of` |
| `audit_events` | Event history: create, update, transition (with idempotency key), import, export, stock moves, reservation expiry |
| `recordings`, `law_runs` | Reserved for Record mode and the Release Gate |

## Business tables

| Table | Core columns | Notes |
|---|---|---|
| `items` | `name`, `on_hand`, `reserved` | `CHECK on_hand >= 0`, `CHECK reserved <= on_hand`; SKU unique per site via `(site_id, data->>'sku')` |
| `stock_movements` | `item_id`, `kind`, `qty`, `ref_id`, `idempotency_key`, `expires_at`, `consumed_by` | Append-only ledger, unique `(site_id, idempotency_key)` |
| `requests` | `item_id`, `qty`, `state`, `requested_by` | Workflow state; formula fields computed from `data` |
| `approvals` | `request_id`, `decision`, `decided_by`, `note` | Written by the Approval module on decision |
| `assignments` | `request_id`, `item_id`, `qty`, `state` | Written by Material Assignment on assign |
| `consumptions` | `assignment_id`, `qty`, `idempotency_key` | Field usage |
| `returns` | `ref_type`, `ref_id`, `item_id`, `qty` | Returned material |
| `repairs` | `request_id`, `serial_no`, `fault`, `diagnosis`, `state` | Opened and closed by PCB Repair steps |

Every entity table also has `row_version` (optimistic concurrency), `created_under_version`, `created_at`, `updated_at`, and `UNIQUE (site_id, id)` so other tables can use composite foreign keys.

## Stock ledger

| Kind | on_hand | reserved | Written by |
|---|---|---|---|
| receive | + | | Stock page, Excel import (opening qty) |
| adjust | +/- | | Stock page (Manager+) |
| reserve | | + | Approve (with expiry) |
| commit | - | - | Assign, Start repair |
| release | | - | Reject, expiry job |
| return | + | | Return step |

`available = on_hand - reserved`. The view `v_ledger_balance` recomputes both from the movements; the chaos test compares it with the item row.

## Row-level security

```sql
ALTER TABLE requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE requests FORCE ROW LEVEL SECURITY;
CREATE POLICY site_iso ON requests
  USING (site_id = app_site()) WITH CHECK (site_id = app_site());
-- app_site() = NULLIF(current_setting('app.site_id', true), '')::uuid
```

Roles: `axel_owner` owns the tables and runs migrations; `axel_app` is what the API uses and has no BYPASSRLS.
'@

W 'docs/API.md' @'
# API

REST over Express, JSON bodies, `Authorization: Bearer <jwt>`. Every site-scoped call also sends `X-Site-Id`, which must equal the `:siteId` in the URL. Errors are `{ code, message, ...details }` with plain-English messages.

**Roles:** Public, Member (create and submit, read), Manager (approve, assign, stock, import), Admin (builder, publish, rollback). Hub admins create sites and run the chaos test.

## Auth and hub

| Method | Path | Who | Notes |
|---|---|---|---|
| POST | `/api/auth/login` | anyone | `{ email, password }` to `{ token, user, memberships }`. Roles are read per request from memberships, never trusted from the token. |
| POST | `/api/auth/refresh` | signed in | new token |
| GET | `/api/me` | signed in | user and memberships |
| GET | `/api/sites` | signed in | sites you belong to, with theme and modules |
| POST | `/api/sites` | hub admin | `{ name, slug, preset? }` creates and publishes a site |
| GET | `/api/sites/:siteId/render-schema` | member | the compiled schema the renderer draws, masked for your role |
| GET | `/api/events?token=` | signed in | server-sent events: `site_published`, `record_changed` |
| POST | `/api/hub/chaos` | hub admin | `{ concurrency: 50, stock: 10 }` runs concurrent approvals and verifies the ledger |

## Builder, versions and releases (Admin of the site)

| Method | Path | Notes |
|---|---|---|
| GET | `/api/sites/:siteId/builder` | live version and latest draft |
| GET | `/api/sites/:siteId/versions` | all versions |
| POST | `/api/sites/:siteId/versions` | `{ config }` new draft, returns diagnostics |
| PUT | `/api/sites/:siteId/versions/:v` | `{ config, expectedRev }`, 409 `DRAFT_CONFLICT` if someone saved meanwhile |
| DELETE | `/api/sites/:siteId/versions/:v` | discard a draft |
| POST | `/api/sites/:siteId/publish` | `{ versionId, confirm? }`, refused with 422 if the Blueprint has errors, 409 if records would be stranded |
| POST | `/api/sites/:siteId/rollback` | `{ versionId, confirm? }` |
| GET | `/api/sites/:siteId/deployments` | history with proof records |

Preview: any GET with header `X-Preview-Version: <draftId>` (Admin only) reads live data through the draft Blueprint. Writes are refused.

## Site resources

| Method | Path | Notes |
|---|---|---|
| GET | `/api/:siteId/components` | modules enabled in this site |
| GET | `/api/:siteId/:entity` | list, `?page&limit&sort&filter[field]=` (entity key or table name, e.g. `requests`) |
| POST | `/api/:siteId/:entity` | create, validated against the role's write mask |
| GET | `/api/:siteId/:entity/:id` | record, `row_version`, and next steps with reasons |
| PATCH | `/api/:siteId/:entity/:id` | `{ ...fields, ifVersion }`, 409 `STALE_RECORD` on mismatch |
| POST | `/api/:siteId/:entity/:id/transition` | `{ to, idempotencyKey, ifVersion?, payload? }` |
| GET | `/api/:siteId/:entity/:id/timeline` | audit events and ledger movements |
| POST | `/api/:siteId/item/:id/stock` | `{ kind: receive or adjust, qty, idempotencyKey }` (Manager+) |
| GET | `/api/:siteId/analytics/:widgetId` | aggregated, respects masks |
| GET | `/api/:siteId/approvals` | decision history |
| POST | `/api/:siteId/approvals` | `{ requestId, decision, note? }` (same engine as transition) |
| GET | `/api/:siteId/assignments` | assignments |
| POST | `/api/:siteId/assignments` | `{ requestId, assignedTo? }` |

## Excel

| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/api/:siteId/excel/template/:entity` | Member+ | columns you may write, dropdowns for choices and links |
| POST | `/api/:siteId/excel/import/:entity?dryRun=true` | Manager+ | body is the raw .xlsx; returns row-by-row errors |
| POST | `/api/:siteId/excel/import/:entity?dryRun=false` | Manager+ | all-or-nothing |
| GET | `/api/:siteId/excel/export/:entity` | Member+ | columns follow your read mask; an About sheet lists hidden columns |

## Error codes

`UNAUTHENTICATED`, `NOT_FOUND`, `NO_MEMBERSHIP`, `FORBIDDEN`, `SITE_HEADER_MISMATCH`, `ENTITY_NOT_IN_SITE`, `VALIDATION_FAILED`, `FIELD_NOT_WRITABLE`, `FIELD_HIDDEN`, `TRANSITION_NOT_ALLOWED`, `GUARD_FAILED`, `INSUFFICIENT_STOCK`, `NO_RESERVATION`, `LAW_VIOLATION`, `STALE_RECORD`, `DRAFT_CONFLICT`, `VERSION_IMMUTABLE`, `GATE_NOT_PASSED`, `DESTRUCTIVE_CHANGE_UNPLANNED`, `ALREADY_LIVE`, `PREVIEW_READ_ONLY`, `DUPLICATE`.

## Example

```bash
TOKEN=$(curl -s localhost:4000/api/auth/login -H 'content-type: application/json' \
  -d '{"email":"manager@sc.dev","password":"demo1234"}' | jq -r .token)
SC=22222222-2222-4222-8222-222222222222
curl -s localhost:4000/api/$SC/requests -H "authorization: Bearer $TOKEN" -H "x-site-id: $SC"
```
'@

W 'docs/DEMO_SCRIPT.md' @'
# Demo script (about 8 minutes)

## Before you go on stage

1. `.\restore.ps1` (clean demo data), then `.\start.ps1`.
2. Browser window A (normal): log in as **Hub admin**.
3. Browser window B (incognito): log in as **Distribution field member** (`field@dist.dev`), open Distribution, leave it on screen.
4. Have `apps/api/test` results ready: run `pnpm test` once so the terminal shows all tests passing.
5. Keep a screen recording of this script as a last resort.

## Brief step 1: one login, three units (1 min)

- Window A: the hub lists Central Stores, Distribution and Service Centre, with the Reuse meter ("27 module instances, 13 implementations").
- Open each unit. Point out that the **layout** changes, not just the colour: dark sidebar with analytics, teal kanban board, amber work queue.
- Press **Ctrl+K** and switch rapidly. No row from one unit ever appears under another.

*Say:* "One login, one codebase. Each unit is a Blueprint; the same renderer draws all of them."

## Brief step 2: two different working systems (2 min)

- **Service Centre:** drag a Submitted card to Approved. Open it: the timeline shows the step and the stock reservation. Start repair commits the stock; a repair log opens.
- **Central Stores:** the stock register with available, reserved and stock value; the Overview dashboard.
- Hub: click **Run chaos**. 50 concurrent approvals against 10 units: exactly 10 succeed, and the ledger matches.

*Say:* "Stock is a ledger with row locks and idempotency keys. It cannot go inconsistent."

## Brief step 3: enable Returns on Distribution with no code (2 min)

- Window A: Hub, Distribution card, **Builder**.
- Drag **Return Management** onto the canvas. It connects itself to Material Assignment; Problems shows none.
- Optional: drag **Approval** into Central Stores' builder first to show "Approval requires Request" and the one-click fix.
- Click **Publish**. Window B (field member) shows "This site was just updated" and a new **Returns** link, with no reload and no restart. Closed requests now have a Return button.
- Versions tab: the deploy history with proof; roll back and forward if time allows.

*Say:* "Typed ports stop invalid systems. Publish is live. Rollback never deletes data."

## Brief step 4: Excel with role rules (1.5 min)

- As `manager@cs.dev`, Central Stores, Stock register: **Template** (dropdowns), fill two rows with one missing SKU, **Import**, **Check file**: the row is reported. Fix, import; stock appears through the ledger.
- **Export**: includes Unit price and Stock value.
- As `member@cs.dev`: **Export** has no price columns (About sheet says why); **Import** is refused by the server with an explanation.

## Close: prove isolation (1 min)

- Show the terminal with `pnpm test` all green, or run `pnpm test:isolation` live (about 4 seconds).
- Explain: FORCE RLS, composite keys, transaction-local site context, 404-not-403, cache wipe on switch.

## Fallbacks

| If | Do |
|---|---|
| Data looks wrong | `.\restore.ps1` then `.\start.ps1`, log in again |
| A page is empty after a reset | Log out and log in again |
| The API window shows a database error | Docker Desktop is not running: start it, then `.\start.ps1` |
| Laptop fails | Play the screen recording |

## Likely judge questions

| Question | Answer |
|---|---|
| How is this different from Retool or Odoo? | Sites are Blueprints compiled by one engine; typed modules cannot be wired wrongly; publish is live and reversible; isolation is enforced by the database and tested. |
| Can a non-developer use it? | Drag a module, read plain-English problems, click Fix, Publish. No JSON needed (the JSON tab is optional). |
| What if two managers approve at once? | The chaos test: row locks on request and item, idempotency keys. Exactly the available quantity succeeds. |
| What if stock is approved but never issued? | Reservations expire; stock is released and the request goes back for re-approval. |
| Prove isolation. | `pnpm test:isolation`, plus 404 for any other unit's data and RLS forced on every table. |
| Scope? | Exactly the 13 approved modules; depth over breadth. |
'@

Write-Host ''
Write-Host 'Batch 6 done. Next: .\start.ps1, pnpm seed, .\backup.ps1, pnpm docs, pnpm test'