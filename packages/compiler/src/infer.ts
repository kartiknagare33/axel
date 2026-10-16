import type { Blueprint, Entity, Field, Law, Page, Role, Transition, Widget } from './types';
import { parse } from './expr';
import { autoWire } from './ports';

export interface Sheet {
  name: string; headers: string[]; letters: string[]; rows: unknown[][];
  formulas: (string | null)[][]; lists: (string[] | null)[]; money: boolean[];
}
export interface Inference { rule: string; target: string; confidence: number; explanation: string }
export interface InferMapping {
  item?: { sheet: number; cols: Record<string, number>; stockCol?: number };
  request?: { sheet: number; cols: Record<string, number>; statusCol?: number; statusMap: Record<string, string> };
  derivedItems: boolean;
}
export interface InferResult { blueprint: Blueprint; inferences: Inference[]; mapping: InferMapping }

const SYN: Record<string, string[]> = {
  sku: ['sku', 'code', 'item code', 'part no', 'part number', 'material code', 'item id', 'product code'],
  name: ['name', 'item', 'item name', 'description', 'material', 'material name', 'product', 'part', 'part name', 'tool', 'tool name', 'equipment', 'asset'],
  on_hand: ['stock', 'stock qty', 'qty on hand', 'on hand', 'balance', 'closing stock', 'available stock', 'stock quantity', 'current stock', 'in stock'],
  unit_price: ['price', 'unit price', 'rate', 'unit cost', 'cost', 'mrp', 'unit rate'],
  category: ['category', 'type', 'group', 'class', 'item type'],
  value: ['value', 'stock value', 'total value', 'amount', 'total', 'line total', 'total cost'],
  qty: ['qty', 'quantity', 'requested qty', 'qty requested', 'issued qty', 'quantity requested', 'units', 'nos'],
  status: ['status', 'stage', 'state', 'current status'],
  requested_by: ['requested by', 'raised by', 'employee', 'requester', 'indentor', 'customer'],
  approved_by: ['approved by', 'approver', 'sanctioned by', 'authorised by', 'authorized by'],
  assigned_to: ['assigned to', 'issued to', 'technician', 'engineer', 'handed to'],
  serial_no: ['serial', 'serial no', 'serial number', 'board serial', 'pcb serial', 'board no', 'pcb no'],
  fault: ['fault', 'issue', 'problem', 'complaint', 'defect', 'fault reported'],
  consumed_qty: ['consumed', 'consumed qty', 'used', 'used qty', 'utilised', 'utilized', 'qty used'],
  returned_on: ['returned on', 'return date', 'returned date', 'returned'],
  location: ['location', 'site', 'field location', 'area', 'ward', 'zone'],
  ref: ['ticket', 'ticket no', 'ref', 'reference', 'request no', 'issue no', 'indent no', 'job no', 'id'],
};
const STATUS_SYN: Record<string, string> = {
  new: 'draft', draft: 'draft', pending: 'submitted', requested: 'submitted', submitted: 'submitted', open: 'submitted', raised: 'submitted',
  approved: 'approved', sanctioned: 'approved', authorised: 'approved', authorized: 'approved',
  rejected: 'rejected', declined: 'rejected', cancelled: 'rejected', canceled: 'rejected',
  assigned: 'assigned', issued: 'assigned', dispatched: 'assigned',
  in_repair: 'in_repair', repairing: 'in_repair', in_progress: 'in_repair', under_repair: 'in_repair',
  repaired: 'closed', closed: 'closed', completed: 'closed', done: 'closed', delivered: 'closed',
  returned: 'returned',
};
const ORDER = ['draft', 'submitted', 'approved', 'assigned', 'in_repair', 'closed', 'returned'];
const LABEL: Record<string, string> = { submitted: 'Submit', approved: 'Approve', rejected: 'Reject', assigned: 'Assign', in_repair: 'Start repair', closed: 'Close', returned: 'Return' };
const RESERVED = new Set(['id', 'state', 'row_version', 'created_at', 'updated_at', 'data', 'site_id', 'available', 'reserved', 'on_hand', 'requested_by']);
const M: Role[] = ['Member', 'Manager', 'Admin'];
const MG: Role[] = ['Manager', 'Admin'];
const MASK = { read: MG, write: MG };

export const normHeader = (h: string) => h.toLowerCase().replace(/[^a-z0-9]+/g, ' ').replace(/\s+/g, ' ').trim();
export const snakeCase = (v: unknown) => String(v ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 30);

function lev(a: string, b: string) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++)
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return d[a.length][b.length];
}
function score(h: string, key: string) {
  const n = normHeader(h);
  const list = SYN[key];
  if (list.includes(n)) return 1;
  if (list.some(s => s.length >= 4 && (n.startsWith(s + ' ') || n.endsWith(' ' + s)))) return 0.8;
  if (n.length >= 6 && list.some(s => s.length >= 6 && lev(n, s) <= 2)) return 0.7;
  return 0;
}

const isNum = (v: unknown) => typeof v === 'number' || (typeof v === 'string' && v.trim() !== '' && !isNaN(Number(v.replace(/,/g, ''))));
const toNum = (v: unknown) => (typeof v === 'number' ? v : Number(String(v).replace(/,/g, '')));
const isDate = (v: unknown) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}/.test(v);

function profile(s: Sheet, col: number) {
  const vals = s.rows.map(r => r[col]).filter(v => v !== null && v !== undefined && v !== '');
  const n = vals.length || 1;
  const nums = vals.filter(isNum).map(toNum);
  const values = [...new Set(vals.map(v => String(v).trim()))];
  const lower = new Set(values.map(v => v.toLowerCase()));
  let min: number | null = null;
  for (const x of nums) if (min === null || x < min) min = x;
  return {
    count: vals.length, values, distinct: lower.size, unique: vals.length > 0 && lower.size === vals.length, min,
    numRatio: nums.length / n, dateRatio: vals.filter(isDate).length / n,
    boolRatio: vals.filter(v => typeof v === 'boolean' || /^(yes|no|true|false|y|n)$/i.test(String(v))).length / n,
    formulaRatio: s.formulas.filter(f => f[col]).length / (s.rows.length || 1),
    firstFormula: s.formulas.map(f => f[col]).find(f => f && f !== '__shared__') ?? null,
  };
}

function convertFormula(f: string, s: Sheet, keyOfCol: (i: number) => string | undefined): { expr?: string; reason?: string } {
  if (f.includes('!')) return { reason: 'it refers to another sheet' };
  const refRe = /\$?([A-Z]{1,3})\$?(\d+)/g;
  const refs = [...f.matchAll(refRe)];
  if (!refs.length) return { reason: 'it has no cell references' };
  if (new Set(refs.map(m => m[2])).size > 1) return { reason: 'it refers to other rows' };
  if (/[A-Za-z_]+\s*\(/.test(f.replace(refRe, ''))) return { reason: 'it uses spreadsheet functions' };
  let bad = '';
  const expr = f.replace(refRe, (_m, letter: string) => {
    const i = s.letters.indexOf(letter);
    const k = i >= 0 ? keyOfCol(i) : undefined;
    if (!k) bad = letter;
    return k ?? 'x';
  }).replace(/\s+/g, ' ').trim();
  if (bad) return { reason: `column ${bad} is not a field` };
  try { parse(expr); } catch (e) { return { reason: (e as Error).message }; }
  return { expr: expr.replace(/\s*([*/+-])\s*/g, ' $1 ') };
}

const pct = (x: number) => `${Math.round(x * 100)}%`;

/** Rule-based, deterministic: spreadsheets in, draft Blueprint plus explained inferences out. */
export function infer(sheets: Sheet[], opts: { name: string }): InferResult {
  const inferences: Inference[] = [];
  const note = (rule: string, target: string, confidence: number, explanation: string) =>
    inferences.push({ rule, target, confidence: Math.round(Math.max(0, Math.min(1, confidence)) * 100) / 100, explanation });

  // 1. Which sheet is what
  const REQ = ['status', 'requested_by', 'approved_by', 'assigned_to', 'serial_no', 'fault'];
  const ITEM = ['name', 'sku', 'on_hand', 'unit_price', 'category'];
  const scored = sheets.map((s, i) => ({
    i, s,
    req: REQ.filter(k => s.headers.some(h => score(h, k) >= 0.8)),
    item: ITEM.filter(k => s.headers.some(h => score(h, k) >= 0.8)),
  }));
  const reqS = [...scored].sort((a, b) => b.req.length - a.req.length)[0];
  const reqSheet = reqS && reqS.req.length > 0 ? reqS : undefined;
  const itemS = scored.filter(x => x !== reqSheet && x.item.length >= 2).sort((a, b) => b.item.length - a.item.length)[0]
    ?? (!reqSheet ? [...scored].sort((a, b) => b.item.length - a.item.length)[0] : undefined);
  if (itemS) note('ENTITY', 'item', itemS.item.length >= 2 ? 0.9 : 0.5, `Sheet '${itemS.s.name}' (${itemS.s.rows.length} rows) is the stock list: it has ${itemS.item.join(', ') || 'few recognisable'} columns.`);
  if (reqSheet) note('ENTITY', 'request', 0.9, `Sheet '${reqSheet.s.name}' (${reqSheet.s.rows.length} rows) is a request register: it has ${reqSheet.req.join(', ')} columns.`);
  for (const x of scored) if (x !== reqSheet && x !== itemS) note('ENTITY', x.s.name, 0.3, `Sheet '${x.s.name}' was not used: it does not look like a stock list or a request register.`);

  const mapping: InferMapping = { derivedItems: false };
  const genericFields = (s: Sheet, used: Set<number>, keys: Set<string>, entity: string, cols: Record<string, number>, fields: Field[], deferred: number[]) => {
    s.headers.forEach((h, col) => {
      if (used.has(col)) return;
      const p = profile(s, col);
      if (!p.count) return;
      if (p.formulaRatio >= 0.5) { deferred.push(col); return; }
      let key = snakeCase(h) || `col_${col + 1}`;
      if (/^\d/.test(key)) key = `f_${key}`;
      while (RESERVED.has(key) || keys.has(key)) key = `${key}_2`;
      keys.add(key);
      const f: Field = { key, label: h, type: 'text', origin: { kind: 'sheet', sheet: s.name, column: s.letters[col] } };
      if (s.lists[col]?.length) { f.type = 'select'; f.options = s.lists[col]!; note('SELECT', `${entity}.${key}`, 0.95, `'${h}' has a dropdown in the sheet: ${f.options.join(', ')}.`); }
      else if (p.dateRatio >= 0.8) { f.type = 'date'; note('FIELD_TYPE', `${entity}.${key}`, p.dateRatio, `'${h}': ${pct(p.dateRatio)} of values are dates.`); }
      else if (p.numRatio >= 0.8) {
        const money = s.money[col] || /price|cost|amount|rate|value/.test(normHeader(h));
        f.type = money ? 'money' : 'number';
        if (money) { f.roles = MASK; note('MONEY', `${entity}.${key}`, s.money[col] ? 0.95 : 0.8, `'${h}' holds money${s.money[col] ? ' (currency format)' : ''}; hidden from Members by default.`); }
        else note('FIELD_TYPE', `${entity}.${key}`, p.numRatio, `'${h}': ${pct(p.numRatio)} of values are numbers.`);
      } else if (p.boolRatio >= 0.9 && p.distinct <= 2) { f.type = 'boolean'; note('FIELD_TYPE', `${entity}.${key}`, p.boolRatio, `'${h}' only says yes or no.`); }
      else if (p.distinct <= 8 && p.count >= 10) {
        f.type = 'select'; f.options = p.values;
        note('SELECT', `${entity}.${key}`, 0.7, `'${h}' has only ${p.distinct} different values in ${p.count} rows: ${p.values.join(', ')}.`);
      } else note('FIELD_TYPE', `${entity}.${key}`, 0.6, `'${h}' is free text.`);
      fields.push(f);
      cols[key] = col;
      used.add(col);
    });
  };
  const formulaFields = (s: Sheet, deferred: number[], cols: Record<string, number>, keys: Set<string>, entity: string, fields: Field[], preferKey?: string) => {
    const keyOfCol = (i: number) => Object.entries(cols).find(([, c]) => c === i)?.[0];
    for (const col of deferred) {
      const h = s.headers[col];
      const p = profile(s, col);
      const conv = p.firstFormula ? convertFormula(p.firstFormula, s, keyOfCol) : { reason: 'the formula could not be read' };
      let key = preferKey && !keys.has(preferKey) ? preferKey : snakeCase(h) || `calc_${col + 1}`;
      while (RESERVED.has(key) || (keys.has(key) && key !== preferKey)) key = `${key}_2`;
      keys.add(key);
      if (conv.expr) {
        fields.push({ key, label: h, type: 'formula', expr: conv.expr, roles: { read: MG }, origin: { kind: 'sheet', sheet: s.name, column: s.letters[col] } });
        note('FORMULA', `${entity}.${key}`, 0.95, `'${h}' is calculated as =${p.firstFormula} in ${pct(p.formulaRatio)} of rows; mapped to ${conv.expr}.`);
      } else {
        fields.push({ key, label: h, type: 'number', origin: { kind: 'sheet', sheet: s.name, column: s.letters[col] } });
        cols[key] = col;
        note('FORMULA', `${entity}.${key}`, 0.4, `'${h}' has formulas but ${conv.reason}; kept as a plain number. Check this.`);
      }
      preferKey = undefined;
    }
  };

  // 2. Items
  const itemFields: Field[] = [];
  const itemCols: Record<string, number> = {};
  const itemKeys = new Set<string>(['name']);
  let stockSeen = false;
  let priceSeen = false;
  if (itemS) {
    const s = itemS.s;
    const used = new Set<number>();
    const take = (k: string) => { let best: { col: number; conf: number } | undefined; s.headers.forEach((h, i) => { if (used.has(i)) return; const sc = score(h, k); if (sc && (!best || sc > best.conf)) best = { col: i, conf: sc }; }); if (best) used.add(best.col); return best; };
    const sku = take('sku'); const name = take('name'); const stock = take('on_hand') ?? take('qty'); const price = take('unit_price');
    const cat = take('category'); const value = take('value');
    if (sku) {
      const p = profile(s, sku.col);
      itemFields.push({ key: 'sku', type: 'text', label: s.headers[sku.col], required: true, unique: p.unique, origin: { kind: 'sheet', sheet: s.name, column: s.letters[sku.col] } });
      itemCols.sku = sku.col; itemKeys.add('sku');
      note('FIELD', 'item.sku', sku.conf, `'${s.headers[sku.col]}' is the item code.`);
      if (p.unique && p.count >= 10) note('LAW_UNIQUE', 'item.sku', 0.9, `All ${p.count} values of '${s.headers[sku.col]}' are different, so it is unique per site.`);
    }
    itemFields.push({ key: 'name', type: 'text', label: name ? s.headers[name.col] : 'Name', required: true });
    if (name) { itemCols.name = name.col; note('FIELD', 'item.name', name.conf, `'${s.headers[name.col]}' is the item name.`); }
    if (cat) {
      const p = profile(s, cat.col);
      const options = s.lists[cat.col] ?? (p.distinct <= 12 ? p.values : null);
      itemFields.push(options?.length
        ? { key: 'category', type: 'select', label: s.headers[cat.col], options }
        : { key: 'category', type: 'text', label: s.headers[cat.col] });
      itemCols.category = cat.col; itemKeys.add('category');
      if (options?.length) note('SELECT', 'item.category', s.lists[cat.col] ? 0.95 : 0.75, `'${s.headers[cat.col]}' has ${options.length} choices: ${options.join(', ')}.`);
    }
    if (price) {
      itemFields.push({ key: 'unit_price', type: 'money', label: s.headers[price.col], roles: MASK, reason: 'cost confidential' });
      itemCols.unit_price = price.col; itemKeys.add('unit_price'); priceSeen = true;
      note('MONEY', 'item.unit_price', s.money[price.col] ? 0.95 : 0.85, `'${s.headers[price.col]}' is the unit price${s.money[price.col] ? ' (currency format)' : ''}.`);
      note('HIDDEN_COST', 'item.unit_price', 0.6, 'Prices are hidden from Members by default (a Law protects this). Change it in the builder if Members should see them.');
    }
    itemFields.push({ key: 'on_hand', type: 'number', label: 'On hand', system: true }, { key: 'reserved', type: 'number', label: 'Reserved', system: true }, { key: 'available', type: 'number', label: 'Available', system: true });
    if (stock) {
      itemCols.on_hand = stock.col; stockSeen = true;
      const p = profile(s, stock.col);
      note('FIELD', 'item.on_hand', stock.conf, `'${s.headers[stock.col]}' becomes the opening stock, received through the ledger.`);
      if (p.min !== null && p.min >= 0) note('LAW_NON_NEGATIVE', 'laws', 0.8, `'${s.headers[stock.col]}' never goes below 0 in ${p.count} rows, so on-hand stock may never go negative.`);
    }
    const deferred: number[] = [];
    if (value && profile(s, value.col).formulaRatio >= 0.5) deferred.push(value.col); else if (value) used.delete(value.col);
    genericFields(s, used, itemKeys, 'item', itemCols, itemFields, deferred);
    formulaFields(s, deferred, itemCols, itemKeys, 'item', itemFields, value && deferred.includes(value.col) ? 'stock_value' : undefined);
    if (!itemFields.some(f => f.type === 'formula') && stock && price) {
      itemFields.push({ key: 'stock_value', type: 'formula', label: 'Stock value', expr: 'on_hand * unit_price', roles: { read: MG } });
      note('FORMULA', 'item.stock_value', 0.7, 'Added Stock value = on_hand * unit_price because the sheet has both stock and price.');
    }
    mapping.item = { sheet: itemS.i, cols: itemCols, stockCol: stock?.col };
  } else {
    itemFields.push({ key: 'name', type: 'text', label: 'Name', required: true },
      { key: 'on_hand', type: 'number', label: 'On hand', system: true }, { key: 'reserved', type: 'number', label: 'Reserved', system: true }, { key: 'available', type: 'number', label: 'Available', system: true });
  }

  // 3. Requests and workflow
  const entities: Record<string, Entity> = { item: { owner_module: 'inventory', label: 'Item', fields: itemFields } };
  const modules = ['auth', 'users', 'dashboard', 'inventory'];
  let wf: Blueprint['workflows']['request'] | undefined;
  let pcb = false;
  let ma = false;
  let consumption = false;
  const reqFields: Field[] = [];
  if (reqSheet) {
    const s = reqSheet.s;
    const used = new Set<number>();
    const keys = new Set<string>(['item_id', 'qty']);
    const cols: Record<string, number> = {};
    const take = (k: string) => { let best: { col: number; conf: number } | undefined; s.headers.forEach((h, i) => { if (used.has(i)) return; const sc = score(h, k); if (sc && (!best || sc > best.conf)) best = { col: i, conf: sc }; }); if (best) used.add(best.col); return best; };
    const status = take('status'); const requester = take('requested_by'); const approver = take('approved_by'); const assignee = take('assigned_to');
    const ref = take('ref'); const serial = take('serial_no'); const fault = take('fault'); const consumed = take('consumed_qty');
    const returned = take('returned_on'); const location = take('location');
    let itemCol: { col: number; conf: number } | undefined;
    const want = itemS ? [itemCols.name, itemCols.sku].filter(c => c !== undefined).map(c => normHeader(itemS.s.headers[c])) : [];
    const exact = s.headers.findIndex((h, k) => !used.has(k) && want.includes(normHeader(h)));
    if (exact >= 0) { used.add(exact); itemCol = { col: exact, conf: 0.9 }; } else itemCol = take('sku') ?? take('name');
    const qty = take('qty'); const price = take('unit_price'); const total = take('value');

    if (itemCol) {
      reqFields.push({ key: 'item_id', type: 'relation', to: 'item', label: s.headers[itemCol.col], required: true });
      cols.item_id = itemCol.col;
      note('RELATION', 'request.item_id', itemCol.conf, `'${s.headers[itemCol.col]}' links each request to an item${itemS ? ` in '${itemS.s.name}'` : ''}.`);
      if (!itemS) { mapping.derivedItems = true; note('ENTITY', 'item', 0.6, `There is no separate stock sheet, so items are created from the distinct values of '${s.headers[itemCol.col]}' with zero stock. Receive stock on the Stock page.`); }
    } else {
      reqFields.push({ key: 'item_id', type: 'relation', to: 'item', label: 'Item', required: true });
      mapping.derivedItems = true;
      note('RELATION', 'request.item_id', 0.3, "No item column was found; imported rows point to 'Unspecified item'. Check this.");
    }
    reqFields.push({ key: 'qty', type: 'number', label: qty ? s.headers[qty.col] : 'Qty', min: 1, required: true, ...(qty ? {} : { default: 1 }) });
    if (qty) cols.qty = qty.col;
    const text = (k: string, c: { col: number; conf: number } | undefined, label: string, extra: Partial<Field> = {}) => {
      if (!c) return;
      reqFields.push({ key: k, type: 'text', label: s.headers[c.col] ?? label, origin: { kind: 'sheet', sheet: s.name, column: s.letters[c.col] }, ...extra });
      cols[k] = c.col; keys.add(k);
    };
    text('ref', ref, 'Ref');
    if (serial) {
      const p = profile(s, serial.col);
      text('serial_no', serial, 'Serial', { owner_module: 'pcb-repair', unique: p.unique && p.count >= 10 });
      pcb = true;
      note('REPAIR', 'modules.pcb-repair', serial.conf, `'${s.headers[serial.col]}' identifies boards, so PCB Repair is enabled.`);
      if (p.unique && p.count >= 10) note('LAW_UNIQUE', 'request.serial_no', 0.85, `All ${p.count} serial numbers are different.`);
    }
    if (fault) { text('fault', fault, 'Fault', { owner_module: 'pcb-repair' }); pcb = true; note('REPAIR', 'request.fault', fault.conf, `'${s.headers[fault.col]}' describes the fault.`); }
    text('location', location, 'Location');
    if (requester) { text('requester', requester, 'Requested by'); note('REQUESTER', 'request.requester', requester.conf, `'${s.headers[requester.col]}' records who asked; kept as history.`); }
    if (approver) text('approved_by', approver, 'Approved by');
    if (assignee) text('assigned_to', assignee, 'Assigned to');
    if (consumed) {
      reqFields.push({ key: 'consumed_qty', type: 'number', label: s.headers[consumed.col] });
      cols.consumed_qty = consumed.col; keys.add('consumed_qty'); consumption = true;
      note('CONSUMPTION', 'modules.consumption', consumed.conf, `'${s.headers[consumed.col]}' tracks what was used in the field.`);
    }
    if (returned) {
      reqFields.push({ key: 'returned_on', type: profile(s, returned.col).dateRatio >= 0.5 ? 'date' : 'text', label: s.headers[returned.col] });
      cols.returned_on = returned.col; keys.add('returned_on');
    }
    if (price) {
      reqFields.push({ key: 'unit_price', type: 'money', label: s.headers[price.col], roles: MASK });
      cols.unit_price = price.col; keys.add('unit_price');
      note('MONEY', 'request.unit_price', 0.85, `'${s.headers[price.col]}' is a price; hidden from Members.`);
    }
    const deferred: number[] = [];
    if (total && profile(s, total.col).formulaRatio >= 0.5) deferred.push(total.col); else if (total) used.delete(total.col);
    genericFields(s, used, keys, 'request', cols, reqFields, deferred);
    formulaFields(s, deferred, cols, keys, 'request', reqFields, total && deferred.includes(total.col) ? 'total' : undefined);
    if (!reqFields.some(f => f.type === 'formula') && price) {
      reqFields.push({ key: 'total', type: 'formula', label: 'Total', expr: 'qty * unit_price', roles: { read: MG } });
      note('FORMULA', 'request.total', 0.7, 'Added Total = qty * unit_price because the register has a quantity and a price.');
    }

    // Workflow from the Status column and other signals
    const states = new Set<string>(['draft', 'submitted']);
    const statusMap: Record<string, string> = {};
    if (status) {
      const values = profile(s, status.col).values;
      const read: string[] = [];
      for (const v of values) {
        const key = snakeCase(v);
        const canon = STATUS_SYN[key] ?? key;
        if (!canon) continue;
        statusMap[key] = canon;
        states.add(canon);
        read.push(canon === key ? v : `${v} as ${canon}`);
      }
      note('STATUS', 'workflows.request', 0.85, `'${s.headers[status.col]}' has ${values.length} stages: ${read.join(', ')}.`);
    }
    if (approver) { states.add('approved'); note('APPROVAL', 'modules.approval', approver.conf, `'${s.headers[approver.col]}' shows requests are approved, so Approval is enabled.`); }
    if (assignee) { states.add('assigned'); note('ASSIGNMENT', 'modules.material-assignment', assignee.conf, `'${s.headers[assignee.col]}' shows material is issued to people, so Material Assignment is enabled.`); }
    if (returned) { states.add('returned'); note('RETURN', 'modules.returns', returned.conf, `'${s.headers[returned.col]}' shows items come back, so Return Management is enabled.`); }
    if (pcb && !states.has('in_repair') && !states.has('assigned')) states.add('in_repair');
    if (states.has('in_repair')) pcb = true;
    if ((states.has('assigned') || states.has('in_repair')) && !states.has('approved')) {
      states.add('approved');
      note('APPROVAL', 'workflows.request', 0.6, 'Added an Approve step before issuing, so stock is reserved before it leaves the store.');
    }
    ma = states.has('assigned');
    const chain = ORDER.filter(x => states.has(x));
    const unknown = [...states].filter(x => !ORDER.includes(x) && x !== 'rejected');
    const at = chain.indexOf('closed') >= 0 ? chain.indexOf('closed') : chain.indexOf('returned') >= 0 ? chain.indexOf('returned') : chain.length;
    chain.splice(at, 0, ...unknown);
    const transitions: Transition[] = [];
    let committed = false;
    for (let k = 1; k < chain.length; k++) {
      const from = chain[k - 1];
      const to = chain[k];
      const actions: string[] = [];
      if (to === 'approved') actions.push("stock.reserve(item_id, qty, ttl='72h')");
      if ((to === 'assigned' || to === 'in_repair') && !committed && chain.includes('approved')) { actions.push('stock.commit(item_id, qty)'); committed = true; }
      if (to === 'in_repair') actions.push('repair.open()');
      if (to === 'closed' && from === 'in_repair') actions.push('repair.close()');
      if (to === 'returned') actions.push('stock.return(item_id, qty)');
      const roles = to === 'submitted' || to === 'returned' || (to === 'closed' && !pcb) ? M : MG;
      transitions.push({
        id: `t${transitions.length + 1}`, from, to, label: LABEL[to] ?? to.replace(/_/g, ' '), roles,
        ...(to === 'submitted' ? { guard: 'stock.available(item_id) >= qty' } : {}),
        ...(actions.length ? { actions } : {}),
        ...(to === 'returned' ? { owner_module: 'returns' } : {}),
      });
    }
    const terminal = [chain[chain.length - 1]];
    if (states.has('rejected')) {
      const before = chain[Math.max(1, chain.indexOf('approved') - 1)] ?? 'submitted';
      transitions.push({ id: `t${transitions.length + 1}`, from: before, to: 'rejected', label: 'Reject', roles: MG });
      terminal.push('rejected');
    }
    wf = { initial: 'draft', states: [...chain, ...(states.has('rejected') ? ['rejected'] : [])], transitions, terminal };
    note('TRANSITIONS', 'workflows.request', 0.75, `Workflow: ${chain.join(' > ')}${states.has('rejected') ? ' (or rejected)' : ''}. Stock is reserved on approval and committed on ${chain.includes('assigned') ? 'assignment' : chain.includes('in_repair') ? 'repair' : 'issue'}.`);
    mapping.request = { sheet: reqSheet.i, cols, statusCol: status?.col, statusMap };

    entities.request = { owner_module: 'request', label: s.name, fields: reqFields };
    modules.push('request');
    if (states.has('approved')) modules.push('approval');
    if (ma) {
      modules.push('material-assignment', 'assignment-frontend');
      entities.assignment = { owner_module: 'material-assignment', label: 'Assignment', fields: [
        { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
        { key: 'item_id', type: 'relation', to: 'item', label: 'Item', required: true },
        { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
        { key: 'assigned_to', type: 'text', label: 'Assigned to' },
      ] };
    }
    if (pcb) {
      modules.push('pcb-repair');
      entities.repair = { owner_module: 'pcb-repair', label: 'Repair log', fields: [
        { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
        { key: 'serial_no', type: 'text', label: 'Serial' },
        { key: 'fault', type: 'text', label: 'Fault' },
        { key: 'diagnosis', type: 'text', label: 'Diagnosis' },
      ] };
    }
    if (states.has('returned') && (ma || pcb)) modules.push('returns');
    if (consumption && ma) {
      modules.push('consumption');
      entities.consumption = { owner_module: 'consumption', label: 'Consumption', fields: [
        { key: 'assignment_id', type: 'relation', to: 'assignment', label: 'Assignment', required: true },
        { key: 'qty', type: 'number', label: 'Qty used', min: 1, required: true },
        { key: 'note', type: 'text', label: 'Note' },
      ] };
    }
  }
  modules.push('analytics', 'excel');

  // 4. Pages, layout, laws
  const has = (e: string, k: string) => entities[e]?.fields.some(f => f.key === k);
  const pages: Page[] = [];
  const nav: { label: string; path: string }[] = [];
  const add = (p: Page, label: string) => { pages.push(p); nav.push({ label, path: p.path }); };
  if (entities.request) {
    const cols = ['item_id', 'qty', 'serial_no', 'fault', 'location', 'assigned_to', 'total'].filter(k => has('request', k)).slice(0, 5);
    add({ path: '/requests', title: entities.request.label ?? 'Requests', view: 'kanban', entity: 'request', groupBy: 'state', columns: cols }, entities.request.label ?? 'Requests');
  }
  if (ma) add({ path: '/assignments', title: 'Assignment queue', view: 'queue', entity: 'assignment', columns: ['item_id', 'qty', 'assigned_to'] }, 'Queue');
  if (pcb) add({ path: '/repairs', title: 'Repair logs', view: 'table', entity: 'repair', columns: ['serial_no', 'fault', 'diagnosis', 'state'], roles: MG }, 'Repairs');
  const itemCols2 = ['sku', 'name', 'category', 'on_hand', 'available', 'unit_price', 'stock_value'].filter(k => has('item', k));
  add({ path: '/items', title: itemS?.s.name ?? 'Stock', view: 'table', entity: 'item', columns: itemCols2 }, itemS?.s.name ?? 'Stock');
  const widgets: Widget[] = [];
  if (entities.request) widgets.push({ id: 'w1', type: 'bar', title: 'Requests by stage', entity: 'request', measure: 'count', by: 'state' });
  if (has('item', 'category')) widgets.push({ id: 'w2', type: 'bar', title: 'Items by category', entity: 'item', measure: 'count', by: 'category' });
  if (has('item', 'stock_value')) widgets.push({ id: 'w3', type: 'stat', title: 'Stock value', entity: 'item', measure: 'sum', field: 'stock_value' });
  if (!widgets.length) widgets.push({ id: 'w1', type: 'stat', title: 'Items', entity: 'item', measure: 'count' });
  add({ path: '/analytics', title: 'Analytics', view: 'dashboard', widgets }, 'Analytics');
  note('PAGES', 'pages', 0.7, `Pages: ${pages.map(p => p.title).join(', ')}.`);

  const layout = ma ? 'queue-first' : entities.request ? 'kanban-first' : 'sidebar';
  const primary = { 'queue-first': '#0369A1', 'kanban-first': '#BE185D', sidebar: '#4338CA' }[layout];
  note('LAYOUT', 'theme.layout', 0.6, layout === 'sidebar'
    ? 'Inventory-heavy, so a dense sidebar layout with analytics.'
    : layout === 'queue-first' ? 'Material is issued to people, so a work-queue layout.' : 'Requests move through stages, so a kanban board layout.');

  const laws: Law[] = [{ id: 'l0', template: 'site_isolation', locked: true }];
  let n = 1;
  if (stockSeen) laws.push({ id: `l${n++}`, template: 'non_negative', entity: 'item', field: 'on_hand' });
  laws.push({ id: `l${n++}`, template: 'reserved_le_on_hand', entity: 'item' });
  if (priceSeen) laws.push({ id: `l${n++}`, template: 'hidden_from', entity: 'item', field: 'unit_price', role: 'Member' });
  if (has('request', 'unit_price')) laws.push({ id: `l${n++}`, template: 'hidden_from', entity: 'request', field: 'unit_price', role: 'Member' });
  if (ma) laws.push({ id: `l${n++}`, template: 'requires_state', entity: 'assignment', ref: 'request_id', state: 'approved' });
  if (wf?.states.includes('closed')) laws.push({ id: `l${n++}`, template: 'reachable', workflow: 'request', state: 'closed' });

  const bp: Blueprint = {
    configVersion: 3, siteId: '', slug: '', name: opts.name,
    theme: { tokens: { primary, surface: '#F8FAFC', radius: layout === 'sidebar' ? '4px' : '10px', font: 'Inter' }, layout, density: layout === 'sidebar' ? 'compact' : 'comfortable', home: pages[0].path },
    modules, entities, workflows: wf ? { request: wf } : {}, laws, pages, roles: ['Public', 'Member', 'Manager', 'Admin'], nav,
  };
  bp.edges = autoWire(bp);
  inferences.sort((a, b) => b.confidence - a.confidence);
  return { blueprint: bp, inferences, mapping };
}
