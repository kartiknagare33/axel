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
