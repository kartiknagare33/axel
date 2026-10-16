import { useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { parse, evaluate } from '@axel/compiler';
import { site, errOf, type ApiErr } from '../api';
import { useSite } from '../hooks';
import { Input, Denial, btn, btnGhost, money, card } from './fields';

export function RecordForm({ entity, initial, onDone, onCancel }: {
  entity: string; initial?: any; onDone?: (rec: any) => void; onCancel?: () => void;
}) {
  const { siteId, schema } = useSite();
  const qc = useQueryClient();
  const ent = schema.entities[entity];
  const editable = ent.fields.filter(f => !f.readonly);
  const formulas = ent.fields.filter(f => f.type === 'formula');
  const [vals, setVals] = useState<Record<string, any>>(() =>
    Object.fromEntries(editable.map(f => [f.key, initial?.[f.key] ?? (f.type === 'boolean' ? false : '')])));
  const [err, setErr] = useState<ApiErr | null>(null);

  const m = useMutation({
    mutationFn: () => {
      const body: Record<string, unknown> = {};
      for (const f of editable) {
        const v = vals[f.key];
        if (initial) { if (v !== (initial[f.key] ?? '')) body[f.key] = v === '' ? null : v; }
        else if (v !== '' && v != null) body[f.key] = v;
      }
      return initial
        ? site.patch(siteId, `/${entity}/${initial.id}`, { ...body, ifVersion: initial.row_version })
        : site.post(siteId, `/${entity}`, body);
    },
    onSuccess: rec => { qc.invalidateQueries({ queryKey: [entity, siteId] }); onDone?.(rec); },
    onError: e => setErr(errOf(e)),
  });

  const scope = { get: (k: string) => (vals[k] !== undefined && vals[k] !== '' ? vals[k] : initial?.[k]) };
  const fieldErr = (k: string) => err?.errors?.find(e => e.field === k)?.message;

  return (
    <form onSubmit={e => { e.preventDefault(); setErr(null); m.mutate(); }} className={`${card} overflow-hidden`}>
      <div className="border-b border-slate-100 px-5 py-4">
        <h3 className="text-base font-semibold text-slate-900">{initial ? 'Edit' : 'New'} {ent.label}</h3>
        <p className="mt-0.5 text-sm text-slate-500">{initial ? 'Changes are checked against this unit before they are saved.' : 'Fields marked * are required.'}</p>
      </div>
      <div className="grid gap-x-5 gap-y-4 px-5 py-5 sm:grid-cols-2">
        {editable.map(f => (
          <label key={f.key} className={f.type === 'boolean' ? 'flex items-center gap-2 pt-6' : 'block'}>
            {f.type === 'boolean'
              ? <><Input field={f} value={vals[f.key]} onChange={v => setVals(s => ({ ...s, [f.key]: v }))} /><span className="text-sm text-slate-700">{f.label}</span></>
              : <>
                  <span className="mb-1.5 block text-sm font-medium text-slate-700">{f.label}{f.required ? <span className="text-rose-500"> *</span> : ''}</span>
                  <Input field={f} value={vals[f.key]} onChange={v => setVals(s => ({ ...s, [f.key]: v }))} />
                </>}
            {fieldErr(f.key) && <span className="mt-1 block text-xs text-rose-600">{fieldErr(f.key)}</span>}
          </label>
        ))}
      </div>
      {!!formulas.length && (
        <div className="flex flex-wrap gap-2 px-5 pb-5">
          {formulas.map(f => {
            let v: unknown = null;
            try { v = evaluate(parse(f.expr!), scope); } catch { v = null; }
            const shown = typeof v === 'number' && Number.isFinite(v) ? (f.expr?.includes('price') ? money(v) : String(Math.round(v * 100) / 100)) : '-';
            return (
              <div key={f.key} className="flex items-center gap-3 rounded-lg bg-primary/5 px-3 py-2 text-sm ring-1 ring-inset ring-primary/10">
                <span className="text-slate-600">{f.label}</span>
                <span className="font-mono text-xs text-slate-400">= {f.expr}</span>
                <span className="tabular font-semibold text-slate-900">{shown}</span>
              </div>
            );
          })}
        </div>
      )}
      {err && <div className="px-5 pb-4"><Denial err={err} /></div>}
      <div className="flex justify-end gap-2 border-t border-slate-100 bg-slate-50/60 px-5 py-3">
        {onCancel && <button type="button" onClick={onCancel} className={btnGhost}>Cancel</button>}
        <button disabled={m.isPending} className={btn}>{m.isPending ? 'Saving...' : 'Save'}</button>
      </div>
    </form>
  );
}
