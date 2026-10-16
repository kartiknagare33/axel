# Axel - batch 5 (Excel import/export with role-based restrictions). Run from the axel folder.
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
Patch 'apps/api/package.json' @'
    "express": "^4.21.0",
'@ @'
    "exceljs": "^4.4.0",
    "express": "^4.21.0",
'@

Patch 'apps/api/package.json' @'
"test:workflow": "tsx --env-file=../../.env --test test/workflow.test.ts"
'@ @'
"test:workflow": "tsx --env-file=../../.env --test test/workflow.test.ts",
    "test:excel": "tsx --env-file=../../.env --test test/excel.test.ts"
'@

Patch 'package.json' @'
"test:workflow": "pnpm --filter @axel/api test:workflow"
'@ @'
"test:workflow": "pnpm --filter @axel/api test:workflow",
    "test:excel": "pnpm --filter @axel/api test:excel",
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel"
'@

Patch 'apps/api/src/server.ts' @'
import { eventsRouter } from './events';
'@ @'
import { eventsRouter } from './events';
import { excel } from './excel';
'@

Patch 'apps/api/src/server.ts' @'
analytics, workflow, resources);
'@ @'
analytics, workflow, excel, resources);
'@

Patch 'apps/web/src/renderer/views.tsx' @'
import { KanbanBoard } from './kanban';
'@ @'
import { KanbanBoard } from './kanban';
import { ExcelBar } from './excel';
'@

Patch 'apps/web/src/renderer/views.tsx' @'
      <PageHeader title={page.title} count={q.data?.total} onNew={c.onNew} />
      {c.form}
'@ @'
      <PageHeader title={page.title} count={q.data?.total} onNew={c.onNew} />
      {c.form}
      <ExcelBar entity={entity} />
'@

Patch 'apps/web/src/renderer/kanban.tsx' @'
import { RecordForm } from './RecordForm';
'@ @'
import { RecordForm } from './RecordForm';
import { ExcelBar } from './excel';
'@

Patch 'apps/web/src/renderer/kanban.tsx' @'
      {creating && <RecordForm entity={entity} onDone={() => setCreating(false)} onCancel={() => setCreating(false)} />}
'@ @'
      {creating && <RecordForm entity={entity} onDone={() => setCreating(false)} onCancel={() => setCreating(false)} />}
      <ExcelBar entity={entity} />
'@

# ============================== API: excel ==============================
W 'apps/api/src/excel.ts' @'
import { Router, raw, type Response } from 'express';
import ExcelJS from 'exceljs';
import { canRead, canWrite, type Field, type Role } from '@axel/compiler';
import { withSite, type Tx } from './db';
import { TABLES, resolveEntity, toRecord, split } from './entities';
import { AxelError, ah } from './errors';
import { bus } from './blueprints';
import * as ledger from './ledger';

// Excel policy: templates and export for Member+, import for Manager+.
// Column access always follows the Blueprint's per-role read/write masks.
export const excel = Router({ mergeParams: true });

const RANK: Record<Role, number> = { Public: 0, Member: 1, Manager: 2, Admin: 3 };
const MAX_ROWS = 2000;
const labelOf = (r: any) => String(r?.name ?? r?.serial_no ?? r?.sku ?? r?.site_location ?? r?.fault ?? String(r?.id ?? '').slice(0, 8));

function need(req: any, min: Role, what: string) {
  if (RANK[req.site.role as Role] < RANK[min])
    throw new AxelError('FORBIDDEN', 403,
      `Only ${min}s and Admins can ${what} in ${req.site.name} (Excel policy). You are signed in as ${req.site.role}.`,
      { because: { kind: 'excel_policy', min } });
}
function entityOr404(req: any) {
  const e = resolveEntity(req.site.compiled.blueprint, req.params.entity);
  if (!e) throw new AxelError('ENTITY_NOT_IN_SITE', 404, 'Not found.');
  return e;
}
const fieldsOf = (req: any, entity: string) => req.site.compiled.blueprint.entities[entity].fields as Field[];

function cellValue(v: ExcelJS.CellValue): unknown {
  if (v == null) return null;
  if (v instanceof Date) return v.toISOString().slice(0, 10);
  if (typeof v === 'object') {
    const o = v as any;
    if ('result' in o) return cellValue(o.result);
    if ('richText' in o) return o.richText.map((t: any) => t.text).join('');
    if ('text' in o) return o.text;
    if ('error' in o) return null;
  }
  return v;
}

// Relation lookups: accept a name / SKU / id in a cell, export a readable name.
async function lookups(c: Tx, fields: Field[]) {
  const toId = new Map<string, Map<string, string>>();
  const toLabel = new Map<string, Map<string, string>>();
  for (const f of fields) {
    if (f.type !== 'relation' || !f.to || !TABLES[f.to] || toId.has(f.key)) continue;
    const recs = (await c.query(`SELECT * FROM ${TABLES[f.to].table} ORDER BY created_at LIMIT 5000`)).rows.map(r => toRecord(f.to!, r));
    const ids = new Map<string, string>();
    const labels = new Map<string, string>();
    for (const r of recs) {
      const id = String(r.id);
      const l = labelOf(r);
      ids.set(id, id);
      ids.set(l.toLowerCase(), id);
      if (r.sku) ids.set(String(r.sku).toLowerCase(), id);
      labels.set(id, l);
    }
    toId.set(f.key, ids);
    toLabel.set(f.key, labels);
  }
  return { toId, toLabel };
}

async function send(res: Response, wb: ExcelJS.Workbook, name: string) {
  const buf = await wb.xlsx.writeBuffer();
  res.setHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
  res.setHeader('Content-Disposition', `attachment; filename="${name}"`);
  res.send(Buffer.from(buf as ArrayBuffer));
}

// GET /api/:siteId/excel/template/:entity
excel.get('/excel/template/:entity', ah(async (req, res) => {
  const entity = entityOr404(req);
  need(req, 'Member', 'download templates');
  const s = req.site!;
  const cols: Field[] = fieldsOf(req, entity).filter(f => canWrite(f, s.role));
  if (entity === 'item' && RANK[s.role] >= 2) cols.push({ key: 'opening_qty', label: 'Opening qty', type: 'number' });
  const { toLabel } = await withSite(s.ctx, c => lookups(c, cols));

  const wb = new ExcelJS.Workbook();
  wb.creator = 'Axel';
  const ws = wb.addWorksheet('Data');
  const lists = wb.addWorksheet('Lists', { state: 'veryHidden' });
  ws.columns = cols.map(f => ({ header: f.label ?? f.key, key: f.key, width: Math.max(14, (f.label ?? f.key).length + 4) }));
  ws.getRow(1).font = { bold: true };
  ws.views = [{ state: 'frozen', ySplit: 1 }];
  cols.forEach((f, i) => {
    const opts = f.type === 'select' ? f.options ?? []
      : f.type === 'relation' ? [...(toLabel.get(f.key)?.values() ?? [])]
      : f.type === 'boolean' ? ['yes', 'no'] : [];
    if (!opts.length) return;
    opts.forEach((o, j) => { lists.getCell(j + 1, i + 1).value = o; });
    const L = lists.getColumn(i + 1).letter;
    for (let r = 2; r <= 300; r++)
      ws.getCell(r, i + 1).dataValidation = {
        type: 'list', allowBlank: !f.required, formulae: [`Lists!$${L}$1:$${L}$${opts.length}`],
        showErrorMessage: true, errorTitle: f.label ?? f.key, error: 'Pick a value from the list.',
      };
  });
  const help = wb.addWorksheet('How to');
  help.addRow(['Column', 'Type', 'Required', 'Notes']).font = { bold: true };
  for (const f of cols)
    help.addRow([f.label ?? f.key, f.type, f.required ? 'yes' : '',
      f.type === 'relation' ? `Name of an existing ${f.to} in ${s.name}` : f.type === 'select' ? (f.options ?? []).join(', ')
      : f.key === 'opening_qty' ? 'Stock received into the ledger when imported' : '']);
  help.addRow([]);
  help.addRow([`Imports are checked row by row first (dry run). Nothing is saved unless every row is valid.`]);
  help.columns.forEach(c => { c.width = 28; });
  await send(res, wb, `${s.slug}-${entity}-template.xlsx`);
}));

// POST /api/:siteId/excel/import/:entity?dryRun=true|false   (body: raw .xlsx bytes)
excel.post('/excel/import/:entity', raw({ type: 'application/octet-stream', limit: '10mb' }), ah(async (req, res) => {
  const entity = entityOr404(req);
  need(req, 'Manager', 'import spreadsheets');
  const dryRun = req.query.dryRun !== 'false';
  if (!Buffer.isBuffer(req.body) || !req.body.length) throw new AxelError('VALIDATION_FAILED', 422, 'Upload an .xlsx file.');
  const s = req.site!;
  const role = s.role;
  const all = fieldsOf(req, entity);
  const spec = TABLES[entity];

  const wb = new ExcelJS.Workbook();
  try { await wb.xlsx.load(req.body as any); }
  catch { throw new AxelError('VALIDATION_FAILED', 422, 'That file is not a readable .xlsx workbook.'); }
  const ws = wb.worksheets.find(w => w.state === 'visible' && !['How to', 'About', 'Lists'].includes(w.name)) ?? wb.worksheets[0];
  if (!ws) throw new AxelError('VALIDATION_FAILED', 422, 'The workbook has no sheets.');

  // Map header cells to fields (by key or label).
  const map: { col: number; key: string }[] = [];
  const warnings: string[] = [];
  const blocked: string[] = [];
  ws.getRow(1).eachCell((cell, col) => {
    const h = String(cellValue(cell.value) ?? '').trim();
    if (!h) return;
    const hl = h.toLowerCase();
    if (entity === 'item' && (hl === 'opening qty' || hl === 'opening_qty')) { map.push({ col, key: 'opening_qty' }); return; }
    const f = all.find(x => x.key.toLowerCase() === hl || (x.label ?? '').toLowerCase() === hl);
    if (!f) { if (!['state', 'id'].includes(hl)) warnings.push(`Column '${h}' is not a field here and was ignored.`); return; }
    if (f.type === 'formula' || f.system) { warnings.push(`Column '${h}' is calculated by the system and was ignored.`); return; }
    if (!canWrite(f, role)) { blocked.push(h); return; }
    map.push({ col, key: f.key });
  });
  if (blocked.length)
    throw new AxelError('FIELD_NOT_WRITABLE', 422, `Your role (${role}) cannot set: ${blocked.join(', ')}. Remove those columns and try again.`, { fields: blocked });
  if (!map.length) throw new AxelError('VALIDATION_FAILED', 422, 'No recognised columns. Download the template to see the expected headers.');

  const rows: { n: number; raw: Record<string, unknown> }[] = [];
  ws.eachRow((row, n) => {
    if (n === 1) return;
    const r: Record<string, unknown> = {};
    for (const m of map) {
      let v = cellValue(row.getCell(m.col).value);
      if (typeof v === 'string') v = v.trim();
      if (v === '' || v == null) continue;
      r[m.key] = v;
    }
    if (Object.keys(r).length) rows.push({ n, raw: r });
  });
  if (rows.length > MAX_ROWS) throw new AxelError('VALIDATION_FAILED', 422, `Too many rows (${rows.length}). The limit is ${MAX_ROWS}.`);

  const fieldBy = new Map(all.map(f => [f.key, f]));
  const validator = s.compiled.validator(entity, role, 'create');
  const { toId } = await withSite(s.ctx, c => lookups(c, all.filter(f => map.some(m => m.key === f.key))));
  const errors: { row: number; field: string; message: string }[] = [];
  const valid: { n: number; body: Record<string, any>; opening?: number }[] = [];
  const seen = new Map<string, Set<string>>();

  for (const { n, raw: r } of rows) {
    const obj: Record<string, unknown> = {};
    let opening: number | undefined;
    let bad = false;
    for (const [k, v] of Object.entries(r)) {
      if (k === 'opening_qty') {
        const q = Number(v);
        if (!Number.isFinite(q) || q < 0) { errors.push({ row: n, field: 'Opening qty', message: 'must be a number of 0 or more' }); bad = true; }
        else opening = q;
        continue;
      }
      const f = fieldBy.get(k)!;
      if (f.type === 'relation') {
        const id = toId.get(k)?.get(String(v).toLowerCase());
        if (!id) { errors.push({ row: n, field: f.label ?? k, message: `no ${f.to} called '${v}' in this site` }); bad = true; continue; }
        obj[k] = id;
      } else if (f.type === 'boolean') obj[k] = ['yes', 'true', '1', 'y'].includes(String(v).toLowerCase());
      else if (f.type === 'select') obj[k] = f.options?.find(o => o.toLowerCase() === String(v).toLowerCase()) ?? v;
      else if (f.type === 'text') obj[k] = String(v);
      else obj[k] = v;
    }
    const parsed = validator.safeParse(obj);
    if (!parsed.success) {
      for (const i of parsed.error.issues)
        errors.push({ row: n, field: fieldBy.get(String(i.path[0]))?.label ?? String(i.path[0] ?? ''), message: i.message });
      continue;
    }
    if (bad) continue;
    let dup = false;
    for (const f of all.filter(x => x.unique)) {
      const v = parsed.data[f.key];
      if (v == null || v === '') continue;
      const set = seen.get(f.key) ?? new Set<string>();
      seen.set(f.key, set);
      const key = String(v).toLowerCase();
      if (set.has(key)) { errors.push({ row: n, field: f.label ?? f.key, message: `'${v}' appears more than once in this file` }); dup = true; }
      set.add(key);
    }
    if (!dup) valid.push({ n, body: parsed.data, opening });
  }

  // Unique values that already exist in this site.
  await withSite(s.ctx, async c => {
    for (const f of all.filter(x => x.unique)) {
      const vals = valid.map(v => v.body[f.key]).filter(v => v != null && v !== '').map(String);
      if (!vals.length) continue;
      const col = spec.core.includes(f.key) ? `${f.key}::text` : `data->>'${f.key}'`;
      const existing = new Set((await c.query(`SELECT ${col} AS v FROM ${spec.table} WHERE ${col} = ANY($1)`, [vals])).rows.map(r => String(r.v)));
      for (const v of valid) if (existing.has(String(v.body[f.key]))) errors.push({ row: v.n, field: f.label ?? f.key, message: `'${v.body[f.key]}' already exists in this site` });
    }
  });
  errors.sort((a, b) => a.row - b.row);
  const good = valid.filter(v => !errors.some(e => e.row === v.n));

  if (dryRun)
    return res.json({ dryRun: true, rows: rows.length, valid: good.length, errors, warnings, preview: good.slice(0, 5).map(v => ({ row: v.n, ...v.body })) });
  if (errors.length)
    throw new AxelError('VALIDATION_FAILED', 422, `${errors.length} problem(s) found. Nothing was imported. Fix them and try again.`, { errors });

  // All-or-nothing commit in one transaction.
  const imported = await withSite(s.ctx, async c => {
    for (const v of good) {
      const { core, data } = split(spec, v.body);
      if (entity === 'request') { core.state = s.compiled.blueprint.workflows.request?.initial ?? 'draft'; core.requested_by = s.ctx.userId; }
      Object.assign(core, spec.insertDefaults?.());
      const cols = ['site_id', 'created_under_version', ...Object.keys(core), 'data'];
      const row = (await c.query(
        `INSERT INTO ${spec.table} (${cols.join(',')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(',')}) RETURNING id`,
        [s.siteId, s.versionId, ...Object.values(core), data])).rows[0];
      await c.query(
        `INSERT INTO audit_events (site_id, entity, record_id, kind, actor_id, actor_role, after, version_id) VALUES ($1,$2,$3,'import',$4,$5,$6,$7)`,
        [s.siteId, entity, row.id, s.ctx.userId, role, v.body, s.versionId]);
      if (entity === 'item' && v.opening)
        await ledger.move(c, s.ctx, { itemId: row.id, kind: 'receive', qty: v.opening, key: `import-${row.id}`, reason: 'opening balance (Excel import)' });
    }
    return good.length;
  });
  bus.emit('record_changed', { siteId: s.siteId, entity });
  res.json({ dryRun: false, imported, warnings });
}));

// GET /api/:siteId/excel/export/:entity  - columns follow the caller's read mask
excel.get('/excel/export/:entity', ah(async (req, res) => {
  const entity = entityOr404(req);
  need(req, 'Member', 'export');
  const s = req.site!;
  const role = s.role;
  const all = fieldsOf(req, entity);
  const visible = all.filter(f => canRead(f, role));
  const hidden = all.filter(f => !canRead(f, role)).map(f => f.label ?? f.key);
  const hasState = !!s.compiled.blueprint.workflows[entity];

  const { rows, toLabel } = await withSite(s.ctx, async c => {
    const rows = (await c.query(`SELECT * FROM ${TABLES[entity].table} ORDER BY created_at LIMIT 10000`)).rows;
    const lk = await lookups(c, visible);
    await c.query(
      `INSERT INTO audit_events (site_id, entity, record_id, kind, actor_id, actor_role, after, version_id) VALUES ($1,$2,$1,'export',$3,$4,$5,$6)`,
      [s.siteId, entity, s.ctx.userId, role, { rows: rows.length, hidden }, s.versionId]);
    return { rows, toLabel: lk.toLabel };
  });

  const wb = new ExcelJS.Workbook();
  wb.creator = 'Axel';
  const ws = wb.addWorksheet('Data');
  ws.columns = [
    ...visible.map(f => ({ header: f.label ?? f.key, key: f.key, width: Math.max(12, (f.label ?? f.key).length + 4) })),
    ...(hasState ? [{ header: 'State', key: 'state', width: 14 }] : []),
  ];
  for (const r of rows) {
    const rec = s.compiled.mask(entity, role, s.compiled.computeFormulas(entity, toRecord(entity, r)));
    const out: Record<string, unknown> = {};
    for (const f of visible) {
      let v = rec[f.key];
      if (f.type === 'relation' && v) v = toLabel.get(f.key)?.get(String(v)) ?? v;
      out[f.key] = v ?? null;
    }
    if (hasState) out.state = rec.state;
    ws.addRow(out);
  }
  ws.getRow(1).font = { bold: true };
  ws.views = [{ state: 'frozen', ySplit: 1 }];
  ws.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: ws.columns.length } };
  visible.forEach((f, i) => {
    if (f.type === 'money' || (f.type === 'formula' && f.expr?.includes('price'))) ws.getColumn(i + 1).numFmt = '#,##0.00';
  });
  const about = wb.addWorksheet('About');
  about.addRows([
    ['Site', s.name], ['Exported at', new Date().toISOString()], ['Your role', role], ['Rows', rows.length],
    ['Hidden for your role', hidden.length ? hidden.join(', ') : 'none'], ['Blueprint version', s.versionId],
  ]);
  about.getColumn(1).font = { bold: true };
  about.getColumn(1).width = 24;
  about.getColumn(2).width = 60;
  await send(res, wb, `${s.slug}-${entity}-${new Date().toISOString().slice(0, 10)}.xlsx`);
}));
'@

W 'apps/api/test/excel.test.ts' @'
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import ExcelJS from 'exceljs';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const CS = '11111111-1111-4111-8111-111111111111';

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  assert.equal(r.status, 200);
  return (await r.json()).token as string;
}
async function upload(token: string, buf: Buffer, dryRun: boolean) {
  const r = await fetch(`${API}/${CS}/excel/import/item?dryRun=${dryRun}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'x-site-id': CS, 'content-type': 'application/octet-stream' },
    body: buf,
  });
  return { status: r.status, body: (await r.json()) as any };
}
async function exportHeaders(token: string) {
  const r = await fetch(`${API}/${CS}/excel/export/item`, { headers: { authorization: `Bearer ${token}`, 'x-site-id': CS } });
  assert.equal(r.status, 200);
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(Buffer.from(await r.arrayBuffer()) as any);
  const h: string[] = [];
  wb.getWorksheet('Data')!.getRow(1).eachCell(c => { h.push(String(c.value)); });
  return h;
}
async function sheet() {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Data');
  ws.addRow(['SKU', 'Name', 'Category', 'Unit price', 'Opening qty']);
  ws.addRow([`XL-${Date.now()}`, 'Imported cable', 'Electrical', 12.5, 40]);
  ws.addRow(['', 'Row without SKU', 'Electrical', 5, 1]);
  ws.addRow(['CS-001', 'Duplicate of an existing SKU', 'Electrical', 5, 1]);
  return Buffer.from(await wb.xlsx.writeBuffer());
}

let manager = '', member = '';
before(async () => { [manager, member] = await Promise.all(['manager@cs.dev', 'member@cs.dev'].map(login)); });

test('dry run reports bad rows by row number and saves nothing', async () => {
  const r = await upload(manager, await sheet(), true);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.valid, 1);
  const rows = [...new Set(r.body.errors.map((e: any) => e.row))];
  assert.deepEqual(rows, [3, 4]);
});

test('commit is all-or-nothing: a file with errors imports nothing', async () => {
  const r = await upload(manager, await sheet(), false);
  assert.equal(r.status, 422);
  assert.equal(r.body.code, 'VALIDATION_FAILED');
});

test('a Member cannot import (Excel policy is enforced by the server)', async () => {
  const r = await upload(member, await sheet(), true);
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'FORBIDDEN');
});

test('export follows the role mask: Member file has no prices, Manager file does', async () => {
  const m = await exportHeaders(member);
  const g = await exportHeaders(manager);
  assert.ok(!m.includes('Unit price') && !m.includes('Stock value'), `member saw: ${m.join(', ')}`);
  assert.ok(g.includes('Unit price') && g.includes('Stock value'), `manager saw: ${g.join(', ')}`);
});
'@

# ============================== WEB: Excel bar ==============================
W 'apps/web/src/renderer/excel.tsx' @'
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { http, errOf, type ApiErr } from '../api';
import { useSite, RANK } from '../hooks';
import { Denial, btn, btnGhost } from './fields';

async function blobErr(e: any): Promise<ApiErr> {
  const d = e?.response?.data;
  if (d instanceof Blob) {
    try { const j = JSON.parse(await d.text()); return { message: j.message, code: j.code }; } catch { /* fall through */ }
  }
  return errOf(e);
}

export function ExcelBar({ entity }: { entity: string }) {
  const { siteId, schema } = useSite();
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [report, setReport] = useState<any>(null);
  const [err, setErr] = useState<ApiErr | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState('');
  if (!schema.modules.includes('excel')) return null;
  const H = { 'X-Site-Id': siteId };
  const isManager = RANK[schema.role] >= 2;

  async function download(path: string, fallback: string) {
    setErr(null);
    try {
      const r = await http.get(`/${siteId}${path}`, { headers: H, responseType: 'blob' });
      const name = /filename="([^"]+)"/.exec(String(r.headers['content-disposition'] ?? ''))?.[1] ?? fallback;
      const url = URL.createObjectURL(r.data);
      const a = document.createElement('a');
      a.href = url; a.download = name;
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (e) { setErr(await blobErr(e)); }
  }

  async function run(dryRun: boolean) {
    if (!file) return;
    setBusy(true); setErr(null); setDone('');
    try {
      const r = await http.post(`/${siteId}/excel/import/${entity}?dryRun=${dryRun}`, await file.arrayBuffer(),
        { headers: { ...H, 'Content-Type': 'application/octet-stream' } });
      if (dryRun) setReport(r.data);
      else {
        setDone(`Imported ${r.data.imported} row(s).`);
        setReport(null); setFile(null);
        qc.invalidateQueries({ predicate: q => q.queryKey[1] === siteId });
      }
    } catch (e: any) {
      setErr(errOf(e));
      if (e?.response?.data?.errors) setReport((p: any) => ({ ...(p ?? {}), errors: e.response.data.errors }));
    } finally { setBusy(false); }
  }

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="text-xs font-medium uppercase text-slate-400">Excel</span>
        <button onClick={() => download(`/excel/export/${entity}`, `${entity}.xlsx`)} className={btnGhost}>Export</button>
        <button onClick={() => download(`/excel/template/${entity}`, `${entity}-template.xlsx`)} className={btnGhost}>Template</button>
        <button onClick={() => { setOpen(o => !o); setReport(null); setErr(null); setDone(''); }} className={btnGhost}>Import...</button>
        {!isManager && <span className="text-xs text-slate-400">Your export leaves out columns your role cannot see.</span>}
      </div>
      {open && (
        <div className="space-y-3 rounded-site border bg-white p-4 text-sm">
          <div className="text-slate-600">Upload an .xlsx (use Template for the right columns). The file is checked first; nothing is saved unless every row is valid.</div>
          <input type="file" accept=".xlsx" onChange={e => { setFile(e.target.files?.[0] ?? null); setReport(null); setErr(null); setDone(''); }} />
          <div className="flex gap-2">
            <button disabled={!file || busy} onClick={() => run(true)} className={btnGhost}>{busy ? 'Checking...' : 'Check file (dry run)'}</button>
            <button disabled={!file || busy || !report || (report.errors?.length ?? 0) > 0 || !report.valid} onClick={() => run(false)} className={btn}>
              Import {report?.valid ?? ''} row(s)
            </button>
          </div>
          {report && report.rows != null && (
            <div className={`rounded px-3 py-2 ${report.errors?.length ? 'bg-amber-50 text-amber-900' : 'bg-emerald-50 text-emerald-800'}`}>
              {report.rows} row(s) read - {report.valid} valid - {report.errors?.length ?? 0} problem(s)
            </div>
          )}
          {!!report?.errors?.length && (
            <table className="w-full text-left text-xs">
              <thead className="text-slate-500"><tr><th className="py-1">Row</th><th>Column</th><th>Problem</th></tr></thead>
              <tbody>{report.errors.map((e: any, i: number) => (
                <tr key={i} className="border-t"><td className="py-1">{e.row}</td><td>{e.field}</td><td>{e.message}</td></tr>
              ))}</tbody>
            </table>
          )}
          {!!report?.warnings?.length && <ul className="list-disc pl-5 text-xs text-slate-500">{report.warnings.map((w: string) => <li key={w}>{w}</li>)}</ul>}
          {err && <Denial err={err} />}
          {done && <div className="rounded bg-emerald-50 px-3 py-2 text-emerald-800">{done}</div>}
        </div>
      )}
      {!open && err && <Denial err={err} />}
    </div>
  );
}
'@

Write-Host ''
Write-Host 'Batch 5 done. Next: pnpm install, then pnpm dev:api, pnpm dev:web, pnpm test:excel'