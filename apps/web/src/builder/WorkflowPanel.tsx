import { useEffect, useState } from 'react';
import { parse, type Blueprint, type Role, type Workflow } from '@axel/compiler';

const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v));
const ROLES: Role[] = ['Member', 'Manager', 'Admin'];

function GuardInput({ value, onCommit }: { value?: string; onCommit: (g?: string) => void }) {
  const [v, setV] = useState(value ?? '');
  useEffect(() => { setV(value ?? ''); }, [value]);
  let err = '';
  if (v.trim()) { try { parse(v); } catch (e) { err = (e as Error).message; } }
  return (
    <div>
      <input value={v} onChange={e => setV(e.target.value)} placeholder="Rule (optional), e.g. qty <= 50"
        onBlur={() => { if (!err && v.trim() !== (value ?? '')) onCommit(v.trim() || undefined); }}
        onKeyDown={e => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur(); }}
        className={`w-full rounded border px-2 py-1 font-mono text-xs ${err ? 'border-red-400' : ''}`} />
      {err && <div className="text-[10px] text-red-600">{err}</div>}
    </div>
  );
}

export function WorkflowPanel({ bp, update }: { bp: Blueprint; update: (b: Blueprint) => void }) {
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [label, setLabel] = useState('');
  const wf = bp.workflows.request;
  if (!wf) return <div className="text-sm text-slate-500">This site has no request workflow. Add the Request module first.</div>;
  const set = (fn: (w: Workflow) => void) => { const next = clone(bp); fn(next.workflows.request); update(next); };
  const nextId = `t${Math.max(0, ...wf.transitions.map(t => Number(t.id.replace(/\D/g, '')) || 0)) + 1}`;
  const addStep = () => {
    const target = to.trim().toLowerCase().replace(/[^a-z0-9_]+/g, '_');
    if (!from || !target) return;
    set(w => {
      if (!w.states.includes(target)) { w.states.push(target); w.terminal.push(target); }
      w.transitions.push({ id: nextId, from, to: target, label: label || target, roles: ['Manager', 'Admin'] });
    });
    setLabel(''); setTo('');
  };

  return (
    <div className="space-y-3 text-sm">
      <div className="text-slate-600">Steps of the request workflow. Choose who may take each step, or add a rule such as <code className="font-mono">qty &lt;= 50</code>. Run Impact to see how past requests would be affected.</div>
      <div className="flex flex-wrap gap-1 text-xs">
        {wf.states.map(s => (
          <span key={s} className={`rounded px-1.5 py-0.5 ${s === wf.initial ? 'bg-sky-100' : wf.terminal.includes(s) ? 'bg-slate-200' : 'bg-slate-100'}`}>{s}</span>
        ))}
      </div>
      {wf.transitions.map((t, idx) => (
        <div key={t.id} className="space-y-1.5 rounded-lg border p-2">
          <div className="flex items-center gap-2">
            <input value={t.label ?? ''} onChange={e => set(w => { w.transitions[idx].label = e.target.value; })} className="w-28 rounded border px-1.5 py-0.5 text-xs font-medium" />
            <span className="font-mono text-xs text-slate-500">{t.from} &rarr; {t.to}</span>
            <span className="ml-auto font-mono text-[10px] text-slate-400">{t.id}</span>
            <button onClick={() => set(w => { w.transitions.splice(idx, 1); })} className="text-xs text-red-600">remove</button>
          </div>
          <div className="flex gap-3 text-xs">
            {ROLES.map(r => (
              <label key={r} className="flex items-center gap-1">
                <input type="checkbox" checked={t.roles.includes(r)} onChange={() => set(w => {
                  const x = w.transitions[idx];
                  x.roles = x.roles.includes(r) ? x.roles.filter(y => y !== r) : [...x.roles, r];
                })} />{r}
              </label>
            ))}
          </div>
          <GuardInput value={t.guard} onCommit={g => set(w => { if (g) w.transitions[idx].guard = g; else delete w.transitions[idx].guard; })} />
          {!!t.actions?.length && <div className="font-mono text-[10px] text-slate-500">does: {t.actions.join('; ')}</div>}
        </div>
      ))}
      <div className="space-y-2 rounded-lg border border-dashed p-2">
        <div className="text-xs font-medium">Add a step</div>
        <div className="grid grid-cols-3 gap-2">
          <select value={from} onChange={e => setFrom(e.target.value)} className="rounded border px-1 py-1 text-xs">
            <option value="">from...</option>
            {wf.states.map(s => <option key={s}>{s}</option>)}
          </select>
          <input list="axel-states" value={to} onChange={e => setTo(e.target.value)} placeholder="to (state)" className="rounded border px-1 py-1 text-xs" />
          <input value={label} onChange={e => setLabel(e.target.value)} placeholder="Label" className="rounded border px-1 py-1 text-xs" />
        </div>
        <datalist id="axel-states">{wf.states.map(s => <option key={s} value={s} />)}</datalist>
        <button onClick={addStep} disabled={!from || !to.trim()} className="rounded-md bg-slate-900 px-3 py-1 text-xs text-white disabled:opacity-40">Add step</button>
      </div>
    </div>
  );
}
