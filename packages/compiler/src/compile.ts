import { z, type ZodTypeAny } from 'zod';
import type { Blueprint, Diagnostic, Entity, Field, Role } from './types';
import { ROLES } from './types';
import { parse, evaluate, refs, ExprError, type Node } from './expr';
import { REGISTRY } from './registry';
import { portDiagnostics } from './ports';

export const RANK: Record<Role, number> = { Public: 0, Member: 1, Manager: 2, Admin: 3 };
export const atLeast = (r: Role, min: Role) => RANK[r] >= RANK[min];
export const canRead = (f: Field, r: Role) => !f.roles?.read || f.roles.read.includes(r);
export const canWrite = (f: Field, r: Role) =>
  f.type !== 'formula' && !f.system && (f.roles?.write ? f.roles.write.includes(r) : atLeast(r, 'Member'));

const META = new Set(['id', 'state', 'row_version', 'created_at', 'updated_at']);
const GUARD_CALLS = new Set(['stock.available', 'stock.on_hand', 'now']);
const ACTION_CALLS = new Set(['stock.reserve', 'stock.commit', 'stock.release', 'stock.consume', 'stock.return', 'repair.open', 'repair.close', 'notify']);

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
  out.push(...portDiagnostics(bp));
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
