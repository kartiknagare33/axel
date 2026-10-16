import type { ReactNode } from 'react';
import { useList, useSite, type Schema } from '../hooks';
import type { ApiErr } from '../api';

export type F = Schema['entities'][string]['fields'][number];

export const btn = 'rounded-site bg-primary px-3 py-1.5 text-sm font-medium text-white hover:opacity-90 disabled:opacity-50';
export const btnGhost = 'rounded-site border border-slate-300 bg-white px-3 py-1.5 text-sm hover:bg-slate-50 disabled:opacity-50';
const inputCls = 'w-full rounded-site border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary/40';

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });
export const money = (v: unknown) => inr.format(Number(v));

export const labelOf = (r: any): string =>
  r?.name ?? r?.serial_no ?? r?.sku ?? r?.site_location ?? r?.fault ?? (r?.id ? String(r.id).slice(0, 8) : '');

export function useLabels(target?: string) {
  const { siteId } = useSite();
  const q = useList(siteId, target ?? '', {}, !!target);
  const rows: any[] = q.data?.rows ?? [];
  const map = new Map<string, string>(rows.map(r => [r.id, labelOf(r)]));
  return { map, rows };
}

export function StateBadge({ state }: { state: unknown }) {
  return (
    <span className="inline-block rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
      {String(state).replace(/_/g, ' ')}
    </span>
  );
}

function RelationCell({ to, value }: { to?: string; value: string }) {
  const { map } = useLabels(to);
  return <>{map.get(value) ?? String(value).slice(0, 8)}</>;
}

export function Cell({ field, value }: { field: F; value: unknown }): ReactNode {
  if (value == null || value === '') return <span className="text-slate-300">-</span>;
  if (field.key === 'state') return <StateBadge state={value} />;
  switch (field.type) {
    case 'relation': return <RelationCell to={field.to} value={String(value)} />;
    case 'money': return <>{money(value)}</>;
    case 'formula': return <>{field.expr?.includes('price') ? money(value) : String(value)}</>;
    case 'boolean': return <>{value ? 'Yes' : 'No'}</>;
    case 'date': return <>{new Date(String(value)).toLocaleDateString()}</>;
    default: return <>{String(value)}</>;
  }
}

function RelationSelect({ field, value, onChange }: { field: F; value: any; onChange: (v: any) => void }) {
  const { rows } = useLabels(field.to);
  return (
    <select value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls}>
      <option value="">Select...</option>
      {rows.map(r => (
        <option key={r.id} value={r.id}>
          {labelOf(r)}{r.available != null ? ` (${r.available} available)` : ''}
        </option>
      ))}
    </select>
  );
}

export function Input({ field, value, onChange }: { field: F; value: any; onChange: (v: any) => void }) {
  switch (field.type) {
    case 'select':
      return (
        <select value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls}>
          <option value="">Select...</option>
          {field.options?.map(o => <option key={o} value={o}>{o}</option>)}
        </select>
      );
    case 'relation': return <RelationSelect field={field} value={value} onChange={onChange} />;
    case 'boolean': return <input type="checkbox" checked={!!value} onChange={e => onChange(e.target.checked)} className="h-4 w-4" />;
    case 'number':
    case 'money':
      return <input type="number" step="any" min={field.min} max={field.max} value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls} />;
    case 'date': return <input type="date" value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls} />;
    default: return <input value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls} />;
  }
}

export function columnFields(ent: Schema['entities'][string], columns?: string[]): F[] {
  const by = new Map(ent.fields.map(f => [f.key, f]));
  const keys = columns ?? ent.fields.map(f => f.key);
  return keys
    .map(k => by.get(k) ?? (k === 'state' ? ({ key: 'state', type: 'text', label: 'State', readonly: true } as F) : null))
    .filter(Boolean) as F[];
}

export function Denial({ err }: { err: ApiErr }) {
  return (
    <div className="rounded-site border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
      <div className="font-medium">{err.message}</div>
      {err.suggestion && <div className="text-amber-700">{err.suggestion}</div>}
      {err.code && <div className="mt-1 font-mono text-[10px] text-amber-600">{err.code}</div>}
    </div>
  );
}
