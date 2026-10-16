import { useState } from 'react';
import { lawSentence, LAW_TEMPLATES, type Blueprint, type Field } from '@axel/compiler';

const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v));

export function LawsPanel({ bp, update }: { bp: Blueprint; update: (b: Blueprint) => void }) {
  const [t, setT] = useState('hidden_from');
  const [entity, setEntity] = useState(Object.keys(bp.entities)[0] ?? 'item');
  const [field, setField] = useState('');
  const [role, setRole] = useState('Member');
  const [state, setState] = useState('approved');
  const states = bp.workflows.request?.states ?? [];
  const fields = bp.entities[entity]?.fields.filter(f => !f.system) ?? [];
  const nextId = () => `l${Math.max(0, ...bp.laws.map(l => Number(String(l.id).replace(/\D/g, '')) || 0)) + 1}`;

  const add = () => {
    let law: Record<string, unknown>;
    switch (t) {
      case 'hidden_from': law = { template: t, entity, field: field || fields[0]?.key, role }; break;
      case 'requires_state': law = { template: t, entity: bp.entities.assignment ? 'assignment' : 'repair', ref: 'request_id', state }; break;
      case 'reachable': law = { template: t, workflow: 'request', state }; break;
      case 'non_negative': law = { template: t, entity: 'item', field: 'on_hand' }; break;
      default: law = { template: t, entity: 'item' };
    }
    update({ ...bp, laws: [...bp.laws, { id: nextId(), ...law } as any] });
  };

  return (
    <div className="space-y-4 text-sm">
      <div className="text-slate-600">Laws are rules this site must never break. The Release Gate proves them before every publish.</div>
      <div className="space-y-1.5">
        {bp.laws.map(l => (
          <div key={l.id} className="flex items-start justify-between gap-2 rounded border p-2">
            <div>
              <div>{lawSentence(l, bp)}</div>
              <div className="font-mono text-[10px] text-slate-400">{l.id} - {l.template}</div>
            </div>
            {l.locked
              ? <span className="text-[10px] uppercase text-slate-400">locked</span>
              : <button onClick={() => update({ ...bp, laws: bp.laws.filter(x => x.id !== l.id) })} className="text-xs text-red-600">remove</button>}
          </div>
        ))}
      </div>
      <div className="space-y-2 rounded-lg border p-3">
        <div className="font-medium">Add a Law</div>
        <select value={t} onChange={e => setT(e.target.value)} className="w-full rounded border px-2 py-1.5">
          {LAW_TEMPLATES.map(x => <option key={x.id} value={x.id}>{x.label}</option>)}
        </select>
        {t === 'hidden_from' && (
          <div className="grid grid-cols-3 gap-2">
            <select value={role} onChange={e => setRole(e.target.value)} className="rounded border px-2 py-1">
              {['Public', 'Member', 'Manager'].map(r => <option key={r}>{r}</option>)}
            </select>
            <select value={entity} onChange={e => { setEntity(e.target.value); setField(''); }} className="rounded border px-2 py-1">
              {Object.keys(bp.entities).map(k => <option key={k}>{k}</option>)}
            </select>
            <select value={field} onChange={e => setField(e.target.value)} className="rounded border px-2 py-1">
              {fields.map(f => <option key={f.key} value={f.key}>{f.label ?? f.key}</option>)}
            </select>
          </div>
        )}
        {(t === 'requires_state' || t === 'reachable') && (
          <select value={state} onChange={e => setState(e.target.value)} className="w-full rounded border px-2 py-1">
            {states.map(s => <option key={s}>{s}</option>)}
          </select>
        )}
        <button onClick={add} className="rounded-md bg-slate-900 px-3 py-1 text-xs text-white">Add Law</button>
      </div>
    </div>
  );
}

/** One-click toggle: can Members read this field? Used in the field list to demonstrate Laws. */
export function RoleToggle({ bp, entity, field, update }: { bp: Blueprint; entity: string; field: Field; update: (b: Blueprint) => void }) {
  if (field.system) return null;
  const hidden = !!field.roles?.read && !(field.roles.read as string[]).includes('Member');
  const toggle = () => {
    const next = clone(bp);
    const f = next.entities[entity].fields.find(x => x.key === field.key)!;
    if (hidden) f.roles = { ...f.roles, read: [...(f.roles?.read ?? []), 'Member'] };
    else f.roles = { ...(f.roles ?? {}), read: ['Manager', 'Admin'] };
    update(next);
  };
  return (
    <button onClick={toggle} title="Can Members see this field?"
      className={`ml-2 shrink-0 rounded px-1.5 text-[10px] ${hidden ? 'bg-slate-200 text-slate-600' : 'bg-amber-100 text-amber-800'}`}>
      {hidden ? 'Member: hidden' : 'Member: sees'}
    </button>
  );
}
