import type { Blueprint, Field, Law } from './types';
import { parse, refs } from './expr';

export const LAW_TEMPLATES: { id: string; label: string }[] = [
  { id: 'hidden_from', label: 'A role never sees a field' },
  { id: 'requires_state', label: 'Assignments only come from requests in a state' },
  { id: 'reachable', label: 'A workflow state can be reached' },
  { id: 'non_negative', label: 'On-hand stock never goes below zero' },
  { id: 'reserved_le_on_hand', label: 'Reserved stock never exceeds on-hand' },
];

const entLabel = (bp: Blueprint, e: string) => bp.entities[e]?.label ?? e;
const fieldLabel = (bp: Blueprint, e: string, k: string) => bp.entities[e]?.fields.find(f => f.key === k)?.label ?? k;

export function lawSentence(l: Law, bp: Blueprint): string {
  const e = String(l.entity ?? '');
  switch (l.template) {
    case 'site_isolation': return `${bp.name || 'This site'} never reads or writes another site's data`;
    case 'non_negative': return `${fieldLabel(bp, e, String(l.field))} of ${entLabel(bp, e)} never goes below zero`;
    case 'reserved_le_on_hand': return 'Reserved stock never exceeds on-hand stock';
    case 'ledger_balanced': return 'Stock figures always equal the sum of the stock ledger';
    case 'requires_state': return `Every ${entLabel(bp, e)} comes from a request that was ${l.state}`;
    case 'hidden_from': return `${l.role}s never see ${fieldLabel(bp, e, String(l.field))} (${entLabel(bp, e)})`;
    case 'reachable': return `'${l.state}' can be reached in the ${l.workflow ?? 'request'} workflow`;
    default: return l.template;
  }
}

export interface LawCheck { id: string; template: string; sentence: string; passed: boolean; dynamic: boolean; detail?: string }

/** Checks every Law that can be decided from the Blueprint alone; marks the rest as dynamic (checked by the gate's walk). */
export function staticLaws(bp: Blueprint): LawCheck[] {
  const laws: Law[] = [...bp.laws];
  if (bp.entities.item && !laws.some(l => l.template === 'ledger_balanced')) laws.push({ id: 'l-ledger', template: 'ledger_balanced', locked: true });
  return laws.map(l => {
    const base = { id: l.id, template: l.template, sentence: lawSentence(l, bp) };
    const e = String(l.entity ?? '');
    switch (l.template) {
      case 'hidden_from': {
        const ent = bp.entities[e];
        const role = String(l.role);
        const f = ent?.fields.find(x => x.key === l.field);
        if (!ent || !f) return { ...base, passed: false, dynamic: false, detail: `There is no field '${l.field}' on '${e}'.` };
        const sees = (x: Field) => !x.roles?.read || (x.roles.read as string[]).includes(role);
        if (sees(f)) return { ...base, passed: false, dynamic: false, detail: `${role}s can currently see ${f.label ?? f.key}.` };
        const leak = ent.fields.find(x => {
          if (x.type !== 'formula' || !x.expr || !sees(x)) return false;
          try { return refs(parse(x.expr)).fields.has(f.key); } catch { return false; }
        });
        if (leak) return { ...base, passed: false, dynamic: false, detail: `${leak.label ?? leak.key} (= ${leak.expr}) is visible to ${role}s and reveals ${f.label ?? f.key}.` };
        return { ...base, passed: true, dynamic: false, detail: `${role}s cannot read it, and no visible calculated field reveals it.` };
      }
      case 'reachable': {
        const wf = bp.workflows[String(l.workflow ?? 'request')];
        if (!wf) return { ...base, passed: false, dynamic: false, detail: 'That workflow does not exist.' };
        const seen = new Set([wf.initial]);
        const q = [wf.initial];
        while (q.length) {
          const s = q.shift()!;
          for (const t of wf.transitions) if (t.from === s && !seen.has(t.to)) { seen.add(t.to); q.push(t.to); }
        }
        return seen.has(String(l.state))
          ? { ...base, passed: true, dynamic: false, detail: 'A path exists from the first state.' }
          : { ...base, passed: false, dynamic: false, detail: `No sequence of steps leads from '${wf.initial}' to '${l.state}'.` };
      }
      case 'requires_state': {
        if (!bp.entities[e]) return { ...base, passed: true, dynamic: false, detail: `Not active: this site has no ${e}.` };
        if (!bp.workflows.request?.states.includes(String(l.state)))
          return { ...base, passed: false, dynamic: false, detail: `The request workflow has no '${l.state}' state.` };
        return { ...base, passed: true, dynamic: true };
      }
      default:
        return { ...base, passed: true, dynamic: true };
    }
  });
}
