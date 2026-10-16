import { useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { parse, evaluate } from '@axel/compiler';
import { site, errOf, type ApiErr } from '../api';
import { useSite } from '../hooks';
import { Input, Denial, btn, btnGhost, money } from './fields';

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
    <form onSubmit={e => { e.preventDefault(); setErr(null); m.mutate(); }} className="space-y-3 rounded-site border bg-white p-4 shadow-sm">
      <h3 className="font-semibold">{initial ? 'Edit' : 'New'} {ent.label}</h3>
      <div className="grid gap-3 sm:grid-cols-2">
        {editable.map(f => (
          <label key={f.key} className="block">
            <span className="mb-1 block text-xs font-medium text-slate-600">{f.label}{f.required ? ' *' : ''}</span>
            <Input field={f} value={vals[f.key]} onChange={v => setVals(s => ({ ...s, [f.key]: v }))} />
            {fieldErr(f.key) && <span className="text-xs text-red-600">{fieldErr(f.key)}</span>}
          </label>
        ))}
      </div>
      {formulas.map(f => {
        let v: unknown = null;
        try { v = evaluate(parse(f.expr!), scope); } catch { v = null; }
        const shown = typeof v === 'number' && Number.isFinite(v) ? (f.expr?.includes('price') ? money(v) : String(Math.round(v * 100) / 100)) : '-';
        return (
          <div key={f.key} className="flex items-center justify-between rounded-site bg-primary/5 px-3 py-2 text-sm">
            <span>{f.label} <span className="font-mono text-xs text-slate-400">= {f.expr}</span></span>
            <b>{shown}</b>
          </div>
        );
      })}
      {err && <Denial err={err} />}
      <div className="flex gap-2">
        <button disabled={m.isPending} className={btn}>{m.isPending ? 'Saving...' : 'Save'}</button>
        {onCancel && <button type="button" onClick={onCancel} className={btnGhost}>Cancel</button>}
      </div>
    </form>
  );
}
