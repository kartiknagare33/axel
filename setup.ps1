# Axel - batch 1 file generator. Run from the axel folder.
$ErrorActionPreference = 'Stop'
function W([string]$Path, [string]$Content) {
  $full = Join-Path $PSScriptRoot $Path
  New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
  $text = $Content.Replace("`r`n", "`n").TrimStart("`n") + "`n"
  [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding $false))
  Write-Host "created $Path"
}

# ============================== ROOT ==============================
W 'package.json' @'
{
  "name": "axel",
  "private": true,
  "packageManager": "pnpm@9.12.0",
  "scripts": {
    "db:up": "docker compose up -d db",
    "migrate": "pnpm --filter @axel/api migrate",
    "seed": "pnpm --filter @axel/api seed",
    "dev:api": "pnpm --filter @axel/api dev",
    "dev:web": "pnpm --filter @axel/web dev"
  }
}
'@

W 'pnpm-workspace.yaml' @'
packages:
  - "apps/*"
  - "packages/*"
'@

W 'docker-compose.yml' @'
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports: ["5432:5432"]
    volumes:
      - ./db/init:/docker-entrypoint-initdb.d
      - pgdata:/var/lib/postgresql/data
volumes:
  pgdata: {}
'@

W 'tsconfig.json' @'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true
  }
}
'@

W '.gitignore' @'
node_modules
.env
dist
'@

W '.env' @'
DATABASE_URL_APP=postgres://axel_app:app_pw@localhost:5432/axel
DATABASE_URL_OWNER=postgres://axel_owner:owner_pw@localhost:5432/axel
JWT_SECRET=change-me-to-a-long-random-string-32chars-min
JWT_TTL=12h
PORT=4000
'@

W 'db/init/00-roles.sql' @'
-- Runs once as superuser when the container is first created.
CREATE ROLE axel_owner LOGIN PASSWORD 'owner_pw';
CREATE ROLE axel_app   LOGIN PASSWORD 'app_pw' NOBYPASSRLS;
CREATE DATABASE axel OWNER axel_owner;
\connect axel
CREATE EXTENSION IF NOT EXISTS citext;
GRANT CONNECT ON DATABASE axel TO axel_app;
GRANT USAGE ON SCHEMA public TO axel_app;
ALTER DEFAULT PRIVILEGES FOR ROLE axel_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO axel_app;
ALTER DEFAULT PRIVILEGES FOR ROLE axel_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO axel_app;
'@

# ============================== COMPILER ==============================
W 'packages/compiler/package.json' @'
{
  "name": "@axel/compiler",
  "private": true,
  "type": "module",
  "main": "src/index.ts",
  "types": "src/index.ts",
  "dependencies": { "zod": "^3.23.8" }
}
'@

W 'packages/compiler/src/types.ts' @'
export type Role = 'Public' | 'Member' | 'Manager' | 'Admin';
export const ROLES: Role[] = ['Public', 'Member', 'Manager', 'Admin'];

export type FieldType =
  | 'text' | 'number' | 'money' | 'date' | 'boolean'
  | 'select' | 'relation' | 'formula' | 'file';

export interface Origin { kind: 'sheet' | 'recording' | 'preset' | 'manual'; [k: string]: unknown }

export interface Field {
  key: string; type: FieldType; label?: string;
  required?: boolean; default?: unknown; unique?: boolean; indexed?: boolean;
  min?: number; max?: number; pattern?: string;
  options?: string[];
  to?: string;
  expr?: string;
  system?: boolean;
  roles?: { read?: Role[]; write?: Role[] };
  origin?: Origin; owner_module?: string; reason?: string;
}

export interface Entity { label?: string; owner_module: string; fields: Field[] }

export interface Transition {
  id: string; from: string; to: string; roles: Role[];
  label?: string; guard?: string; actions?: string[];
}
export interface Workflow { initial: string; states: string[]; transitions: Transition[]; terminal: string[] }

export interface Law { id: string; template: string; locked?: boolean; [k: string]: unknown }

export interface Widget {
  id: string; type: 'bar' | 'line' | 'pie' | 'stat'; title?: string;
  entity: string; measure: 'count' | 'sum' | 'avg'; field?: string; by?: string;
}

export interface Page {
  path: string; title: string;
  view: 'table' | 'kanban' | 'queue' | 'dashboard' | 'form' | 'detail';
  entity?: string; groupBy?: string; columns?: string[];
  filter?: Record<string, string>; widgets?: Widget[]; roles?: Role[];
}

export type Layout = 'sidebar' | 'topbar' | 'kanban-first' | 'queue-first';
export interface Theme {
  tokens: { primary: string; surface: string; radius: string; font: string };
  layout: Layout; density: 'compact' | 'comfortable'; home: string;
}

export interface Edge { from: { module: string; port: string }; to: { module: string; port: string } }

export interface Blueprint {
  configVersion: 3;
  siteId: string; slug: string; name: string;
  theme: Theme;
  modules: string[];
  entities: Record<string, Entity>;
  workflows: Record<string, Workflow>;
  laws: Law[];
  pages: Page[];
  roles: Role[];
  nav: { label: string; path: string }[];
  edges?: Edge[];
}

export interface Diagnostic {
  code: string; severity: 'error' | 'warning';
  nodeId?: string; entity?: string; fieldKey?: string;
  message: string; fix?: { label: string; patch: unknown };
}
'@

W 'packages/compiler/src/expr.ts' @'
export class ExprError extends Error {}

export type Node =
  | { k: 'num'; v: number } | { k: 'str'; v: string } | { k: 'bool'; v: boolean }
  | { k: 'ref'; name: string }
  | { k: 'call'; fn: string; args: Node[] }
  | { k: 'un'; op: '-' | 'not'; e: Node }
  | { k: 'bin'; op: string; l: Node; r: Node };

const PREC: Record<string, number> = {
  or: 1, and: 2, '==': 3, '!=': 3, '<': 4, '<=': 4, '>': 4, '>=': 4,
  '+': 5, '-': 5, '*': 6, '/': 6,
};

export function tokenize(src: string): string[] {
  const re = /\s*(\d+(?:\.\d+)?|'[^']*'|"[^"]*"|[A-Za-z_][\w.]*|==|!=|<=|>=|[-+*/<>(),=])/y;
  const out: string[] = [];
  while (re.lastIndex < src.length) {
    const start = re.lastIndex;
    if (!src.slice(start).trim()) break;
    const m = re.exec(src);
    if (!m) throw new ExprError(`Unexpected character '${src.slice(start).trim()[0]}'`);
    out.push(m[1]);
  }
  return out;
}

export function parse(src: string): Node {
  const t = tokenize(src);
  let i = 0;
  const peek = () => t[i];
  const next = () => t[i++];
  const expect = (s: string) => { if (t[i] !== s) throw new ExprError(`Expected '${s}'`); i++; };
  const isIdent = (s?: string) => !!s && /^[A-Za-z_]/.test(s);

  function primary(): Node {
    const tok = next();
    if (tok === undefined) throw new ExprError('Expression ends too early');
    if (/^\d/.test(tok)) return { k: 'num', v: Number(tok) };
    if (/^['"]/.test(tok)) return { k: 'str', v: tok.slice(1, -1) };
    if (tok === '(') { const e = expr(0); expect(')'); return e; }
    if (tok === '-') return { k: 'un', op: '-', e: expr(7) };
    if (tok === 'not') return { k: 'un', op: 'not', e: expr(3) };
    if (tok === 'true' || tok === 'false') return { k: 'bool', v: tok === 'true' };
    if (isIdent(tok)) {
      if (peek() === '(') {
        next();
        const args: Node[] = [];
        if (peek() !== ')') {
          do {
            if (isIdent(peek()) && t[i + 1] === '=') i += 2;
            args.push(expr(0));
          } while (peek() === ',' && next());
        }
        expect(')');
        return { k: 'call', fn: tok, args };
      }
      return { k: 'ref', name: tok };
    }
    throw new ExprError(`Unexpected '${tok}'`);
  }

  function expr(min: number): Node {
    let l = primary();
    for (;;) {
      const op = peek();
      const p = op === undefined ? undefined : PREC[op];
      if (p === undefined || p < min) return l;
      next();
      l = { k: 'bin', op: op!, l, r: expr(p + 1) };
    }
  }

  const ast = expr(0);
  if (i !== t.length) throw new ExprError(`Unexpected '${t[i]}'`);
  return ast;
}

export interface Scope { get(name: string): unknown; call?(fn: string, args: unknown[]): unknown }

export function evaluate(n: Node, s: Scope): unknown {
  switch (n.k) {
    case 'num': case 'str': case 'bool': return n.v;
    case 'ref': return s.get(n.name);
    case 'call':
      if (!s.call) throw new ExprError(`${n.fn}() is not available here`);
      return s.call(n.fn, n.args.map(a => evaluate(a, s)));
    case 'un': {
      const v = evaluate(n.e, s);
      return n.op === 'not' ? !v : v == null ? null : -Number(v);
    }
    case 'bin': {
      if (n.op === 'and') return !!evaluate(n.l, s) && !!evaluate(n.r, s);
      if (n.op === 'or') return !!evaluate(n.l, s) || !!evaluate(n.r, s);
      const l = evaluate(n.l, s), r = evaluate(n.r, s);
      const eq = l === r || (l != null && r != null && String(l) === String(r));
      if (n.op === '==') return eq;
      if (n.op === '!=') return !eq;
      if (l == null || r == null || l === '' || r === '') return null;
      const a = Number(l), b = Number(r);
      switch (n.op) {
        case '+': return a + b;
        case '-': return a - b;
        case '*': return a * b;
        case '/': return b === 0 ? null : a / b;
        case '<': return a < b;
        case '<=': return a <= b;
        case '>': return a > b;
        case '>=': return a >= b;
      }
    }
  }
  throw new ExprError('Unknown expression');
}

export function refs(n: Node, out = { fields: new Set<string>(), calls: new Set<string>() }) {
  if (n.k === 'ref') out.fields.add(n.name);
  else if (n.k === 'call') { out.calls.add(n.fn); n.args.forEach(a => refs(a, out)); }
  else if (n.k === 'un') refs(n.e, out);
  else if (n.k === 'bin') { refs(n.l, out); refs(n.r, out); }
  return out;
}
'@

W 'packages/compiler/src/registry.ts' @'
export type PortType =
  | 'Identity' | 'Membership' | 'Page[]' | 'ItemStream' | 'StockLedger'
  | 'RequestStream' | 'ApprovedStream' | 'AssignmentStream' | 'RepairLog' | 'File' | 'Any';

export interface Port { name: string; types: PortType[]; required?: boolean }
export interface ModuleDef {
  id: string; name: string;
  kind: 'hub-core' | 'layout' | 'entity' | 'entity+workflow' | 'workflow' | 'page' | 'page+action';
  in: Port[]; out: Port[];
  requires: string[][];
  infer?: string[];
}

export const REGISTRY: Record<string, ModuleDef> = {
  auth: { id: 'auth', name: 'Authentication and RBAC', kind: 'hub-core', in: [], out: [{ name: 'identity', types: ['Identity'] }], requires: [] },
  users: { id: 'users', name: 'User Management', kind: 'hub-core', in: [{ name: 'identity', types: ['Identity'], required: true }], out: [{ name: 'membership', types: ['Membership'] }], requires: [['auth']] },
  dashboard: { id: 'dashboard', name: 'Dashboard Shell/Navigation/Forms', kind: 'layout', in: [{ name: 'pages', types: ['Page[]'] }], out: [], requires: [['auth']] },
  inventory: { id: 'inventory', name: 'Inventory', kind: 'entity', in: [], out: [{ name: 'items', types: ['ItemStream'] }, { name: 'ledger', types: ['StockLedger'] }], requires: [['dashboard']], infer: ['stock', 'qty', 'quantity', 'sku', 'item'] },
  request: { id: 'request', name: 'Request', kind: 'entity+workflow', in: [{ name: 'items', types: ['ItemStream'], required: true }], out: [{ name: 'requests', types: ['RequestStream'] }], requires: [['inventory']], infer: ['requested by', 'raised by', 'employee'] },
  approval: { id: 'approval', name: 'Approval', kind: 'workflow', in: [{ name: 'requests', types: ['RequestStream'], required: true }], out: [{ name: 'approved', types: ['ApprovedStream'] }], requires: [['request']], infer: ['approved by', 'approver', 'sanctioned by', 'authorised by'] },
  'material-assignment': { id: 'material-assignment', name: 'Material Assignment', kind: 'workflow', in: [{ name: 'approved', types: ['ApprovedStream'], required: true }, { name: 'ledger', types: ['StockLedger'], required: true }], out: [{ name: 'assignments', types: ['AssignmentStream'] }], requires: [['approval'], ['inventory']], infer: ['assigned to', 'issued to', 'technician'] },
  'assignment-frontend': { id: 'assignment-frontend', name: 'Assignment Frontend', kind: 'page', in: [{ name: 'assignments', types: ['AssignmentStream'], required: true }], out: [], requires: [['material-assignment']] },
  consumption: { id: 'consumption', name: 'Consumption Tracking', kind: 'workflow', in: [{ name: 'assignments', types: ['AssignmentStream'], required: true }], out: [{ name: 'ledger', types: ['StockLedger'] }], requires: [['material-assignment']], infer: ['consumed', 'used', 'utilised'] },
  returns: { id: 'returns', name: 'Return Management', kind: 'workflow', in: [{ name: 'source', types: ['AssignmentStream', 'RepairLog'], required: true }], out: [{ name: 'ledger', types: ['StockLedger'] }], requires: [['material-assignment', 'pcb-repair']], infer: ['returned on', 'return date', 'returned qty'] },
  'pcb-repair': { id: 'pcb-repair', name: 'PCB Repair', kind: 'entity+workflow', in: [{ name: 'requests', types: ['RequestStream'], required: true }], out: [{ name: 'repairs', types: ['RepairLog'] }], requires: [['request']], infer: ['serial', 'pcb', 'fault', 'board'] },
  analytics: { id: 'analytics', name: 'Analytics Dashboard', kind: 'page', in: [{ name: 'source', types: ['Any'] }], out: [], requires: [['dashboard']] },
  excel: { id: 'excel', name: 'Reports with Excel Integration', kind: 'page+action', in: [{ name: 'source', types: ['Any'] }], out: [{ name: 'file', types: ['File'] }], requires: [['dashboard']] },
};

export const MODULE_IDS = Object.keys(REGISTRY);
'@

W 'packages/compiler/src/compile.ts' @'
import { z, type ZodTypeAny } from 'zod';
import type { Blueprint, Diagnostic, Entity, Field, Role } from './types';
import { ROLES } from './types';
import { parse, evaluate, refs, ExprError, type Node } from './expr';
import { REGISTRY } from './registry';

export const RANK: Record<Role, number> = { Public: 0, Member: 1, Manager: 2, Admin: 3 };
export const atLeast = (r: Role, min: Role) => RANK[r] >= RANK[min];
export const canRead = (f: Field, r: Role) => !f.roles?.read || f.roles.read.includes(r);
export const canWrite = (f: Field, r: Role) =>
  f.type !== 'formula' && !f.system && (f.roles?.write ? f.roles.write.includes(r) : atLeast(r, 'Member'));

const META = new Set(['id', 'state', 'row_version', 'created_at', 'updated_at']);
const GUARD_CALLS = new Set(['stock.available', 'stock.on_hand', 'now']);
const ACTION_CALLS = new Set(['stock.reserve', 'stock.commit', 'stock.release', 'stock.consume', 'repair.open', 'repair.close', 'notify']);

function lev(a: string, b: string) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++)
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return d[a.length][b.length];
}
const suggest = (name: string, keys: string[]) =>
  keys.map(k => [k, lev(name, k)] as const).filter(([, d]) => d <= 3).sort((x, y) => x[1] - y[1])[0]?.[0];

export function diagnose(bp: Blueprint): Diagnostic[] {
  const out: Diagnostic[] = [];
  const mods = new Set(bp.modules);

  for (const m of bp.modules) {
    const def = REGISTRY[m];
    if (!def) { out.push({ code: 'MODULE_UNKNOWN', severity: 'error', nodeId: m, message: `'${m}' is not one of the 13 approved modules.` }); continue; }
    for (const anyOf of def.requires) {
      if (!anyOf.some(r => mods.has(r))) {
        const names = anyOf.map(r => REGISTRY[r].name).join(' or ');
        out.push({ code: 'MODULE_DEP', severity: 'error', nodeId: m, message: `${def.name} requires ${names}.`, fix: { label: `Enable ${REGISTRY[anyOf[0]].name}`, patch: { op: 'addModule', id: anyOf[0] } } });
      }
    }
  }

  for (const [ek, ent] of Object.entries(bp.entities)) {
    const keys = ent.fields.map(f => f.key);
    for (const f of ent.fields) {
      if (f.type === 'formula') {
        if (f.unique) out.push({ code: 'UNIQUE_ON_FORMULA', severity: 'error', entity: ek, fieldKey: f.key, message: 'Calculated fields cannot be unique.', fix: { label: 'Clear unique', patch: { op: 'setField', entity: ek, key: f.key, unique: false } } });
        try {
          for (const r of refs(parse(f.expr ?? '')).fields) {
            if (!keys.includes(r)) {
              const s = suggest(r, keys);
              out.push({ code: 'FORMULA_REF', severity: 'error', entity: ek, fieldKey: f.key, message: `${f.key} uses '${r}' but there is no such field${s ? `; did you mean ${s}?` : '.'}`, fix: s ? { label: `Use ${s}`, patch: { op: 'renameRef', entity: ek, key: f.key, from: r, to: s } } : undefined });
            }
          }
        } catch (e) {
          out.push({ code: 'FORMULA_PARSE', severity: 'error', entity: ek, fieldKey: f.key, message: `${f.key}: ${(e as Error).message}` });
        }
      }
      if (f.type === 'select' && !f.options?.length) out.push({ code: 'SELECT_EMPTY', severity: 'error', entity: ek, fieldKey: f.key, message: `${f.key} is a choice field with no options.` });
      if (f.type === 'relation' && (!f.to || !bp.entities[f.to])) out.push({ code: 'RELATION_TARGET', severity: 'error', entity: ek, fieldKey: f.key, message: `${f.key} points to '${f.to}', which is not in this site.` });
      for (const r of [...(f.roles?.read ?? []), ...(f.roles?.write ?? [])])
        if (!bp.roles.includes(r)) out.push({ code: 'ROLE_UNKNOWN', severity: 'error', entity: ek, fieldKey: f.key, message: `'${r}' is not a role in this site.` });
      if (f.required && f.roles?.write && f.roles.read && !f.roles.write.some(r => f.roles!.read!.includes(r)))
        out.push({ code: 'MASK_CONFLICT', severity: 'warning', entity: ek, fieldKey: f.key, message: `${f.key} is required, but nobody who can write it can also read it.` });
    }
  }

  for (const [ek, wf] of Object.entries(bp.workflows)) {
    const ent = bp.entities[ek];
    if (!ent) { out.push({ code: 'WORKFLOW_ENTITY', severity: 'error', entity: ek, message: `Workflow '${ek}' has no matching entity.` }); continue; }
    const states = new Set(wf.states);
    const keys = ent.fields.map(f => f.key);
    if (!states.has(wf.initial)) out.push({ code: 'STATE_UNKNOWN', severity: 'error', entity: ek, message: `Initial state '${wf.initial}' is not in the state list.` });
    for (const t of wf.transitions) {
      for (const s of [t.from, t.to]) if (!states.has(s)) out.push({ code: 'STATE_UNKNOWN', severity: 'error', entity: ek, nodeId: t.id, message: `Transition ${t.id} uses unknown state '${s}'.` });
      for (const r of t.roles) if (!bp.roles.includes(r)) out.push({ code: 'ROLE_UNKNOWN', severity: 'error', entity: ek, nodeId: t.id, message: `'${r}' is not a role in this site.`, fix: { label: `Add role ${r}`, patch: { op: 'addRole', role: r } } });
      if (t.guard) {
        try {
          const r = refs(parse(t.guard));
          for (const f of r.fields) if (!keys.includes(f) && f !== 'user.role') out.push({ code: 'GUARD_REF', severity: 'error', entity: ek, nodeId: t.id, message: `Guard on ${t.id} uses '${f}', which is not a field.` });
          for (const c of r.calls) if (!GUARD_CALLS.has(c)) out.push({ code: 'GUARD_REF', severity: 'error', entity: ek, nodeId: t.id, message: `Guard on ${t.id} calls ${c}(), which is not allowed.` });
        } catch (e) { out.push({ code: 'GUARD_PARSE', severity: 'error', entity: ek, nodeId: t.id, message: `Guard on ${t.id}: ${(e as Error).message}` }); }
      }
      for (const a of t.actions ?? []) {
        try {
          const n = parse(a);
          if (n.k !== 'call' || !ACTION_CALLS.has(n.fn)) out.push({ code: 'ACTION_UNKNOWN', severity: 'error', entity: ek, nodeId: t.id, message: `'${a}' is not an allowed action.` });
        } catch (e) { out.push({ code: 'ACTION_PARSE', severity: 'error', entity: ek, nodeId: t.id, message: `${a}: ${(e as Error).message}` }); }
      }
    }
    for (const s of wf.states) {
      if (s !== wf.initial && !wf.transitions.some(t => t.to === s))
        out.push({ code: 'STATE_UNREACHABLE', severity: 'error', entity: ek, message: `Nothing leads to '${s}'.` });
      if (!wf.terminal.includes(s) && !wf.transitions.some(t => t.from === s))
        out.push({ code: 'STATE_DEAD_END', severity: 'error', entity: ek, message: `'${s}' has no way out.`, fix: { label: 'Mark terminal', patch: { op: 'markTerminal', entity: ek, state: s } } });
    }
  }

  for (const p of bp.pages) {
    if (p.entity && !bp.entities[p.entity]) out.push({ code: 'PAGE_ENTITY', severity: 'error', message: `Page ${p.path} shows '${p.entity}', which is not in this site.` });
    for (const w of p.widgets ?? []) if (!bp.entities[w.entity]) out.push({ code: 'PAGE_ENTITY', severity: 'error', message: `Widget ${w.id} reads '${w.entity}', which is not in this site.` });
  }
  if (!bp.laws.some(l => l.template === 'site_isolation'))
    out.push({ code: 'LAW_ISOLATION_MISSING', severity: 'error', message: 'The site isolation law is locked and cannot be removed.' });
  return out;
}

function fieldSchema(f: Field): ZodTypeAny {
  switch (f.type) {
    case 'number':
    case 'money': {
      let s = z.coerce.number({ invalid_type_error: `${f.key} must be a number` });
      if (f.min != null) s = s.min(f.min, `${f.key} must be at least ${f.min}`);
      else if (f.type === 'money') s = s.min(0, `${f.key} cannot be negative`);
      if (f.max != null) s = s.max(f.max, `${f.key} must be at most ${f.max}`);
      return s;
    }
    case 'boolean':
      return z.union([z.boolean(), z.enum(['true', 'false']).transform(v => v === 'true')]);
    case 'date':
      return z.string().refine(v => !Number.isNaN(Date.parse(v)), `${f.key} must be a date`);
    case 'select':
      return f.options?.length ? z.enum(f.options as [string, ...string[]]) : z.string();
    case 'relation':
      return z.string().uuid(`${f.key} must reference a record`);
    default: {
      let s = z.string().trim();
      if (f.max != null) s = s.max(f.max);
      if (f.pattern) s = s.regex(new RegExp(f.pattern), `${f.key} has the wrong format`);
      return f.required ? s.min(1, `${f.key} is required`) : s;
    }
  }
}

export interface RenderSchema {
  siteId: string; slug: string; name: string; role: Role;
  theme: Blueprint['theme']; modules: string[];
  nav: Blueprint['nav']; pages: Blueprint['pages'];
  entities: Record<string, {
    label: string;
    fields: (Pick<Field, 'key' | 'type' | 'label' | 'options' | 'to' | 'required' | 'min' | 'max' | 'expr'> & { readonly: boolean })[];
    workflow?: { initial: string; states: string[]; terminal: string[]; transitions: { id: string; from: string; to: string; label: string; allowed: boolean }[] };
  }>;
}

export interface Compiled {
  ok: boolean;
  diagnostics: Diagnostic[];
  blueprint: Blueprint;
  validator(entity: string, role: Role, mode: 'create' | 'update'): z.ZodObject<any>;
  computeFormulas(entity: string, rec: Record<string, unknown>): Record<string, unknown>;
  mask(entity: string, role: Role, rec: Record<string, unknown>): Record<string, unknown>;
  renderSchema(role: Role): RenderSchema;
}

export function compile(bp: Blueprint): Compiled {
  const diagnostics = diagnose(bp);
  const formulas = new Map<string, { key: string; ast: Node }[]>();
  for (const [ek, ent] of Object.entries(bp.entities)) {
    const list: { key: string; ast: Node }[] = [];
    for (const f of ent.fields) if (f.type === 'formula' && f.expr) { try { list.push({ key: f.key, ast: parse(f.expr) }); } catch (e) { if (!(e instanceof ExprError)) throw e; } }
    formulas.set(ek, list);
  }
  const ent = (k: string): Entity => {
    const e = bp.entities[k];
    if (!e) throw new Error(`Unknown entity ${k}`);
    return e;
  };
  const vcache = new Map<string, z.ZodObject<any>>();
  const rcache = new Map<Role, RenderSchema>();
  const pageVisible = (roles: Role[] | undefined, r: Role) => (roles ? roles.includes(r) : atLeast(r, 'Member'));

  return {
    ok: !diagnostics.some(d => d.severity === 'error'),
    diagnostics,
    blueprint: bp,

    validator(entity, role, mode) {
      const key = `${entity}|${role}|${mode}`;
      const hit = vcache.get(key);
      if (hit) return hit;
      const shape: Record<string, ZodTypeAny> = {};
      for (const f of ent(entity).fields) {
        if (!canWrite(f, role)) continue;
        let s = fieldSchema(f);
        if (mode === 'create' && f.default !== undefined) s = s.default(f.default);
        else if (mode === 'update' || !f.required) s = s.optional().nullable();
        shape[f.key] = s;
      }
      const v = z.object(shape).strict();
      vcache.set(key, v);
      return v;
    },

    computeFormulas(entity, rec) {
      for (const { key, ast } of formulas.get(entity) ?? []) {
        try {
          const v = evaluate(ast, { get: n => rec[n] });
          rec[key] = typeof v === 'number' && Number.isFinite(v) ? Math.round(v * 100) / 100 : v ?? null;
        } catch { rec[key] = null; }
      }
      return rec;
    },

    mask(entity, role, rec) {
      const byKey = new Map(ent(entity).fields.map(f => [f.key, f]));
      const out: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(rec)) {
        const f = byKey.get(k);
        if (f ? canRead(f, role) : META.has(k)) out[k] = v;
      }
      return out;
    },

    renderSchema(role) {
      const hit = rcache.get(role);
      if (hit) return hit;
      const pages = bp.pages
        .filter(p => pageVisible(p.roles, role))
        .map(p => {
          if (!p.entity || !p.columns) return p;
          const readable = new Set(ent(p.entity).fields.filter(f => canRead(f, role)).map(f => f.key));
          return { ...p, columns: p.columns.filter(c => readable.has(c) || META.has(c)) };
        });
      const paths = new Set(pages.map(p => p.path));
      const entities: RenderSchema['entities'] = {};
      for (const [ek, e] of Object.entries(bp.entities)) {
        const wf = bp.workflows[ek];
        entities[ek] = {
          label: e.label ?? ek,
          fields: e.fields.filter(f => canRead(f, role)).map(f => ({
            key: f.key, type: f.type, label: f.label ?? f.key, options: f.options, to: f.to,
            required: f.required, min: f.min, max: f.max, expr: f.expr, readonly: !canWrite(f, role),
          })),
          workflow: wf && {
            initial: wf.initial, states: wf.states, terminal: wf.terminal,
            transitions: wf.transitions.map(t => ({ id: t.id, from: t.from, to: t.to, label: t.label ?? t.to, allowed: t.roles.includes(role) })),
          },
        };
      }
      const rs: RenderSchema = {
        siteId: bp.siteId, slug: bp.slug, name: bp.name, role,
        theme: bp.theme, modules: bp.modules,
        nav: bp.nav.filter(n => paths.has(n.path)), pages, entities,
      };
      rcache.set(role, rs);
      return rs;
    },
  };
}

export function canonicalJson(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(',')}]`;
  if (v && typeof v === 'object')
    return `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${canonicalJson((v as any)[k])}`).join(',')}}`;
  return JSON.stringify(v);
}

export { ROLES };
'@

W 'packages/compiler/src/index.ts' @'
export * from './types';
export * from './expr';
export * from './registry';
export * from './compile';
'@

# ============================== API ==============================
W 'apps/api/package.json' @'
{
  "name": "@axel/api",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "tsx watch --env-file=../../.env src/server.ts",
    "migrate": "tsx --env-file=../../.env src/migrate.ts",
    "seed": "tsx --env-file=../../.env seed/seed.ts"
  },
  "dependencies": {
    "@axel/compiler": "workspace:*",
    "bcryptjs": "^2.4.3",
    "express": "^4.21.0",
    "jsonwebtoken": "^9.0.2",
    "pg": "^8.13.0",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "@types/bcryptjs": "^2.4.6",
    "@types/express": "^4.17.21",
    "@types/jsonwebtoken": "^9.0.7",
    "@types/pg": "^8.11.10",
    "tsx": "^4.19.0",
    "typescript": "^5.6.0"
  }
}
'@

W 'apps/api/migrations/001_core.sql' @'
-- Helpers read the transaction-local context. NULLIF guards the '' a pooled
-- connection reports after a set_config(...,true) transaction ends.
CREATE FUNCTION app_site() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT NULLIF(current_setting('app.site_id', true), '')::uuid $$;
CREATE FUNCTION app_user() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT NULLIF(current_setting('app.user_id', true), '')::uuid $$;

-- ---------- hub tables (not site-scoped) ----------
CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email citext UNIQUE NOT NULL,
  password_hash text NOT NULL,
  name text NOT NULL,
  is_hub_admin boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE sites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text UNIQUE NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  name text NOT NULL,
  published_version_id uuid,
  created_by uuid REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now());

-- ---------- site-scoped platform tables ----------
CREATE TABLE memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  user_id uuid NOT NULL REFERENCES users(id),
  role text NOT NULL CHECK (role IN ('Public','Member','Manager','Admin')),
  UNIQUE (site_id, user_id));

CREATE TABLE site_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  config jsonb NOT NULL,
  content_hash text NOT NULL,
  parent_id uuid REFERENCES site_versions(id),
  status text NOT NULL CHECK (status IN ('draft','gated','published','archived')),
  author_id uuid REFERENCES users(id),
  reason text,
  updated_rev integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, content_hash),
  UNIQUE (site_id, id));
ALTER TABLE sites ADD CONSTRAINT fk_sites_published
  FOREIGN KEY (published_version_id) REFERENCES site_versions(id);

CREATE TABLE site_deployments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  version_id uuid NOT NULL,
  audience jsonb NOT NULL DEFAULT '{"roles":"all"}',
  proof jsonb NOT NULL,
  plans jsonb,
  deployed_by uuid REFERENCES users(id),
  deployed_at timestamptz NOT NULL DEFAULT now(),
  rollback_of uuid REFERENCES site_deployments(id),
  FOREIGN KEY (site_id, version_id) REFERENCES site_versions (site_id, id));

CREATE TABLE recordings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  version_id uuid REFERENCES site_versions(id),
  steps jsonb NOT NULL, created_by uuid, created_at timestamptz DEFAULT now());

CREATE TABLE law_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  version_id uuid NOT NULL REFERENCES site_versions(id),
  seed bigint NOT NULL, steps integer NOT NULL, passed boolean NOT NULL,
  failures jsonb NOT NULL DEFAULT '[]', duration_ms integer, ran_at timestamptz DEFAULT now());

CREATE TABLE audit_events (
  id bigserial PRIMARY KEY,
  site_id uuid NOT NULL REFERENCES sites(id),
  entity text NOT NULL, record_id uuid NOT NULL,
  kind text NOT NULL,
  transition_id text, from_state text, to_state text,
  actor_id uuid, actor_role text,
  before jsonb, after jsonb,
  version_id uuid REFERENCES site_versions(id),
  idempotency_key text,
  at timestamptz NOT NULL DEFAULT now());
CREATE INDEX ix_audit_record ON audit_events (site_id, entity, record_id, at);

-- ---------- business tables ----------
CREATE TABLE items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  name text NOT NULL,
  on_hand numeric NOT NULL DEFAULT 0 CHECK (on_hand >= 0),
  reserved numeric NOT NULL DEFAULT 0 CHECK (reserved >= 0 AND reserved <= on_hand),
  data jsonb NOT NULL DEFAULT '{}',
  row_version integer NOT NULL DEFAULT 1,
  created_under_version uuid, created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id));
CREATE UNIQUE INDEX ux_items_sku ON items (site_id, (data->>'sku'));

CREATE TABLE stock_movements (
  id bigserial PRIMARY KEY,
  site_id uuid NOT NULL REFERENCES sites(id),
  item_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('receive','adjust','reserve','commit','release','consume','return')),
  qty numeric NOT NULL CHECK (qty <> 0 AND (qty > 0 OR kind = 'adjust')),
  ref_type text, ref_id uuid, reason text,
  idempotency_key text NOT NULL,
  expires_at timestamptz,
  consumed_by bigint REFERENCES stock_movements(id),
  actor_id uuid, at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (site_id, item_id) REFERENCES items (site_id, id),
  UNIQUE (site_id, idempotency_key));
CREATE INDEX ix_mov_item ON stock_movements (site_id, item_id, at);
CREATE INDEX ix_mov_expiry ON stock_movements (expires_at) WHERE kind = 'reserve' AND consumed_by IS NULL;

CREATE TABLE requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  item_id uuid NOT NULL,
  qty numeric NOT NULL CHECK (qty > 0),
  state text NOT NULL,
  requested_by uuid REFERENCES users(id),
  data jsonb NOT NULL DEFAULT '{}',
  row_version integer NOT NULL DEFAULT 1,
  created_under_version uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id),
  FOREIGN KEY (site_id, item_id) REFERENCES items (site_id, id));
CREATE INDEX ix_req_state ON requests (site_id, state);
CREATE INDEX ix_req_by ON requests (site_id, requested_by);

CREATE TABLE approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  request_id uuid NOT NULL,
  decision text NOT NULL CHECK (decision IN ('approved','rejected')),
  decided_by uuid, note text,
  data jsonb NOT NULL DEFAULT '{}',
  row_version integer NOT NULL DEFAULT 1, created_under_version uuid,
  at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id),
  FOREIGN KEY (site_id, request_id) REFERENCES requests (site_id, id));

CREATE TABLE assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  request_id uuid NOT NULL, item_id uuid NOT NULL,
  qty numeric NOT NULL CHECK (qty > 0),
  assigned_to uuid, state text NOT NULL DEFAULT 'assigned',
  data jsonb NOT NULL DEFAULT '{}',
  row_version integer NOT NULL DEFAULT 1, created_under_version uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id),
  FOREIGN KEY (site_id, request_id) REFERENCES requests (site_id, id),
  FOREIGN KEY (site_id, item_id) REFERENCES items (site_id, id));
CREATE INDEX ix_asg_state ON assignments (site_id, state);

CREATE TABLE consumptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  assignment_id uuid NOT NULL,
  qty numeric NOT NULL CHECK (qty > 0),
  note text,
  data jsonb NOT NULL DEFAULT '{}',
  idempotency_key text NOT NULL,
  recorded_by uuid, recorded_at timestamptz NOT NULL DEFAULT now(), synced_at timestamptz,
  row_version integer NOT NULL DEFAULT 1, created_under_version uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id), UNIQUE (site_id, idempotency_key),
  FOREIGN KEY (site_id, assignment_id) REFERENCES assignments (site_id, id));

CREATE TABLE returns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  ref_type text NOT NULL CHECK (ref_type IN ('assignment','request')),
  ref_id uuid NOT NULL, item_id uuid NOT NULL,
  qty numeric NOT NULL CHECK (qty > 0), condition text,
  data jsonb NOT NULL DEFAULT '{}', returned_by uuid,
  at timestamptz NOT NULL DEFAULT now(),
  row_version integer NOT NULL DEFAULT 1, created_under_version uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id),
  FOREIGN KEY (site_id, item_id) REFERENCES items (site_id, id));

CREATE TABLE repairs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id uuid NOT NULL REFERENCES sites(id),
  request_id uuid NOT NULL,
  serial_no text, fault text, diagnosis text,
  parts_used jsonb NOT NULL DEFAULT '[]',
  state text NOT NULL DEFAULT 'open',
  technician_id uuid,
  data jsonb NOT NULL DEFAULT '{}',
  row_version integer NOT NULL DEFAULT 1, created_under_version uuid,
  opened_at timestamptz NOT NULL DEFAULT now(), closed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (site_id, id),
  FOREIGN KEY (site_id, request_id) REFERENCES requests (site_id, id));

CREATE INDEX gin_items_data ON items USING gin (data);
CREATE INDEX gin_requests_data ON requests USING gin (data);
CREATE INDEX gin_approvals_data ON approvals USING gin (data);
CREATE INDEX gin_assignments_data ON assignments USING gin (data);
CREATE INDEX gin_consumptions_data ON consumptions USING gin (data);
CREATE INDEX gin_returns_data ON returns USING gin (data);
CREATE INDEX gin_repairs_data ON repairs USING gin (data);

CREATE VIEW v_ledger_balance WITH (security_invoker = true) AS
SELECT site_id, item_id,
  SUM(CASE kind WHEN 'receive' THEN qty WHEN 'adjust' THEN qty WHEN 'return' THEN qty
                WHEN 'commit' THEN -qty WHEN 'consume' THEN -qty ELSE 0 END) AS on_hand,
  SUM(CASE kind WHEN 'reserve' THEN qty WHEN 'commit' THEN -qty WHEN 'release' THEN -qty ELSE 0 END) AS reserved
FROM stock_movements GROUP BY site_id, item_id;

-- ---------- FORCE RLS on every site-scoped table ----------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['site_versions','site_deployments','recordings','law_runs','audit_events',
    'items','stock_movements','requests','approvals','assignments','consumptions','returns','repairs'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY site_iso ON %I USING (site_id = app_site()) WITH CHECK (site_id = app_site())', t);
  END LOOP;
END $$;

ALTER TABLE memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE memberships FORCE ROW LEVEL SECURITY;
CREATE POLICY m_read   ON memberships FOR SELECT USING (site_id = app_site() OR user_id = app_user());
CREATE POLICY m_insert ON memberships FOR INSERT WITH CHECK (site_id = app_site());
CREATE POLICY m_update ON memberships FOR UPDATE USING (site_id = app_site()) WITH CHECK (site_id = app_site());
CREATE POLICY m_delete ON memberships FOR DELETE USING (site_id = app_site());

CREATE FUNCTION memberships_role_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    IF coalesce(current_setting('app.role', true), '') <> 'Admin' THEN
      RAISE EXCEPTION 'ROLE_CHANGE_ADMIN_ONLY' USING ERRCODE = '42501';
    END IF;
    IF NEW.user_id = app_user() THEN
      RAISE EXCEPTION 'SELF_ROLE_CHANGE' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_memberships_role BEFORE UPDATE ON memberships
  FOR EACH ROW EXECUTE FUNCTION memberships_role_guard();
'@

W 'apps/api/src/migrate.ts' @'
import pg from 'pg';
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'migrations');
const c = new pg.Client({ connectionString: process.env.DATABASE_URL_OWNER });
await c.connect();
await c.query('CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz DEFAULT now())');
const done = new Set((await c.query('SELECT name FROM schema_migrations')).rows.map(r => r.name));
for (const f of (await readdir(dir)).filter(f => f.endsWith('.sql')).sort()) {
  if (done.has(f)) continue;
  const sql = await readFile(path.join(dir, f), 'utf8');
  try {
    await c.query('BEGIN');
    await c.query(sql);
    await c.query('INSERT INTO schema_migrations (name) VALUES ($1)', [f]);
    await c.query('COMMIT');
    console.log(`applied ${f}`);
  } catch (e) {
    await c.query('ROLLBACK');
    console.error(`failed ${f}`, e);
    process.exit(1);
  }
}
await c.end();
'@

W 'apps/api/src/db.ts' @'
import pg from 'pg';
import type { Role } from '@axel/compiler';

pg.types.setTypeParser(1700, v => (v === null ? null : parseFloat(v)));

export const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL_APP, max: 20 });
export type Tx = pg.PoolClient;
export interface SiteCtx { siteId: string; userId: string; role: Role | ''; versionId?: string }

async function inTx<T>(setup: (c: Tx) => Promise<unknown>, fn: (c: Tx) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await setup(c);
    const r = await fn(c);
    await c.query('COMMIT');
    return r;
  } catch (e) {
    await c.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

// Every site-scoped query runs here. Context is transaction-local, so pooled connections never carry a stale site.
export const withSite = <T>(ctx: SiteCtx, fn: (c: Tx) => Promise<T>) =>
  inTx(c => c.query(
    `SELECT set_config('app.site_id',$1,true), set_config('app.user_id',$2,true), set_config('app.role',$3,true)`,
    [ctx.siteId, ctx.userId, ctx.role],
  ), fn);

// Hub-level context: no site, only the user (lets a user read their own memberships).
export const withUser = <T>(userId: string, fn: (c: Tx) => Promise<T>) =>
  inTx(c => c.query(`SELECT set_config('app.user_id',$1,true)`, [userId]), fn);

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
'@

W 'apps/api/src/errors.ts' @'
import type { ErrorRequestHandler, RequestHandler } from 'express';
import { ZodError } from 'zod';

export class AxelError extends Error {
  constructor(public code: string, public status: number, message: string, public extra: Record<string, unknown> = {}) {
    super(message);
  }
}
export const notFound = () => new AxelError('NOT_FOUND', 404, 'Not found.');

export const ah = (fn: (...a: Parameters<RequestHandler>) => Promise<unknown>): RequestHandler =>
  (req, res, next) => fn(req, res, next).catch(next);

export const errorHandler: ErrorRequestHandler = (err, _req, res, _next) => {
  if (err instanceof AxelError) return res.status(err.status).json({ code: err.code, message: err.message, ...err.extra });
  if (err instanceof ZodError) {
    const unknown = err.issues.flatMap(i => (i.code === 'unrecognized_keys' ? i.keys : []));
    if (unknown.length)
      return res.status(422).json({ code: 'FIELD_NOT_WRITABLE', message: `You can't set ${unknown.join(', ')} here.`, fields: unknown });
    return res.status(422).json({
      code: 'VALIDATION_FAILED', message: 'Some fields need attention.',
      errors: err.issues.map(i => ({ field: i.path.join('.'), message: i.message })),
    });
  }
  switch (err?.code) {
    case '23503': return res.status(422).json({ code: 'VALIDATION_FAILED', message: 'A referenced record does not exist in this site.' });
    case '23505': return res.status(409).json({ code: 'DUPLICATE', message: 'A record with that value already exists in this site.' });
    case '23514': return res.status(422).json({ code: 'LAW_VIOLATION', message: 'That change would break a stock rule (on-hand or reserved).', constraint: err.constraint });
    case '22P02': return res.status(404).json({ code: 'NOT_FOUND', message: 'Not found.' });
    case '42501': return res.status(404).json({ code: 'NOT_FOUND', message: 'Not found.' });
  }
  console.error(err);
  res.status(500).json({ code: 'INTERNAL', message: 'Something went wrong.' });
};
'@

W 'apps/api/src/auth.ts' @'
import { Router, type RequestHandler } from 'express';
import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { pool, withUser } from './db';
import { AxelError, ah } from './errors';
import type { SiteReq } from './site';

export interface AuthUser { id: string; hubAdmin: boolean }
declare global {
  namespace Express { interface Request { user?: AuthUser; site?: SiteReq } }
}

const SECRET = process.env.JWT_SECRET!;
if (!SECRET || SECRET.length < 32) throw new Error('JWT_SECRET must be at least 32 chars');

export const sign = (u: { id: string; is_hub_admin: boolean }) =>
  jwt.sign({ hub_admin: u.is_hub_admin }, SECRET, { subject: u.id, expiresIn: process.env.JWT_TTL ?? '12h' } as jwt.SignOptions);

export const requireAuth: RequestHandler = (req, _res, next) => {
  const h = req.headers.authorization;
  if (!h?.startsWith('Bearer ')) return next(new AxelError('UNAUTHENTICATED', 401, 'Log in to continue.'));
  try {
    const p = jwt.verify(h.slice(7), SECRET) as jwt.JwtPayload;
    req.user = { id: p.sub!, hubAdmin: !!p.hub_admin };
    next();
  } catch {
    next(new AxelError('UNAUTHENTICATED', 401, 'Your session expired. Log in again.'));
  }
};

export const requireHubAdmin: RequestHandler = (req, _res, next) =>
  next(req.user?.hubAdmin ? undefined : new AxelError('FORBIDDEN', 403, 'Only hub admins can do this.'));

export const memberships = (userId: string) =>
  withUser(userId, async c => (await c.query(
    `SELECT m.site_id, m.role, s.slug, s.name FROM memberships m JOIN sites s ON s.id = m.site_id
     WHERE m.user_id = $1 ORDER BY s.name`, [userId])).rows);

export const authRouter = Router();

authRouter.post('/login', ah(async (req, res) => {
  const { email, password } = z.object({ email: z.string().email(), password: z.string().min(1) }).parse(req.body);
  const u = (await pool.query('SELECT * FROM users WHERE email = $1', [email])).rows[0];
  const ok = await bcrypt.compare(password, u?.password_hash ?? '$2a$12$invalidinvalidinvalidinvalidinvalidinvalidinvalidinv');
  if (!u || !ok) throw new AxelError('UNAUTHENTICATED', 401, 'Email or password is wrong.');
  res.json({
    token: sign(u),
    user: { id: u.id, email: u.email, name: u.name, hubAdmin: u.is_hub_admin },
    memberships: await memberships(u.id),
  });
}));

authRouter.post('/refresh', requireAuth, ah(async (req, res) => {
  const u = (await pool.query('SELECT id, is_hub_admin FROM users WHERE id = $1', [req.user!.id])).rows[0];
  if (!u) throw new AxelError('UNAUTHENTICATED', 401, 'Account no longer exists.');
  res.json({ token: sign(u) });
}));
'@

W 'apps/api/src/blueprints.ts' @'
import pg from 'pg';
import { EventEmitter } from 'node:events';
import { compile, type Blueprint, type Compiled } from '@axel/compiler';
import { withSite } from './db';

export interface Loaded { siteId: string; slug: string; name: string; versionId: string; compiled: Compiled }
const cache = new Map<string, Promise<Loaded | null>>();
export const bus = new EventEmitter();

export function getPublished(siteId: string): Promise<Loaded | null> {
  let p = cache.get(siteId);
  if (!p) {
    p = withSite({ siteId, userId: '', role: '' }, async c => {
      const r = (await c.query(
        `SELECT s.slug, s.name, v.id AS version_id, v.config
           FROM sites s JOIN site_versions v ON v.id = s.published_version_id
          WHERE s.id = $1`, [siteId])).rows[0];
      if (!r) return null;
      return { siteId, slug: r.slug, name: r.name, versionId: r.version_id, compiled: compile(r.config as Blueprint) };
    });
    p.catch(() => cache.delete(siteId));
    p.then(v => { if (!v) cache.delete(siteId); });
    cache.set(siteId, p);
  }
  return p;
}

export const invalidate = (siteId: string) => cache.delete(siteId);

export async function startPublishListener() {
  const c = new pg.Client({ connectionString: process.env.DATABASE_URL_APP });
  await c.connect();
  await c.query('LISTEN site_published');
  c.on('notification', n => {
    const [siteId, versionId] = (n.payload ?? '').split(':');
    invalidate(siteId);
    bus.emit('site_published', { siteId, versionId });
  });
  c.on('error', e => { console.error('listener lost', e); setTimeout(startPublishListener, 2000); });
}
'@

W 'apps/api/src/site.ts' @'
import type { RequestHandler } from 'express';
import type { Role } from '@axel/compiler';
import { withSite, UUID, type SiteCtx } from './db';
import { getPublished, type Loaded } from './blueprints';
import { AxelError, ah, notFound } from './errors';

export interface SiteReq extends Loaded { role: Role; ctx: SiteCtx }

export const siteScope: RequestHandler = ah(async (req, _res, next) => {
  const siteId = req.params.siteId;
  const isRead = req.method === 'GET';
  if (!UUID.test(siteId)) throw notFound();
  if (req.header('x-site-id') !== siteId)
    throw new AxelError('SITE_HEADER_MISMATCH', 400, 'X-Site-Id must match the site in the URL.');

  const userId = req.user!.id;
  const role = await withSite({ siteId, userId, role: '' }, async c =>
    (await c.query('SELECT role FROM memberships WHERE site_id = $1 AND user_id = $2', [siteId, userId])).rows[0]?.role as Role | undefined);
  if (!role) throw isRead ? notFound() : new AxelError('NO_MEMBERSHIP', 403, 'You are not a member of this site.');

  const loaded = await getPublished(siteId);
  if (!loaded) throw notFound();
  req.site = { ...loaded, role, ctx: { siteId, userId, role, versionId: loaded.versionId } };
  next();
});

export const requireRole = (min: Role): RequestHandler => (req, _res, next) => {
  const rank = { Public: 0, Member: 1, Manager: 2, Admin: 3 };
  next(rank[req.site!.role] >= rank[min] ? undefined
    : new AxelError('TRANSITION_NOT_ALLOWED', 403, `Only ${min}s and above can do this in ${req.site!.name}.`));
};
'@

W 'apps/api/src/entities.ts' @'
import { randomUUID } from 'node:crypto';
import type { Blueprint } from '@axel/compiler';

export interface TableSpec { table: string; core: string[]; insertDefaults?: () => Record<string, unknown> }

export const TABLES: Record<string, TableSpec> = {
  item:        { table: 'items',        core: ['name', 'on_hand', 'reserved'] },
  request:     { table: 'requests',     core: ['item_id', 'qty', 'state', 'requested_by'] },
  approval:    { table: 'approvals',    core: ['request_id', 'decision', 'decided_by', 'note'] },
  assignment:  { table: 'assignments',  core: ['request_id', 'item_id', 'qty', 'assigned_to', 'state'] },
  consumption: { table: 'consumptions', core: ['assignment_id', 'qty', 'note'], insertDefaults: () => ({ idempotency_key: randomUUID() }) },
  return:      { table: 'returns',      core: ['ref_type', 'ref_id', 'item_id', 'qty', 'condition'] },
  repair:      { table: 'repairs',      core: ['request_id', 'serial_no', 'fault', 'diagnosis', 'state', 'technician_id'] },
};

export function resolveEntity(bp: Blueprint, seg: string): string | null {
  if (bp.entities[seg] && TABLES[seg]) return seg;
  return Object.keys(bp.entities).find(k => TABLES[k]?.table === seg) ?? null;
}

export function toRecord(entity: string, row: Record<string, any>) {
  const { data, site_id, created_under_version, ...rest } = row;
  const rec: Record<string, unknown> = { ...(data ?? {}), ...rest };
  if (entity === 'item') rec.available = Number(rec.on_hand) - Number(rec.reserved);
  return rec;
}

export function split(spec: TableSpec, body: Record<string, unknown>) {
  const core: Record<string, unknown> = {}, data: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(body)) (spec.core.includes(k) ? core : data)[k] = v;
  return { core, data };
}
'@

W 'apps/api/src/ledger.ts' @'
import type { Tx, SiteCtx } from './db';
import { AxelError, notFound } from './errors';

export async function move(tx: Tx, ctx: SiteCtx, m: {
  itemId: string; kind: 'receive' | 'adjust'; qty: number; key: string; reason?: string;
}) {
  if (m.kind === 'receive' && m.qty <= 0) throw new AxelError('VALIDATION_FAILED', 422, 'Received quantity must be positive.');
  if (m.qty === 0) throw new AxelError('VALIDATION_FAILED', 422, 'Quantity cannot be zero.');

  const item = (await tx.query(
    'SELECT id, name, on_hand, reserved FROM items WHERE site_id = $1 AND id = $2 FOR UPDATE',
    [ctx.siteId, m.itemId])).rows[0];
  if (!item) throw notFound();

  if (item.on_hand + m.qty < item.reserved)
    throw new AxelError('INSUFFICIENT_STOCK', 409,
      `Adjust refused: ${item.name} has ${item.reserved} reserved; on-hand cannot drop to ${item.on_hand + m.qty}.`,
      { because: { kind: 'law', ref: 'reserved_le_on_hand' }, suggestion: 'Release or commit reservations first.' });

  const ins = await tx.query(
    `INSERT INTO stock_movements (site_id, item_id, kind, qty, reason, idempotency_key, actor_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (site_id, idempotency_key) DO NOTHING RETURNING id`,
    [ctx.siteId, m.itemId, m.kind, m.qty, m.reason ?? null, m.key, ctx.userId]);
  if (!ins.rowCount) return { replay: true, item };

  const after = (await tx.query(
    `UPDATE items SET on_hand = on_hand + $3, row_version = row_version + 1, updated_at = now()
     WHERE site_id = $1 AND id = $2 RETURNING *`, [ctx.siteId, m.itemId, m.qty])).rows[0];

  await tx.query(
    `INSERT INTO audit_events (site_id, entity, record_id, kind, actor_id, actor_role, before, after, version_id, idempotency_key)
     VALUES ($1,'item',$2,$3,$4,$5,$6,$7,$8,$9)`,
    [ctx.siteId, m.itemId, `stock_${m.kind}`, ctx.userId, ctx.role,
     { on_hand: item.on_hand }, { on_hand: after.on_hand }, ctx.versionId ?? null, m.key]);
  return { replay: false, item: after };
}
'@

W 'apps/api/src/resources.ts' @'
import { Router } from 'express';
import { z } from 'zod';
import { REGISTRY } from '@axel/compiler';
import { withSite, UUID, type Tx } from './db';
import { TABLES, resolveEntity, toRecord, split } from './entities';
import { AxelError, ah, notFound } from './errors';
import { requireRole } from './site';
import { move } from './ledger';

export const resources = Router({ mergeParams: true });

const entityOr404 = (req: any) => {
  const e = resolveEntity(req.site.compiled.blueprint, req.params.entity);
  if (!e) throw new AxelError('ENTITY_NOT_IN_SITE', 404, 'Not found.');
  return e;
};
const present = (req: any, entity: string, row: any) => {
  const { compiled, role } = req.site;
  return compiled.mask(entity, role, compiled.computeFormulas(entity, toRecord(entity, row)));
};
const audit = (tx: Tx, req: any, entity: string, id: string, kind: string, before: unknown, after: unknown) =>
  tx.query(
    `INSERT INTO audit_events (site_id, entity, record_id, kind, actor_id, actor_role, before, after, version_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
    [req.site.siteId, entity, id, kind, req.site.ctx.userId, req.site.role, before, after, req.site.versionId]);

// GET /components - enabled modules (brief alias)
resources.get('/components', (req, res) => {
  const bp = req.site!.compiled.blueprint;
  res.json(bp.modules.map(id => ({ id, name: REGISTRY[id]?.name, kind: REGISTRY[id]?.kind })));
});

// LIST
resources.get('/:entity', ah(async (req, res) => {
  const entity = entityOr404(req);
  const spec = TABLES[entity];
  const fields = new Set(req.site!.compiled.blueprint.entities[entity].fields.map(f => f.key));
  const q = z.object({
    page: z.coerce.number().int().min(1).default(1),
    limit: z.coerce.number().int().min(1).max(200).default(50),
    sort: z.string().optional(),
    filter: z.record(z.string()).optional(),
  }).parse(req.query);

  const where: string[] = [];
  const args: unknown[] = [];
  for (const [k, v] of Object.entries(q.filter ?? {})) {
    if (!fields.has(k) && k !== 'state') throw new AxelError('VALIDATION_FAILED', 422, `Cannot filter by ${k}.`);
    args.push(v);
    where.push(spec.core.includes(k) ? `${k}::text = $${args.length}` : `data->>'${k}' = $${args.length}`);
  }
  let order = 'created_at DESC';
  if (q.sort) {
    const desc = q.sort.startsWith('-');
    const col = q.sort.replace(/^-/, '');
    if (![...spec.core, 'created_at', 'updated_at'].includes(col)) throw new AxelError('VALIDATION_FAILED', 422, `Cannot sort by ${col}.`);
    order = `${col} ${desc ? 'DESC' : 'ASC'}`;
  }
  args.push(q.limit, (q.page - 1) * q.limit);
  const rows = await withSite(req.site!.ctx, async c => (await c.query(
    `SELECT *, count(*) OVER() AS _total FROM ${spec.table}
     ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
     ORDER BY ${order} LIMIT $${args.length - 1} OFFSET $${args.length}`, args)).rows);
  res.json({ total: Number(rows[0]?._total ?? 0), page: q.page, rows: rows.map(({ _total, ...r }) => present(req, entity, r)) });
}));

// CREATE
resources.post('/:entity', ah(async (req, res) => {
  const entity = entityOr404(req);
  const spec = TABLES[entity];
  const { compiled, role, ctx } = req.site!;
  const body = compiled.validator(entity, role, 'create').parse(req.body ?? {});
  const { core, data } = split(spec, body);
  if (entity === 'request') {
    core.state = compiled.blueprint.workflows.request?.initial ?? 'draft';
    core.requested_by = ctx.userId;
  }
  Object.assign(core, spec.insertDefaults?.());
  const cols = ['site_id', 'created_under_version', ...Object.keys(core), 'data'];
  const vals = [ctx.siteId, req.site!.versionId, ...Object.values(core), data];
  const row = await withSite(ctx, async c => {
    const r = (await c.query(
      `INSERT INTO ${spec.table} (${cols.join(',')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(',')}) RETURNING *`, vals)).rows[0];
    await audit(c, req, entity, r.id, 'create', null, body);
    return r;
  });
  res.status(201).json(present(req, entity, row));
}));

// READ
resources.get('/:entity/:id', ah(async (req, res) => {
  const entity = entityOr404(req);
  if (!UUID.test(req.params.id)) throw notFound();
  const row = await withSite(req.site!.ctx, async c =>
    (await c.query(`SELECT * FROM ${TABLES[entity].table} WHERE id = $1`, [req.params.id])).rows[0]);
  if (!row) throw notFound();
  const wf = req.site!.compiled.blueprint.workflows[entity];
  const allowedTransitions = wf?.transitions
    .filter(t => t.from === row.state && t.roles.includes(req.site!.role))
    .map(t => ({ id: t.id, to: t.to, label: t.label ?? t.to })) ?? [];
  res.json({ ...present(req, entity, row), allowedTransitions });
}));

// UPDATE (optimistic concurrency)
resources.patch('/:entity/:id', ah(async (req, res) => {
  const entity = entityOr404(req);
  if (!UUID.test(req.params.id)) throw notFound();
  const spec = TABLES[entity];
  const { compiled, role, ctx } = req.site!;
  const { ifVersion, ...rest } = req.body ?? {};
  if (!Number.isInteger(ifVersion)) throw new AxelError('VALIDATION_FAILED', 422, 'ifVersion is required.');
  const body = compiled.validator(entity, role, 'update').parse(rest);
  const { core, data } = split(spec, body);

  const row = await withSite(ctx, async c => {
    const before = (await c.query(`SELECT * FROM ${spec.table} WHERE id = $1 FOR UPDATE`, [req.params.id])).rows[0];
    if (!before) throw notFound();
    if (before.row_version !== ifVersion)
      throw new AxelError('STALE_RECORD', 409, `This record changed since you opened it (now v${before.row_version}). Reload to continue.`, { current: before.row_version });
    const sets = Object.keys(core).map((k, i) => `${k} = $${i + 3}`);
    const r = (await c.query(
      `UPDATE ${spec.table} SET ${[...sets, `data = data || $${sets.length + 3}`, 'row_version = row_version + 1', 'updated_at = now()'].join(', ')}
       WHERE id = $1 AND row_version = $2 RETURNING *`,
      [req.params.id, ifVersion, ...Object.values(core), data])).rows[0];
    await audit(c, req, entity, r.id, 'update', toRecord(entity, before), body);
    return r;
  });
  res.json(present(req, entity, row));
}));

// STOCK: receive / adjust through the ledger only
resources.post('/:entity/:id/stock', requireRole('Manager'), ah(async (req, res) => {
  const entity = entityOr404(req);
  if (entity !== 'item' || !UUID.test(req.params.id)) throw notFound();
  const b = z.object({
    kind: z.enum(['receive', 'adjust']),
    qty: z.coerce.number().refine(n => n !== 0, 'qty cannot be zero'),
    reason: z.string().max(200).optional(),
    idempotencyKey: z.string().min(8).max(100),
  }).parse(req.body);
  const r = await withSite(req.site!.ctx, c => move(c, req.site!.ctx, { itemId: req.params.id, kind: b.kind, qty: b.qty, key: b.idempotencyKey, reason: b.reason }));
  res.status(r.replay ? 200 : 201).json({ replay: r.replay, item: present(req, 'item', r.item) });
}));
'@

W 'apps/api/src/starter.ts' @'
import type { Blueprint } from '@axel/compiler';

export const starterBlueprint = (): Blueprint => ({
  configVersion: 3, siteId: '', slug: '', name: '',
  theme: { tokens: { primary: '#4F46E5', surface: '#F8FAFC', radius: '8px', font: 'Inter' }, layout: 'topbar', density: 'comfortable', home: '/items' },
  modules: ['auth', 'users', 'dashboard', 'inventory', 'analytics', 'excel'],
  entities: {
    item: { owner_module: 'inventory', label: 'Item', fields: [
      { key: 'sku', type: 'text', label: 'SKU', required: true, unique: true },
      { key: 'name', type: 'text', label: 'Name', required: true },
      { key: 'unit_price', type: 'money', label: 'Unit price', roles: { read: ['Manager', 'Admin'], write: ['Manager', 'Admin'] } },
      { key: 'on_hand', type: 'number', label: 'On hand', system: true },
      { key: 'reserved', type: 'number', label: 'Reserved', system: true },
      { key: 'available', type: 'number', label: 'Available', system: true },
    ] },
  },
  workflows: {},
  laws: [{ id: 'l0', template: 'site_isolation', locked: true }, { id: 'l1', template: 'non_negative', entity: 'item', field: 'on_hand' }],
  pages: [{ path: '/items', title: 'Stock', view: 'table', entity: 'item', columns: ['sku', 'name', 'on_hand', 'available', 'unit_price'] }],
  roles: ['Public', 'Member', 'Manager', 'Admin'],
  nav: [{ label: 'Stock', path: '/items' }],
});
'@

W 'apps/api/src/sites.ts' @'
import { Router } from 'express';
import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod';
import { compile, canonicalJson, type Blueprint } from '@axel/compiler';
import { withSite, withUser } from './db';
import { getPublished } from './blueprints';
import { requireAuth, requireHubAdmin } from './auth';
import { siteScope } from './site';
import { AxelError, ah } from './errors';
import { starterBlueprint } from './starter';

export const sitesRouter = Router();
export const hashBlueprint = (bp: Blueprint) => 'sha256:' + createHash('sha256').update(canonicalJson(bp)).digest('hex');

sitesRouter.get('/', requireAuth, ah(async (req, res) => {
  const mine = await withUser(req.user!.id, async c => (await c.query(
    `SELECT s.id, s.slug, s.name, m.role FROM memberships m JOIN sites s ON s.id = m.site_id
     WHERE m.user_id = $1 AND s.slug <> 'hub' ORDER BY s.name`, [req.user!.id])).rows);
  const out = await Promise.all(mine.map(async s => {
    const p = await getPublished(s.id);
    const bp = p?.compiled.blueprint;
    return { ...s, versionId: p?.versionId, theme: bp && { primary: bp.theme.tokens.primary, layout: bp.theme.layout }, modules: bp?.modules ?? [] };
  }));
  res.json(out);
}));

sitesRouter.post('/', requireAuth, requireHubAdmin, ah(async (req, res) => {
  const b = z.object({
    name: z.string().min(2).max(60),
    slug: z.string().regex(/^[a-z0-9][a-z0-9-]{1,40}$/),
    blueprint: z.any().optional(),
    reason: z.string().max(200).optional(),
  }).parse(req.body);
  const siteId = randomUUID();
  const bp: Blueprint = { ...(b.blueprint ?? starterBlueprint()), siteId, slug: b.slug, name: b.name };
  const compiled = compile(bp);
  if (!compiled.ok) throw new AxelError('VALIDATION_FAILED', 422, 'The blueprint has problems.', { diagnostics: compiled.diagnostics });

  const userId = req.user!.id;
  const result = await withSite({ siteId, userId, role: 'Admin' }, async c => {
    await c.query('INSERT INTO sites (id, slug, name, created_by) VALUES ($1,$2,$3,$4)', [siteId, b.slug, b.name, userId]);
    await c.query(`INSERT INTO memberships (site_id, user_id, role) VALUES ($1,$2,'Admin')`, [siteId, userId]);
    const v = (await c.query(
      `INSERT INTO site_versions (site_id, config, content_hash, status, author_id, reason)
       VALUES ($1,$2,$3,'published',$4,$5) RETURNING id`,
      [siteId, bp, hashBlueprint(bp), userId, b.reason ?? 'site created'])).rows[0];
    await c.query(
      `INSERT INTO site_deployments (site_id, version_id, proof, deployed_by) VALUES ($1,$2,$3,$4)`,
      [siteId, v.id, { versionHash: hashBlueprint(bp), compiledAt: new Date().toISOString(), note: 'initial publish' }, userId]);
    await c.query('UPDATE sites SET published_version_id = $2 WHERE id = $1', [siteId, v.id]);
    await c.query(`SELECT pg_notify('site_published', $1)`, [`${siteId}:${v.id}`]);
    return { id: siteId, slug: b.slug, name: b.name, versionId: v.id };
  });
  res.status(201).json(result);
}));

sitesRouter.get('/:siteId/render-schema', requireAuth, siteScope, (req, res) => {
  const { compiled, role, versionId } = req.site!;
  res.json({ versionId, ...compiled.renderSchema(role) });
});
'@

W 'apps/api/src/server.ts' @'
import express from 'express';
import { authRouter, requireAuth, memberships } from './auth';
import { sitesRouter } from './sites';
import { siteScope } from './site';
import { resources } from './resources';
import { errorHandler, ah } from './errors';
import { pool } from './db';
import { startPublishListener } from './blueprints';

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '2mb' }));

app.get('/api/health', ah(async (_req, res) => { await pool.query('SELECT 1'); res.json({ ok: true }); }));
app.use('/api/auth', authRouter);
app.get('/api/me', requireAuth, ah(async (req, res) => {
  const u = (await pool.query('SELECT id, email, name, is_hub_admin FROM users WHERE id = $1', [req.user!.id])).rows[0];
  res.json({ user: { id: u.id, email: u.email, name: u.name, hubAdmin: u.is_hub_admin }, memberships: await memberships(u.id) });
}));
app.use('/api/sites', sitesRouter);
app.use('/api/:siteId', requireAuth, siteScope, resources);
app.use(errorHandler);

await startPublishListener();
const port = Number(process.env.PORT ?? 4000);
app.listen(port, () => console.log(`Axel API on :${port}`));
'@

# ============================== SEED ==============================
W 'apps/api/seed/blueprints.ts' @'
import type { Blueprint, Entity, Field } from '@axel/compiler';

export const SITE_IDS = {
  'central-stores': '11111111-1111-4111-8111-111111111111',
  'service-centre': '22222222-2222-4222-8222-222222222222',
  distribution:     '33333333-3333-4333-8333-333333333333',
} as const;

const R4 = ['Public', 'Member', 'Manager', 'Admin'] as Blueprint['roles'];
const MGR = { read: ['Manager', 'Admin'], write: ['Manager', 'Admin'] } as Field['roles'];

const item = (extra: Field[] = []): Entity => ({ owner_module: 'inventory', label: 'Item', fields: [
  { key: 'sku', type: 'text', label: 'SKU', required: true, unique: true },
  { key: 'name', type: 'text', label: 'Name', required: true },
  { key: 'category', type: 'select', label: 'Category', options: ['Electrical', 'Mechanical', 'Consumable', 'PCB'], default: 'Consumable' },
  { key: 'unit_price', type: 'money', label: 'Unit price', roles: MGR, reason: 'cost confidential' },
  { key: 'on_hand', type: 'number', label: 'On hand', system: true },
  { key: 'reserved', type: 'number', label: 'Reserved', system: true },
  { key: 'available', type: 'number', label: 'Available', system: true },
  ...extra,
] });

const baseLaws = [
  { id: 'l0', template: 'site_isolation', locked: true },
  { id: 'l1', template: 'non_negative', entity: 'item', field: 'on_hand' },
  { id: 'l5', template: 'reserved_le_on_hand', entity: 'item' },
];

export const centralStores: Blueprint = {
  configVersion: 3, siteId: SITE_IDS['central-stores'], slug: 'central-stores', name: 'Central Stores',
  theme: { tokens: { primary: '#1D4ED8', surface: '#F1F5F9', radius: '4px', font: 'Inter' }, layout: 'sidebar', density: 'compact', home: '/analytics' },
  modules: ['auth', 'users', 'dashboard', 'inventory', 'analytics', 'excel'],
  entities: {
    item: item([
      { key: 'reorder_level', type: 'number', label: 'Reorder level', min: 0, default: 10 },
      { key: 'bin', type: 'text', label: 'Bin location' },
      { key: 'stock_value', type: 'formula', label: 'Stock value', expr: 'on_hand * unit_price', roles: { read: ['Manager', 'Admin'] } },
    ]),
  },
  workflows: {},
  laws: [...baseLaws, { id: 'l3', template: 'hidden_from', entity: 'item', field: 'unit_price', role: 'Member' }],
  pages: [
    { path: '/analytics', title: 'Overview', view: 'dashboard', widgets: [
      { id: 'w1', type: 'bar', title: 'Items by category', entity: 'item', measure: 'count', by: 'category' },
      { id: 'w2', type: 'bar', title: 'On-hand by category', entity: 'item', measure: 'sum', field: 'on_hand', by: 'category' },
      { id: 'w3', type: 'stat', title: 'Stock value', entity: 'item', measure: 'sum', field: 'stock_value' },
    ] },
    { path: '/items', title: 'Stock register', view: 'table', entity: 'item', columns: ['sku', 'name', 'category', 'bin', 'on_hand', 'reserved', 'available', 'reorder_level', 'unit_price', 'stock_value'] },
  ],
  roles: R4,
  nav: [{ label: 'Overview', path: '/analytics' }, { label: 'Stock register', path: '/items' }],
};

export const serviceCentre: Blueprint = {
  configVersion: 3, siteId: SITE_IDS['service-centre'], slug: 'service-centre', name: 'Service Centre',
  theme: { tokens: { primary: '#0F766E', surface: '#F8FAFC', radius: '12px', font: 'Inter' }, layout: 'kanban-first', density: 'comfortable', home: '/requests' },
  modules: ['auth', 'users', 'dashboard', 'inventory', 'request', 'approval', 'pcb-repair', 'returns', 'analytics', 'excel'],
  entities: {
    item: item(),
    request: { owner_module: 'request', label: 'Repair request', fields: [
      { key: 'item_id', type: 'relation', to: 'item', label: 'Part', required: true },
      { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
      { key: 'unit_price', type: 'money', label: 'Unit price', roles: MGR },
      { key: 'total', type: 'formula', label: 'Total', expr: 'qty * unit_price', roles: { read: ['Manager', 'Admin'] } },
      { key: 'serial_no', type: 'text', label: 'Board serial', unique: true, owner_module: 'pcb-repair', reason: 'board identity' },
      { key: 'fault', type: 'text', label: 'Fault reported', required: true },
      { key: 'priority', type: 'select', label: 'Priority', options: ['low', 'normal', 'urgent'], default: 'normal' },
    ] },
    repair: { owner_module: 'pcb-repair', label: 'Repair log', fields: [
      { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
      { key: 'serial_no', type: 'text', label: 'Serial' },
      { key: 'fault', type: 'text', label: 'Fault' },
      { key: 'diagnosis', type: 'text', label: 'Diagnosis' },
    ] },
  },
  workflows: {
    request: {
      initial: 'draft',
      states: ['draft', 'submitted', 'approved', 'in_repair', 'closed', 'returned', 'rejected'],
      transitions: [
        { id: 't1', from: 'draft', to: 'submitted', label: 'Submit', roles: ['Member', 'Manager', 'Admin'], guard: 'stock.available(item_id) >= qty' },
        { id: 't2', from: 'submitted', to: 'approved', label: 'Approve', roles: ['Manager', 'Admin'], actions: ["stock.reserve(item_id, qty, ttl='72h')"] },
        { id: 't3', from: 'submitted', to: 'rejected', label: 'Reject', roles: ['Manager', 'Admin'] },
        { id: 't4', from: 'approved', to: 'in_repair', label: 'Start repair', roles: ['Manager', 'Admin'], actions: ['stock.commit(item_id, qty)', 'repair.open()'] },
        { id: 't5', from: 'in_repair', to: 'closed', label: 'Close', roles: ['Manager', 'Admin'], actions: ['repair.close()'] },
        { id: 't6', from: 'closed', to: 'returned', label: 'Return to customer', roles: ['Member', 'Manager', 'Admin'], actions: ["stock.release(item_id, qty, reason='return')"] },
      ],
      terminal: ['returned', 'rejected'],
    },
  },
  laws: [...baseLaws,
    { id: 'l3', template: 'hidden_from', entity: 'request', field: 'unit_price', role: 'Member' },
    { id: 'l4', template: 'reachable', workflow: 'request', state: 'closed' }],
  pages: [
    { path: '/requests', title: 'Repair board', view: 'kanban', entity: 'request', groupBy: 'state', columns: ['serial_no', 'fault', 'priority', 'qty', 'total'] },
    { path: '/repairs', title: 'Repair logs', view: 'table', entity: 'repair', columns: ['serial_no', 'fault', 'diagnosis', 'state'], roles: ['Manager', 'Admin'] },
    { path: '/items', title: 'Parts', view: 'table', entity: 'item', columns: ['sku', 'name', 'available', 'unit_price'] },
    { path: '/analytics', title: 'Insights', view: 'dashboard', roles: ['Manager', 'Admin'], widgets: [
      { id: 'w1', type: 'bar', title: 'Requests by state', entity: 'request', measure: 'count', by: 'state' },
      { id: 'w2', type: 'pie', title: 'By priority', entity: 'request', measure: 'count', by: 'priority' },
    ] },
  ],
  roles: R4,
  nav: [{ label: 'Repair board', path: '/requests' }, { label: 'Repair logs', path: '/repairs' }, { label: 'Parts', path: '/items' }, { label: 'Insights', path: '/analytics' }],
};

export const distribution: Blueprint = {
  configVersion: 3, siteId: SITE_IDS.distribution, slug: 'distribution', name: 'Distribution',
  theme: { tokens: { primary: '#B45309', surface: '#FFFBEB', radius: '6px', font: 'Inter' }, layout: 'queue-first', density: 'comfortable', home: '/assignments' },
  // Returns intentionally NOT enabled: the demo enables it live.
  modules: ['auth', 'users', 'dashboard', 'inventory', 'request', 'approval', 'material-assignment', 'assignment-frontend', 'consumption', 'analytics', 'excel'],
  entities: {
    item: item(),
    request: { owner_module: 'request', label: 'Material request', fields: [
      { key: 'item_id', type: 'relation', to: 'item', label: 'Material', required: true },
      { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
      { key: 'unit_price', type: 'money', label: 'Unit price', roles: MGR },
      { key: 'total', type: 'formula', label: 'Total', expr: 'qty * unit_price', roles: { read: ['Manager', 'Admin'] } },
      { key: 'site_location', type: 'text', label: 'Field location', required: true },
    ] },
    assignment: { owner_module: 'material-assignment', label: 'Assignment', fields: [
      { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
      { key: 'item_id', type: 'relation', to: 'item', label: 'Material', required: true },
      { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
      { key: 'assigned_to', type: 'text', label: 'Assigned to' },
    ] },
    consumption: { owner_module: 'consumption', label: 'Consumption', fields: [
      { key: 'assignment_id', type: 'relation', to: 'assignment', label: 'Assignment', required: true },
      { key: 'qty', type: 'number', label: 'Qty used', min: 1, required: true },
      { key: 'note', type: 'text', label: 'Note' },
    ] },
  },
  workflows: {
    request: {
      initial: 'draft',
      states: ['draft', 'submitted', 'approved', 'assigned', 'closed', 'rejected'],
      transitions: [
        { id: 't1', from: 'draft', to: 'submitted', label: 'Submit', roles: ['Member', 'Manager', 'Admin'], guard: 'stock.available(item_id) >= qty' },
        { id: 't2', from: 'submitted', to: 'approved', label: 'Approve', roles: ['Manager', 'Admin'], actions: ["stock.reserve(item_id, qty, ttl='72h')"] },
        { id: 't3', from: 'submitted', to: 'rejected', label: 'Reject', roles: ['Manager', 'Admin'] },
        { id: 't4', from: 'approved', to: 'assigned', label: 'Assign', roles: ['Manager', 'Admin'], actions: ['stock.commit(item_id, qty)'] },
        { id: 't5', from: 'assigned', to: 'closed', label: 'Close', roles: ['Member', 'Manager', 'Admin'] },
      ],
      terminal: ['closed', 'rejected'],
    },
  },
  laws: [...baseLaws, { id: 'l2', template: 'requires_state', entity: 'assignment', ref: 'request_id', state: 'approved' }],
  pages: [
    { path: '/assignments', title: 'Assignment queue', view: 'queue', entity: 'assignment', columns: ['item_id', 'qty', 'assigned_to'] },
    { path: '/requests', title: 'Requests', view: 'table', entity: 'request', columns: ['item_id', 'qty', 'site_location', 'state', 'total'] },
    { path: '/consumption', title: 'Field consumption', view: 'table', entity: 'consumption', columns: ['assignment_id', 'qty', 'note'] },
    { path: '/items', title: 'Materials', view: 'table', entity: 'item', columns: ['sku', 'name', 'available'] },
  ],
  roles: R4,
  nav: [{ label: 'Queue', path: '/assignments' }, { label: 'Requests', path: '/requests' }, { label: 'Consumption', path: '/consumption' }, { label: 'Materials', path: '/items' }],
};
'@

W 'apps/api/seed/seed.ts' @'
import pg from 'pg';
import bcrypt from 'bcryptjs';
import { randomUUID } from 'node:crypto';
import { compile, type Blueprint } from '@axel/compiler';
import { pool, withSite } from '../src/db';
import { hashBlueprint } from '../src/sites';
import { centralStores, serviceCentre, distribution, SITE_IDS } from './blueprints';

const owner = new pg.Client({ connectionString: process.env.DATABASE_URL_OWNER });
await owner.connect();
await owner.query(`TRUNCATE users, sites, memberships, site_versions, site_deployments, recordings, law_runs,
  audit_events, items, stock_movements, requests, approvals, assignments, consumptions, returns, repairs
  RESTART IDENTITY CASCADE`);
await owner.end();

const hash = await bcrypt.hash('demo1234', 12);
const mk = async (email: string, name: string, hub = false) =>
  (await pool.query('INSERT INTO users (email, password_hash, name, is_hub_admin) VALUES ($1,$2,$3,$4) RETURNING id', [email, hash, name, hub])).rows[0].id as string;

const admin = await mk('admin@axel.dev', 'Asha Admin', true);
const people: Record<string, [string, 'Manager' | 'Member'][]> = {
  'central-stores': [[await mk('manager@cs.dev', 'Chetan Manager'), 'Manager'], [await mk('member@cs.dev', 'Meera Member'), 'Member']],
  'service-centre': [[await mk('manager@sc.dev', 'Priya Manager'), 'Manager'], [await mk('member@sc.dev', 'Sahil Member'), 'Member']],
  distribution:     [[await mk('manager@dist.dev', 'Dev Manager'), 'Manager'], [await mk('field@dist.dev', 'Farah Field'), 'Member']],
};

const CATALOGUE: Record<string, [string, string, string, number][]> = {
  'central-stores': [['CS-001', 'Copper wire 2.5mm', 'Electrical', 42], ['CS-002', 'MCB 16A', 'Electrical', 180], ['CS-003', 'Hex bolt M8', 'Mechanical', 4], ['CS-004', 'Bearing 6204', 'Mechanical', 95], ['CS-005', 'Cable ties', 'Consumable', 1], ['CS-006', 'Insulation tape', 'Consumable', 18], ['CS-007', 'Relay 12V', 'Electrical', 65], ['CS-008', 'Gear oil 1L', 'Consumable', 310]],
  'service-centre': [['SC-101', 'Power board PB-4', 'PCB', 2400], ['SC-102', 'Control board CB-2', 'PCB', 3100], ['SC-103', 'Capacitor 470uF', 'Electrical', 12], ['SC-104', 'MOSFET IRF540', 'Electrical', 38], ['SC-105', 'Solder wire', 'Consumable', 220], ['SC-106', 'Display ribbon', 'Electrical', 150]],
  distribution:     [['DS-201', 'Smart meter', 'Electrical', 1850], ['DS-202', 'Service cable 10m', 'Electrical', 640], ['DS-203', 'Meter box', 'Mechanical', 410], ['DS-204', 'Seal kit', 'Consumable', 25], ['DS-205', 'Junction box', 'Mechanical', 120]],
};

const blueprints: Blueprint[] = [centralStores, serviceCentre, distribution];

for (const bp of blueprints) {
  const c = compile(bp);
  if (!c.ok) throw new Error(`${bp.slug}: ${JSON.stringify(c.diagnostics.filter(d => d.severity === 'error'), null, 2)}`);
  const siteId = SITE_IDS[bp.slug as keyof typeof SITE_IDS];
  const ctx = { siteId, userId: admin, role: 'Admin' as const };

  await withSite(ctx, async tx => {
    await tx.query('INSERT INTO sites (id, slug, name, created_by) VALUES ($1,$2,$3,$4)', [siteId, bp.slug, bp.name, admin]);
    const v = (await tx.query(
      `INSERT INTO site_versions (site_id, config, content_hash, status, author_id, reason)
       VALUES ($1,$2,$3,'published',$4,'seeded from register') RETURNING id`,
      [siteId, bp, hashBlueprint(bp), admin])).rows[0].id;
    await tx.query(`INSERT INTO site_deployments (site_id, version_id, proof, deployed_by) VALUES ($1,$2,$3,$4)`,
      [siteId, v, { versionHash: hashBlueprint(bp), seeded: true }, admin]);
    await tx.query('UPDATE sites SET published_version_id = $2 WHERE id = $1', [siteId, v]);

    await tx.query(`INSERT INTO memberships (site_id, user_id, role) VALUES ($1,$2,'Admin')`, [siteId, admin]);
    for (const [uid, role] of people[bp.slug]) await tx.query('INSERT INTO memberships (site_id, user_id, role) VALUES ($1,$2,$3)', [siteId, uid, role]);

    const items: { id: string; price: number }[] = [];
    const rows = [...CATALOGUE[bp.slug], [`MARKER-${bp.slug}`, `MARKER-${bp.slug}`, 'Consumable', 1] as [string, string, string, number]];
    for (const [sku, name, category, price] of rows) {
      const qty = sku.startsWith('MARKER') ? 1 : 20 + Math.floor(Math.random() * 60);
      const id = (await tx.query(
        `INSERT INTO items (site_id, name, on_hand, data, created_under_version, created_by) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
        [siteId, name, qty, { sku, category, unit_price: price, reorder_level: 10 }, v, admin])).rows[0].id;
      await tx.query(
        `INSERT INTO stock_movements (site_id, item_id, kind, qty, reason, idempotency_key, actor_id) VALUES ($1,$2,'receive',$3,'opening balance',$4,$5)`,
        [siteId, id, qty, `seed-${randomUUID()}`, admin]);
      items.push({ id, price });
    }

    if (bp.workflows.request) {
      const member = people[bp.slug].find(p => p[1] === 'Member')![0];
      for (let i = 0; i < 10; i++) {
        const it = items[i % (items.length - 1)];
        const data: Record<string, unknown> = { unit_price: it.price };
        if (bp.slug === 'service-centre') Object.assign(data, { serial_no: `PCB-${24000 + i}`, fault: ['No power', 'Display dead', 'Relay chatter', 'Overheating'][i % 4], priority: ['low', 'normal', 'urgent'][i % 3] });
        if (bp.slug === 'distribution') Object.assign(data, { site_location: ['Ward 4', 'Sector 12', 'Plant gate', 'Substation B'][i % 4] });
        const state = i % 2 ? 'submitted' : 'draft';
        const r = (await tx.query(
          `INSERT INTO requests (site_id, item_id, qty, state, requested_by, data, created_under_version) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
          [siteId, it.id, 1 + (i % 4), state, member, data, v])).rows[0].id;
        await tx.query(
          `INSERT INTO audit_events (site_id, entity, record_id, kind, actor_id, actor_role, after, version_id) VALUES ($1,'request',$2,'create',$3,'Member',$4,$5)`,
          [siteId, r, member, data, v]);
      }
    }
  });
  console.log(`seeded ${bp.slug}`);
}
await pool.end();
console.log('done. login: admin@axel.dev / demo1234');
'@

Write-Host ''
Write-Host 'All files created. Next: pnpm install'