import { Router, raw } from 'express';
import { randomUUID } from 'node:crypto';
import ExcelJS from 'exceljs';
import { z } from 'zod';
import { compile, infer, snakeCase, type Blueprint, type Field, type InferMapping, type Sheet } from '@axel/compiler';
import { withSite, type Tx } from './db';
import { requireAuth, requireHubAdmin } from './auth';
import { AxelError, ah } from './errors';
import { hashBlueprint } from './sites';
import * as ledger from './ledger';

export const inferRouter = Router();

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

export async function parseWorkbook(buf: Buffer): Promise<Sheet[]> {
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(buf as any);
  const out: Sheet[] = [];
  wb.eachSheet(ws => {
    if (ws.state && ws.state !== 'visible') return;
    let hr = 1;
    for (let r = 1; r <= Math.min(10, ws.rowCount); r++) {
      let n = 0;
      ws.getRow(r).eachCell(() => { n++; });
      if (n >= 2) { hr = r; break; }
    }
    const cols: number[] = [];
    const headers: string[] = [];
    ws.getRow(hr).eachCell((cell, col) => {
      const h = String(cellValue(cell.value) ?? '').trim();
      if (h) { cols.push(col); headers.push(h); }
    });
    if (headers.length < 2) return;
    const rows: unknown[][] = [];
    const formulas: (string | null)[][] = [];
    const money = cols.map(() => false);
    const lists: (string[] | null)[] = cols.map(() => null);
    for (let r = hr + 1; r <= ws.rowCount && rows.length < 2000; r++) {
      const row = ws.getRow(r);
      const vals: unknown[] = [];
      const fs: (string | null)[] = [];
      let any = false;
      cols.forEach((c, i) => {
        const cell = row.getCell(c);
        const v: any = cell.value;
        let f: string | null = null;
        if (v && typeof v === 'object' && 'formula' in v) f = String(v.formula);
        else if (v && typeof v === 'object' && 'sharedFormula' in v) f = '__shared__';
        const out = cellValue(v);
        if (out !== null && out !== '') any = true;
        vals.push(out);
        fs.push(f);
        if (cell.numFmt && /[$\u20B9\u20AC\u00A3]|INR|Rs/.test(cell.numFmt)) money[i] = true;
        const dv: any = cell.dataValidation;
        if (!lists[i] && dv?.type === 'list' && typeof dv.formulae?.[0] === 'string' && dv.formulae[0].startsWith('"'))
          lists[i] = dv.formulae[0].replace(/"/g, '').split(',').map((x: string) => x.trim()).filter(Boolean);
      });
      if (any) { rows.push(vals); formulas.push(fs); }
    }
    out.push({ name: ws.name, headers, letters: cols.map(c => ws.getColumn(c).letter), rows, formulas, lists, money });
  });
  return out;
}

function conv(f: Field | undefined, v: unknown): unknown {
  if (!f || v === null || v === undefined || v === '') return undefined;
  switch (f.type) {
    case 'number': case 'money': { const n = typeof v === 'number' ? v : Number(String(v).replace(/,/g, '')); return Number.isFinite(n) ? n : undefined; }
    case 'boolean': return v === true || /^(yes|true|y|1)$/i.test(String(v));
    case 'select': return f.options?.find(o => o.toLowerCase() === String(v).trim().toLowerCase()) ?? String(v).trim();
    case 'date': return String(v).slice(0, 10);
    case 'formula': return undefined;
    default: return String(v).trim();
  }
}

async function importRows(c: Tx, ctx: any, bp: Blueprint, sheets: Sheet[], m: InferMapping) {
  const itemDefs = new Map(bp.entities.item.fields.map(f => [f.key, f]));
  const index = new Map<string, string>();
  let items = 0;
  let requests = 0;
  let skipped = 0;
  const newItem = async (name: string, data: Record<string, unknown>) => {
    const id = (await c.query('INSERT INTO items (site_id, name, on_hand, data, created_under_version, created_by) VALUES ($1,$2,0,$3,$4,$5) RETURNING id',
      [ctx.siteId, name.slice(0, 200), data, ctx.versionId, ctx.userId])).rows[0].id as string;
    index.set(name.toLowerCase(), id);
    if (data.sku) index.set(String(data.sku).toLowerCase(), id);
    items++;
    return id;
  };
  if (m.item) {
    const s = sheets[m.item.sheet];
    const seen = new Set<string>();
    for (const [k, row] of s.rows.entries()) {
      const data: Record<string, unknown> = {};
      for (const [key, col] of Object.entries(m.item.cols)) {
        if (key === 'name' || key === 'on_hand') continue;
        const v = conv(itemDefs.get(key), row[col]);
        if (v !== undefined) data[key] = v;
      }
      const name = String(row[m.item.cols.name] ?? data.sku ?? `Item ${k + 1}`).trim() || `Item ${k + 1}`;
      const dedupe = String(data.sku ?? name).toLowerCase();
      if (seen.has(dedupe)) { skipped++; continue; }
      seen.add(dedupe);
      const id = await newItem(name, data);
      const qty = m.item.stockCol !== undefined ? Number(row[m.item.stockCol]) : 0;
      if (Number.isFinite(qty) && qty > 0) await ledger.move(c, ctx, { itemId: id, kind: 'receive', qty, key: `infer-${id}`, reason: 'opening balance (spreadsheet)' });
    }
  }
  if (m.request && bp.entities.request) {
    const s = sheets[m.request.sheet];
    const defs = new Map(bp.entities.request.fields.map(f => [f.key, f]));
    const initial = bp.workflows.request?.initial ?? 'draft';
    const states = new Set(bp.workflows.request?.states ?? []);
    for (const row of s.rows) {
      const ref = m.request.cols.item_id !== undefined ? String(row[m.request.cols.item_id] ?? '').trim() : '';
      const refName = ref || 'Unspecified item';
      const itemId = index.get(refName.toLowerCase()) ?? await newItem(refName, {});
      const qtyRaw = m.request.cols.qty !== undefined ? Number(row[m.request.cols.qty]) : 1;
      const qty = Number.isFinite(qtyRaw) && qtyRaw >= 1 ? qtyRaw : 1;
      const st = m.request.statusCol !== undefined ? m.request.statusMap[snakeCase(row[m.request.statusCol])] : undefined;
      const state = st && states.has(st) ? st : initial;
      const data: Record<string, unknown> = {};
      for (const [key, col] of Object.entries(m.request.cols)) {
        if (key === 'item_id' || key === 'qty') continue;
        const v = conv(defs.get(key), row[col]);
        if (v !== undefined) data[key] = v;
      }
      const id = (await c.query(
        `INSERT INTO requests (site_id, item_id, qty, state, requested_by, data, created_under_version) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
        [ctx.siteId, itemId, qty, state, ctx.userId, data, ctx.versionId])).rows[0].id;
      await c.query(
        `INSERT INTO audit_events (site_id, entity, record_id, kind, actor_id, actor_role, after, version_id) VALUES ($1,'request',$2,'import',$3,'Admin',$4,$5)`,
        [ctx.siteId, id, ctx.userId, { source: s.name, state }, ctx.versionId]);
      requests++;
    }
  }
  return { items, requests, skipped };
}

// POST /api/sites/infer?name=&slug=&create=false|true   (body: raw .xlsx)
inferRouter.post('/infer', requireAuth, requireHubAdmin, raw({ type: 'application/octet-stream', limit: '10mb' }), ah(async (req, res) => {
  const q = z.object({
    name: z.string().min(2).max(60),
    slug: z.string().regex(/^[a-z0-9][a-z0-9-]{1,40}$/).optional(),
    create: z.enum(['true', 'false']).default('false'),
  }).parse(req.query);
  if (!Buffer.isBuffer(req.body) || !req.body.length) throw new AxelError('VALIDATION_FAILED', 422, 'Upload an .xlsx file.');
  let sheets: Sheet[];
  try { sheets = await parseWorkbook(req.body); }
  catch { throw new AxelError('VALIDATION_FAILED', 422, 'That file is not a readable .xlsx workbook.'); }
  if (!sheets.length) throw new AxelError('VALIDATION_FAILED', 422, 'No sheet with at least two column headers was found.');

  const result = infer(sheets, { name: q.name });
  const diagnostics = compile(result.blueprint).diagnostics;
  const counts = {
    items: result.mapping.item ? sheets[result.mapping.item.sheet].rows.length : 0,
    requests: result.mapping.request ? sheets[result.mapping.request.sheet].rows.length : 0,
  };
  const sheetInfo = sheets.map(s => ({ name: s.name, rows: s.rows.length, headers: s.headers }));
  if (q.create === 'false') return res.json({ ...result, diagnostics, counts, sheets: sheetInfo });

  if (diagnostics.some(d => d.severity === 'error'))
    throw new AxelError('VALIDATION_FAILED', 422, 'The inferred site has problems; open it as a preview and fix them in the builder.', { diagnostics });
  const siteId = randomUUID();
  const slug = q.slug ?? (snakeCase(q.name).replace(/_/g, '-').slice(0, 40) || `unit-${Date.now()}`);
  const userId = req.user!.id;
  const bp: Blueprint = { ...result.blueprint, siteId, slug, name: q.name };
  const imported = await withSite({ siteId, userId, role: 'Admin' }, async c => {
    await c.query('INSERT INTO sites (id, slug, name, created_by) VALUES ($1,$2,$3,$4)', [siteId, slug, q.name, userId]);
    await c.query(`INSERT INTO memberships (site_id, user_id, role) VALUES ($1,$2,'Admin')`, [siteId, userId]);
    const v = (await c.query(
      `INSERT INTO site_versions (site_id, config, content_hash, status, author_id, reason) VALUES ($1,$2,$3,'published',$4,$5) RETURNING id`,
      [siteId, bp, hashBlueprint(bp), userId, 'inferred from spreadsheet'])).rows[0].id;
    await c.query('INSERT INTO site_deployments (site_id, version_id, proof, deployed_by) VALUES ($1,$2,$3,$4)',
      [siteId, v, { versionHash: hashBlueprint(bp), kind: 'publish', inferred: { inferences: result.inferences.length, sheets: sheetInfo.map(s => s.name) } }, userId]);
    await c.query('UPDATE sites SET published_version_id = $2 WHERE id = $1', [siteId, v]);
    const r = await importRows(c, { siteId, userId, role: 'Admin', versionId: v }, bp, sheets, result.mapping);
    await c.query(`SELECT pg_notify('site_published', $1)`, [`${siteId}:${v}`]);
    return r;
  });
  res.status(201).json({ id: siteId, slug, name: q.name, imported });
}));
