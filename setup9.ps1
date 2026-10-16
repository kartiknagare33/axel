# Axel - batch 9 (Sheet Inferencer, demo registers, people management). Run from the axel folder.
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
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel && pnpm test:api && pnpm test:gate && pnpm test:replay"
'@ @'
    "test:infer": "pnpm --filter @axel/api test:infer",
    "registers": "pnpm --filter @axel/api registers",
    "test": "pnpm test:isolation && pnpm test:workflow && pnpm test:excel && pnpm test:api && pnpm test:gate && pnpm test:replay && pnpm test:infer"
'@

Patch 'apps/api/package.json' @'
    "test:replay": "tsx --env-file=../../.env --test test/replay.test.ts",
'@ @'
    "test:replay": "tsx --env-file=../../.env --test test/replay.test.ts",
    "test:infer": "tsx --env-file=../../.env --test test/infer.test.ts",
    "registers": "tsx scripts/gen-registers.ts",
'@

Patch 'packages/compiler/src/index.ts' @'
export * from './laws';
'@ @'
export * from './laws';
export * from './infer';
'@

Patch 'apps/api/src/server.ts' @'
import { replayRouter } from './replay';
'@ @'
import { replayRouter } from './replay';
import { inferRouter } from './infer';
import { membersRouter } from './members';
'@

Patch 'apps/api/src/server.ts' @'
app.use('/api/sites', sitesRouter);
'@ @'
app.use('/api/sites', sitesRouter);
app.use('/api/sites', inferRouter);
'@

Patch 'apps/api/src/server.ts' @'
versionsRouter, gateRouter, replayRouter);
'@ @'
versionsRouter, gateRouter, replayRouter, membersRouter);
'@

# ============================== PATCHES: web ==============================
Patch 'apps/web/src/pages/Hub.tsx' @'
import { ChaosCard } from './Chaos';
'@ @'
import { ChaosCard } from './Chaos';
import { SheetUnit } from './SheetUnit';
'@

Patch 'apps/web/src/pages/Hub.tsx' @'
          {user?.hubAdmin && <NewUnit />}
'@ @'
          {user?.hubAdmin && <div className="flex flex-col items-end gap-2"><NewUnit /><SheetUnit /></div>}
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
import { ReleasesPanel } from './ReleasesPanel';
'@ @'
import { ReleasesPanel } from './ReleasesPanel';
import { PeoplePanel } from './PeoplePanel';
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
'impact' | 'theme' | 'json' | 'versions'>('problems');
'@ @'
'impact' | 'theme' | 'json' | 'versions' | 'people'>('problems');
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
['json', 'JSON'], ['versions', 'Versions']] as const)
'@ @'
['json', 'JSON'], ['versions', 'Versions'], ['people', 'People']] as const)
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
            {tab === 'theme' && <ThemePanel bp={bp} update={update} />}
'@ @'
            {tab === 'people' && <PeoplePanel siteId={siteId} H={H} />}
            {tab === 'theme' && <ThemePanel bp={bp} update={update} />}
'@

# ============================== PATCHES: docs ==============================
Patch 'README.md' @'
- Publish runs Gate, then Replay and Impact; anything that differs must be reviewed first. The replay summary and the chosen plans are stored with the deployment.
'@ @'
- Publish runs Gate, then Replay and Impact; anything that differs must be reviewed first. The replay summary and the chosen plans are stored with the deployment.

## Sheet Inferencer

Nobody has to design a site from a blank canvas. On the hub, **+ From a spreadsheet** reads a unit's existing `.xlsx` and proposes the whole site: which sheet is the stock list and which is the request register, field types, choice lists (from data validation or repeated values), calculated fields (`=D2*I2` becomes `qty * unit_price`), workflow stages from the Status column ("Sanctioned" is read as approved, "Repairing" as in repair), modules, Laws, pages and layout. Every inference has a confidence and a plain-English explanation; low-confidence ones are highlighted. Creating the site also imports the rows (opening stock through the ledger). It is rule-based and deterministic: no AI service, no internet.

Try it with the generated registers: `pnpm registers` writes four workbooks to `demo/registers/`, including `Workshop_Tools.xlsx` for a unit that does not exist yet.

## People

Each unit's builder has a **People** tab: Admins add members by email (creating the account with a starting password if needed), change roles (Public, Member, Manager, Admin) and remove members. Nobody can change their own role; the database enforces this too.
'@

Patch 'README.md' @'
| `test:replay` (4) |
'@ @'
| `test:infer` (4) | A repair register infers approval, repair and returns with a mapped formula; a stock sheet infers a sidebar inventory site; the upload endpoint is hub-admin only; members can be added, re-roled and removed but never change their own role |
| `test:replay` (4) |
'@

Patch 'README.md' @'
Run with Axel started: `pnpm test` (31 tests).
'@ @'
Run with Axel started: `pnpm test` (35 tests).
'@

Patch 'README.md' @'
404-not-403 for other sites. 31 automated tests.
'@ @'
404-not-403 for other sites. 35 automated tests.
'@

Patch 'README.md' @'
Built: the Release Gate with Laws, the Replay Report and the Impact Report (above). Next: a Sheet Inferencer that derives a site from a unit's existing spreadsheets.
'@ @'
Built: Release Gate with Laws, Replay Report, Impact Report and Sheet Inferencer (above). Possible next steps: Record mode (derive a workflow by acting it out), offline field consumption, serial-number scanning.
'@

Patch 'docs/API.md' @'
| GET | `/api/sites/:siteId/render-schema` |
'@ @'
| POST | `/api/sites/infer?name=&slug=&create=` | hub admin; body is the raw .xlsx. `create=false` returns the proposed Blueprint, inferences (rule, confidence, explanation) and diagnostics; `create=true` creates the site and imports the rows |
| GET | `/api/sites/:siteId/members` | Admin: members and roles |
| POST | `/api/sites/:siteId/members` | Admin: `{ email, role, name?, password? }` (creates the account if new) |
| PATCH | `/api/sites/:siteId/members/:userId` | Admin: `{ role }`; changing your own role is refused |
| DELETE | `/api/sites/:siteId/members/:userId` | Admin: remove a member (not yourself) |
| GET | `/api/sites/:siteId/render-schema` |
'@

Patch 'docs/DEMO_SCRIPT.md' @'
## Brief step 4: Excel with role rules (1.5 min)
'@ @'
## A fourth unit from a spreadsheet (1.5 min)

- Hub, **+ From a spreadsheet**, choose `demo/registers/Workshop_Tools.xlsx` (or a judge's own register), **Read spreadsheet**.
- Walk through a few inferences: the Tool column became the item list, Status values became the workflow, "Returned On" enabled Return Management, unit prices are hidden from Members by default. Point at the confidence bars.
- **Create unit**. The builder opens on the new unit with its rows already imported. **People** tab: add `member@cs.dev` as Member; in the second window that user now sees the new unit on the hub.

*Say:* "We did not design this site. We read the spreadsheet the unit already keeps, and every guess is explained."

## Brief step 4: Excel with role rules (1.5 min)
'@

# ============================== COMPILER: infer ==============================
W 'packages/compiler/src/infer.ts' @'
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
'@

# ============================== API: infer + members ==============================
W 'apps/api/src/infer.ts' @'
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
'@

W 'apps/api/src/members.ts' @'
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { pool, withSite, UUID } from './db';
import { AxelError, ah, notFound } from './errors';

// Mounted at /api/sites/:siteId (Admin only). User management for the Hub layer.
export const membersRouter = Router({ mergeParams: true });
const ROLE = z.enum(['Public', 'Member', 'Manager', 'Admin']);

membersRouter.get('/members', ah(async (req, res) => {
  const rows = await withSite(req.site!.ctx, async c => (await c.query(
    `SELECT m.user_id, m.role, u.email, u.name FROM memberships m JOIN users u ON u.id = m.user_id
      WHERE m.site_id = $1 ORDER BY u.name`, [req.site!.siteId])).rows);
  res.json(rows);
}));

membersRouter.post('/members', ah(async (req, res) => {
  const b = z.object({
    email: z.string().email(), role: ROLE,
    name: z.string().min(2).max(80).optional(), password: z.string().min(8).max(100).optional(),
  }).parse(req.body);
  let user = (await pool.query('SELECT id, name, email FROM users WHERE email = $1', [b.email])).rows[0];
  if (!user) {
    if (!b.name || !b.password)
      throw new AxelError('VALIDATION_FAILED', 422, 'This email has no account yet. Give a name and a starting password (8+ characters) to create one.', { needsAccount: true });
    user = (await pool.query('INSERT INTO users (email, password_hash, name) VALUES ($1,$2,$3) RETURNING id, name, email',
      [b.email, await bcrypt.hash(b.password, 12), b.name])).rows[0];
  }
  await withSite(req.site!.ctx, async c => {
    const r = await c.query('INSERT INTO memberships (site_id, user_id, role) VALUES ($1,$2,$3) ON CONFLICT (site_id, user_id) DO NOTHING RETURNING id',
      [req.site!.siteId, user.id, b.role]);
    if (!r.rowCount) throw new AxelError('DUPLICATE', 409, `${user.email} is already a member of ${req.site!.name}.`);
  });
  res.status(201).json({ user_id: user.id, email: user.email, name: user.name, role: b.role });
}));

membersRouter.patch('/members/:userId', ah(async (req, res) => {
  if (!UUID.test(req.params.userId)) throw notFound();
  const { role } = z.object({ role: ROLE }).parse(req.body);
  if (req.params.userId === req.site!.ctx.userId) throw new AxelError('FORBIDDEN', 403, 'You cannot change your own role. Ask another Admin.');
  const row = await withSite(req.site!.ctx, async c => (await c.query(
    'UPDATE memberships SET role = $2 WHERE site_id = $3 AND user_id = $1 RETURNING user_id, role', [req.params.userId, role, req.site!.siteId])).rows[0]);
  if (!row) throw notFound();
  res.json(row);
}));

membersRouter.delete('/members/:userId', ah(async (req, res) => {
  if (!UUID.test(req.params.userId)) throw notFound();
  if (req.params.userId === req.site!.ctx.userId) throw new AxelError('FORBIDDEN', 403, 'You cannot remove yourself. Ask another Admin.');
  const n = await withSite(req.site!.ctx, async c => (await c.query(
    'DELETE FROM memberships WHERE site_id = $2 AND user_id = $1', [req.params.userId, req.site!.siteId])).rowCount);
  if (!n) throw notFound();
  res.json({ ok: true });
}));
'@

# ============================== demo registers ==============================
W 'apps/api/scripts/gen-registers.ts' @'
import ExcelJS from 'exceljs';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const out = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'demo', 'registers');
mkdirSync(out, { recursive: true });
let seed = 42;
const rnd = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647; };
const pick = <T,>(a: T[]): T => a[Math.floor(rnd() * a.length)];
const int = (a: number, b: number) => a + Math.floor(rnd() * (b - a + 1));
const MONEY = '"Rs "#,##0.00';
const day = (n: number) => new Date(Date.UTC(2026, 7, 1 + n));
const people = ['Anil', 'Bhavna', 'Chirag', 'Divya', 'Esha', 'Farhan', 'Gauri', 'Harsh'];
const bold = (ws: ExcelJS.Worksheet) => { ws.getRow(1).font = { bold: true }; ws.views = [{ state: 'frozen', ySplit: 1 }]; };

async function stores() {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Stock');
  ws.columns = [
    { header: 'SKU', width: 10 }, { header: 'Item Name', width: 26 }, { header: 'Category', width: 14 }, { header: 'Bin', width: 8 },
    { header: 'Stock Qty', width: 10 }, { header: 'Unit Price', width: 12 }, { header: 'Stock Value', width: 14 },
  ];
  const names = ['Copper wire 2.5mm', 'MCB 16A', 'Hex bolt M8', 'Bearing 6204', 'Cable ties', 'Insulation tape', 'Relay 12V', 'Gear oil 1L', 'Safety gloves', 'Fuse 10A'];
  for (let i = 0; i < 40; i++) {
    const qty = int(0, 150);
    const price = int(5, 900);
    const row = ws.addRow([`ST-${100 + i}`, `${names[i % names.length]}${i >= names.length ? ` (${Math.floor(i / names.length) + 1})` : ''}`, pick(['Electrical', 'Mechanical', 'Consumable', 'Safety']), `${pick(['A', 'B', 'C'])}${int(1, 9)}`, qty, price]);
    row.getCell(7).value = { formula: `E${row.number}*F${row.number}`, result: qty * price } as any;
    row.getCell(3).dataValidation = { type: 'list', allowBlank: true, formulae: ['"Electrical,Mechanical,Consumable,Safety"'] };
  }
  ws.getColumn(6).numFmt = MONEY; ws.getColumn(7).numFmt = MONEY; bold(ws);
  const f = path.join(out, 'CentralStores_Stock.xlsx'); await wb.xlsx.writeFile(f); console.log(f);
}

async function service() {
  const wb = new ExcelJS.Workbook();
  const parts = wb.addWorksheet('Parts');
  parts.columns = [{ header: 'SKU', width: 10 }, { header: 'Part Name', width: 24 }, { header: 'Stock', width: 8 }, { header: 'Unit Price', width: 12 }];
  const partNames = ['Power board PB-4', 'Control board CB-2', 'Capacitor 470uF', 'MOSFET IRF540', 'Display ribbon', 'Relay module'];
  partNames.forEach((n, i) => parts.addRow([`SC-${101 + i}`, n, int(10, 60), [2400, 3100, 12, 38, 150, 420][i]]));
  parts.getColumn(4).numFmt = MONEY; bold(parts);
  const ws = wb.addWorksheet('Repairs');
  ws.columns = [
    { header: 'Ticket No', width: 10 }, { header: 'Requested By', width: 14 }, { header: 'Part Name', width: 22 }, { header: 'Qty', width: 6 },
    { header: 'Serial No', width: 12 }, { header: 'Fault', width: 18 }, { header: 'Status', width: 12 }, { header: 'Sanctioned By', width: 14 },
    { header: 'Unit Price', width: 12 }, { header: 'Total', width: 12 }, { header: 'Returned On', width: 12 },
  ];
  const flow = ['Pending', 'Sanctioned', 'Repairing', 'Closed', 'Returned', 'Rejected'];
  for (let i = 0; i < 50; i++) {
    const p = int(0, partNames.length - 1);
    const price = [2400, 3100, 12, 38, 150, 420][p];
    const qty = int(1, 4);
    const status = pick(flow);
    const row = ws.addRow([`T-${5000 + i}`, pick(people), partNames[p], qty, `PCB-${30000 + i}`, pick(['No power', 'Display dead', 'Relay chatter', 'Overheating']),
      status, status === 'Pending' ? null : pick(['Priya', 'Rahul']), price, null, status === 'Returned' ? day(i % 25) : null]);
    row.getCell(10).value = { formula: `D${row.number}*I${row.number}`, result: qty * price } as any;
  }
  ws.getColumn(9).numFmt = MONEY; ws.getColumn(10).numFmt = MONEY; bold(ws);
  const f = path.join(out, 'ServiceCentre_Repairs.xlsx'); await wb.xlsx.writeFile(f); console.log(f);
}

async function distribution() {
  const wb = new ExcelJS.Workbook();
  const mats = wb.addWorksheet('Materials');
  mats.columns = [{ header: 'Code', width: 10 }, { header: 'Material', width: 22 }, { header: 'Balance', width: 10 }, { header: 'Rate', width: 10 }];
  const names = ['Smart meter', 'Service cable 10m', 'Meter box', 'Seal kit', 'Junction box'];
  names.forEach((n, i) => mats.addRow([`DS-${201 + i}`, n, int(20, 90), [1850, 640, 410, 25, 120][i]]));
  mats.getColumn(4).numFmt = MONEY; bold(mats);
  const ws = wb.addWorksheet('Issues');
  ws.columns = [
    { header: 'Issue No', width: 10 }, { header: 'Material', width: 22 }, { header: 'Qty', width: 6 }, { header: 'Issued To', width: 12 },
    { header: 'Location', width: 14 }, { header: 'Status', width: 12 }, { header: 'Consumed Qty', width: 12 },
  ];
  for (let i = 0; i < 40; i++) {
    const status = pick(['Requested', 'Approved', 'Issued', 'Completed', 'Rejected']);
    const qty = int(1, 6);
    ws.addRow([`I-${700 + i}`, pick(names), qty, ['Issued', 'Completed'].includes(status) ? pick(people) : null,
      pick(['Ward 4', 'Sector 12', 'Plant gate', 'Substation B']), status, status === 'Completed' ? int(1, qty) : null]);
  }
  bold(ws);
  const f = path.join(out, 'Distribution_Issues.xlsx'); await wb.xlsx.writeFile(f); console.log(f);
}

async function workshop() {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Tool Requests');
  ws.columns = [
    { header: 'Ref', width: 8 }, { header: 'Tool', width: 22 }, { header: 'Qty', width: 6 }, { header: 'Requested By', width: 14 },
    { header: 'Status', width: 10 }, { header: 'Returned On', width: 12 }, { header: 'Remarks', width: 24 },
  ];
  const tools = ['Torque wrench', 'Multimeter', 'Crimping tool', 'Cordless drill', 'Insulation tester', 'Ladder 8ft'];
  for (let i = 0; i < 30; i++) {
    const status = pick(['Pending', 'Approved', 'Issued', 'Returned']);
    ws.addRow([`W-${100 + i}`, pick(tools), int(1, 2), pick(people), status, status === 'Returned' ? day(i % 20) : null, pick(['', 'urgent', 'night shift', ''])]);
  }
  bold(ws);
  const f = path.join(out, 'Workshop_Tools.xlsx'); await wb.xlsx.writeFile(f); console.log(f);
}

await stores();
await service();
await distribution();
await workshop();
'@

W 'apps/api/test/infer.test.ts' @'
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import ExcelJS from 'exceljs';
import { infer, compile, type Sheet } from '@axel/compiler';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const DS = '33333333-3333-4333-8333-333333333333';
const L = 'ABCDEFGHIJKLMNOP'.split('');

function sheet(name: string, headers: string[], rows: unknown[][], formulas?: (string | null)[][]): Sheet {
  return { name, headers, letters: L.slice(0, headers.length), rows, formulas: formulas ?? rows.map(r => r.map(() => null)), lists: headers.map(() => null), money: headers.map(h => /price/i.test(h)) };
}

test('a repair register infers approval, repair, returns and a mapped formula', () => {
  const parts = sheet('Parts', ['SKU', 'Part Name', 'Stock', 'Unit Price'], Array.from({ length: 6 }, (_, i) => [`P-${i}`, `Board ${i}`, 10 + i, 100 * (i + 1)]));
  const statuses = ['Pending', 'Sanctioned', 'Repairing', 'Closed', 'Returned', 'Rejected'];
  const rows = Array.from({ length: 24 }, (_, i) => [`T-${i}`, `Board ${i % 6}`, 1 + (i % 3), `PCB-${i}`, 'No power', statuses[i % 6], i % 6 ? 'Priya' : null, 100, null]);
  const formulas = rows.map((_, i) => [null, null, null, null, null, null, null, null, `C${i + 2}*H${i + 2}`]);
  const repairs = sheet('Repairs', ['Ticket No', 'Part Name', 'Qty', 'Serial No', 'Fault', 'Status', 'Sanctioned By', 'Unit Price', 'Total'], rows, formulas);
  const r = infer([parts, repairs], { name: 'Repairs Test' });
  const bp = r.blueprint;
  for (const m of ['approval', 'pcb-repair', 'returns']) assert.ok(bp.modules.includes(m), `module ${m}`);
  for (const s of ['approved', 'in_repair', 'closed', 'returned', 'rejected']) assert.ok(bp.workflows.request.states.includes(s), `state ${s}`);
  assert.equal(bp.entities.request.fields.find(f => f.key === 'total')?.expr, 'qty * unit_price');
  assert.equal(bp.theme.layout, 'kanban-first');
  assert.deepEqual(compile(bp).diagnostics.filter(d => d.severity === 'error'), []);
  assert.ok(r.inferences.every(i => i.explanation.length > 10 && i.confidence > 0));
});

test('a stock sheet alone infers a sidebar inventory site', () => {
  const rows = Array.from({ length: 20 }, (_, i) => [`S-${i}`, `Thing ${i}`, ['A', 'B', 'C'][i % 3], i * 2, 10 + i, null]);
  const formulas = rows.map((_, i) => [null, null, null, null, null, `D${i + 2}*E${i + 2}`]);
  const r = infer([sheet('Stock', ['SKU', 'Item Name', 'Category', 'Stock Qty', 'Unit Price', 'Stock Value'], rows, formulas)], { name: 'Stores Test' });
  assert.equal(r.blueprint.theme.layout, 'sidebar');
  assert.ok(!r.blueprint.entities.request);
  assert.equal(r.blueprint.entities.item.fields.find(f => f.key === 'stock_value')?.expr, 'on_hand * unit_price');
  assert.ok(r.inferences.some(i => i.rule === 'LAW_NON_NEGATIVE'));
  assert.deepEqual(compile(r.blueprint).diagnostics.filter(d => d.severity === 'error'), []);
});

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  return (await r.json()).token as string;
}
let admin = '', manager = '', member = '';
before(async () => { [admin, manager, member] = await Promise.all(['admin@axel.dev', 'manager@sc.dev', 'member@cs.dev'].map(login)); });

test('the upload endpoint reads a workbook and is hub-admin only', async () => {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Tool Requests');
  ws.addRow(['Ref', 'Tool', 'Qty', 'Requested By', 'Status']);
  for (let i = 0; i < 12; i++) ws.addRow([`W-${i}`, ['Drill', 'Meter'][i % 2], 1, 'Anil', ['Pending', 'Approved', 'Issued', 'Returned'][i % 4]]);
  const buf = Buffer.from(await wb.xlsx.writeBuffer());
  const post = (token: string) => fetch(`${API}/sites/infer?name=Tools%20Test`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/octet-stream' }, body: buf });
  const ok = await post(admin);
  const body = await ok.json();
  assert.equal(ok.status, 200, JSON.stringify(body));
  assert.ok(body.blueprint.modules.includes('material-assignment'));
  assert.ok(body.inferences.length > 5);
  assert.deepEqual(body.diagnostics.filter((d: any) => d.severity === 'error'), []);
  assert.equal((await post(manager)).status, 403);
});

test('members can be added, re-roled and removed, but nobody changes their own role', async () => {
  const H = (t: string) => ({ authorization: `Bearer ${t}`, 'x-site-id': DS, 'content-type': 'application/json' });
  const me = await (await fetch(`${API}/me`, { headers: { authorization: `Bearer ${admin}` } })).json();
  const add = await fetch(`${API}/sites/${DS}/members`, { method: 'POST', headers: H(admin), body: JSON.stringify({ email: 'member@cs.dev', role: 'Member' }) });
  assert.ok([201, 409].includes(add.status));
  const list = await (await fetch(`${API}/sites/${DS}/members`, { headers: H(admin) })).json();
  const target = list.find((m: any) => m.email === 'member@cs.dev');
  try {
    const sites = await (await fetch(`${API}/sites`, { headers: { authorization: `Bearer ${member}` } })).json();
    assert.ok(sites.some((s: any) => s.id === DS), 'new member sees the unit');
    const self = await fetch(`${API}/sites/${DS}/members/${me.user.id}`, { method: 'PATCH', headers: H(admin), body: JSON.stringify({ role: 'Member' }) });
    assert.equal(self.status, 403);
    const up = await fetch(`${API}/sites/${DS}/members/${target.user_id}`, { method: 'PATCH', headers: H(admin), body: JSON.stringify({ role: 'Manager' }) });
    assert.equal(up.status, 200);
  } finally {
    const del = await fetch(`${API}/sites/${DS}/members/${target.user_id}`, { method: 'DELETE', headers: H(admin) });
    assert.equal(del.status, 200);
  }
  const after = await (await fetch(`${API}/sites`, { headers: { authorization: `Bearer ${member}` } })).json();
  assert.ok(!after.some((s: any) => s.id === DS));
});
'@

# ============================== WEB: sheet upload + people ==============================
W 'apps/web/src/pages/SheetUnit.tsx' @'
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { REGISTRY } from '@axel/compiler';
import { http, errOf } from '../api';

const slugify = (s: string) => s.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);

export function SheetUnit() {
  const [open, setOpen] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [name, setName] = useState('');
  const [preview, setPreview] = useState<any>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const qc = useQueryClient();
  const nav = useNavigate();

  async function read() {
    if (!file) return;
    setBusy(true); setErr(''); setPreview(null);
    try {
      const r = await http.post(`/sites/infer?name=${encodeURIComponent(name)}`, await file.arrayBuffer(), { headers: { 'Content-Type': 'application/octet-stream' } });
      setPreview(r.data);
    } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  async function create() {
    if (!file) return;
    setBusy(true); setErr('');
    try {
      const r = await http.post(`/sites/infer?name=${encodeURIComponent(name)}&slug=${slugify(name)}&create=true`, await file.arrayBuffer(), { headers: { 'Content-Type': 'application/octet-stream' } });
      await qc.invalidateQueries({ queryKey: ['sites'] });
      nav(`/builder/${r.data.id}`);
    } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }

  if (!open) return <button onClick={() => setOpen(true)} className="rounded-lg border border-dashed border-slate-300 px-4 py-2 text-sm text-slate-600 hover:bg-white">+ From a spreadsheet</button>;
  const errors = (preview?.diagnostics ?? []).filter((d: any) => d.severity === 'error');
  return (
    <div className="w-[640px] max-w-full space-y-3 rounded-xl border bg-white p-5 text-left">
      <div className="font-medium">New unit from a spreadsheet</div>
      <div className="text-sm text-slate-500">Upload the register this unit already keeps. Axel proposes the site and explains every guess. Try <code>demo/registers/Workshop_Tools.xlsx</code>.</div>
      <input type="file" accept=".xlsx" onChange={e => {
        const f = e.target.files?.[0] ?? null;
        setFile(f); setPreview(null);
        if (f && !name) setName(f.name.replace(/\.xlsx$/i, '').replace(/[_-]+/g, ' ').trim());
      }} />
      <input value={name} onChange={e => setName(e.target.value)} placeholder="Unit name" className="w-full rounded-lg border px-3 py-2 text-sm" />
      <div className="flex gap-2">
        <button disabled={!file || name.trim().length < 2 || busy} onClick={read} className="rounded-lg border px-4 py-2 text-sm disabled:opacity-50">{busy && !preview ? 'Reading...' : 'Read spreadsheet'}</button>
        <button onClick={() => { setOpen(false); setPreview(null); setFile(null); }} className="rounded-lg border px-4 py-2 text-sm">Cancel</button>
      </div>
      {err && <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
      {preview && (
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2 text-xs">
            {preview.sheets.map((s: any) => <span key={s.name} className="rounded bg-slate-100 px-2 py-1">{s.name}: {s.rows} rows</span>)}
            <span className="rounded bg-slate-900 px-2 py-1 text-white">{preview.blueprint.theme.layout} layout</span>
          </div>
          <div className="flex flex-wrap gap-1">
            {preview.blueprint.modules.filter((m: string) => !['auth', 'users', 'dashboard'].includes(m)).map((m: string) => (
              <span key={m} className="rounded bg-emerald-50 px-1.5 py-0.5 text-[11px] text-emerald-800">{REGISTRY[m]?.name ?? m}</span>
            ))}
          </div>
          {preview.blueprint.workflows?.request && (
            <div className="text-xs text-slate-600">Workflow: {preview.blueprint.workflows.request.states.join(' > ')}</div>
          )}
          <div className="max-h-72 space-y-1 overflow-y-auto rounded-lg border p-2">
            {preview.inferences.map((i: any, n: number) => (
              <div key={n} className={`flex items-start gap-2 rounded px-1 py-1 text-xs ${i.confidence < 0.6 ? 'bg-amber-50' : ''}`}>
                <div className="mt-1 h-1.5 w-14 shrink-0 rounded bg-slate-200"><div className="h-1.5 rounded bg-slate-900" style={{ width: `${Math.round(i.confidence * 100)}%` }} /></div>
                <span className="w-8 shrink-0 text-slate-400">{Math.round(i.confidence * 100)}%</span>
                <span className="w-28 shrink-0 font-mono text-[10px] text-slate-500">{i.rule}</span>
                <span>{i.explanation}{i.confidence < 0.6 ? ' (check this)' : ''}</span>
              </div>
            ))}
          </div>
          {!!errors.length && <div className="rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700">{errors.map((d: any) => d.message).join(' ')}</div>}
          <button disabled={busy || !!errors.length} onClick={create} className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">
            {busy ? 'Creating...' : `Create unit and import ${preview.counts.items + preview.counts.requests} rows`}
          </button>
        </div>
      )}
    </div>
  );
}
'@

W 'apps/web/src/builder/PeoplePanel.tsx' @'
import { useEffect, useState } from 'react';
import { http, errOf } from '../api';
import { useSession } from '../store/session';

const ROLES = ['Public', 'Member', 'Manager', 'Admin'];

export function PeoplePanel({ siteId, H }: { siteId: string; H: any }) {
  const me = useSession(s => s.user);
  const [rows, setRows] = useState<any[] | null>(null);
  const [email, setEmail] = useState('');
  const [role, setRole] = useState('Member');
  const [name, setName] = useState('');
  const [password, setPassword] = useState('');
  const [needsAccount, setNeedsAccount] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  const load = () => http.get(`/sites/${siteId}/members`, H).then(r => setRows(r.data), e => setMsg({ ok: false, text: errOf(e).message }));
  useEffect(() => { load(); }, [siteId]);

  async function add() {
    setMsg(null);
    try {
      await http.post(`/sites/${siteId}/members`, { email, role, ...(needsAccount ? { name, password } : {}) }, H);
      setMsg({ ok: true, text: `${email} added as ${role}.` });
      setEmail(''); setName(''); setPassword(''); setNeedsAccount(false);
      load();
    } catch (e: any) {
      if (e?.response?.data?.needsAccount) setNeedsAccount(true);
      setMsg({ ok: false, text: errOf(e).message });
    }
  }
  async function change(userId: string, r: string) {
    try { await http.patch(`/sites/${siteId}/members/${userId}`, { role: r }, H); load(); }
    catch (e) { setMsg({ ok: false, text: errOf(e).message }); }
  }
  async function remove(userId: string) {
    if (!window.confirm('Remove this member from the unit?')) return;
    try { await http.delete(`/sites/${siteId}/members/${userId}`, H); load(); }
    catch (e) { setMsg({ ok: false, text: errOf(e).message }); }
  }

  return (
    <div className="space-y-4 text-sm">
      <div className="text-slate-600">Who can use this unit, and with which role. Nobody can change their own role.</div>
      {!rows && <div className="text-slate-400">Loading...</div>}
      <div className="space-y-1">
        {rows?.map(r => (
          <div key={r.user_id} className="flex items-center gap-2 rounded border p-2">
            <div className="min-w-0 flex-1">
              <div className="truncate font-medium">{r.name}{r.user_id === me?.id ? ' (you)' : ''}</div>
              <div className="truncate text-xs text-slate-500">{r.email}</div>
            </div>
            <select value={r.role} disabled={r.user_id === me?.id} onChange={e => change(r.user_id, e.target.value)} className="rounded border px-1 py-1 text-xs">
              {ROLES.map(x => <option key={x}>{x}</option>)}
            </select>
            {r.user_id !== me?.id && <button onClick={() => remove(r.user_id)} className="text-xs text-red-600">remove</button>}
          </div>
        ))}
      </div>
      <div className="space-y-2 rounded-lg border p-3">
        <div className="font-medium">Add a member</div>
        <div className="grid grid-cols-3 gap-2">
          <input value={email} onChange={e => setEmail(e.target.value)} placeholder="email" className="col-span-2 rounded border px-2 py-1" />
          <select value={role} onChange={e => setRole(e.target.value)} className="rounded border px-2 py-1">{ROLES.map(x => <option key={x}>{x}</option>)}</select>
        </div>
        {needsAccount && (
          <div className="grid grid-cols-2 gap-2">
            <input value={name} onChange={e => setName(e.target.value)} placeholder="Full name" className="rounded border px-2 py-1" />
            <input value={password} onChange={e => setPassword(e.target.value)} placeholder="Starting password (8+)" type="password" className="rounded border px-2 py-1" />
          </div>
        )}
        <button disabled={!email} onClick={add} className="rounded-md bg-slate-900 px-3 py-1 text-xs text-white disabled:opacity-40">{needsAccount ? 'Create account and add' : 'Add'}</button>
      </div>
      {msg && <div className={`rounded px-3 py-2 text-xs ${msg.ok ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-700'}`}>{msg.text}</div>}
    </div>
  );
}
'@

Write-Host ''
Write-Host 'Batch 9 done. Next: .\start.ps1, pnpm registers, pnpm test'