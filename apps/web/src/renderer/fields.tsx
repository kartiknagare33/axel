import type { ReactNode } from 'react';
import { AlertTriangle, Inbox } from 'lucide-react';
import { useList, useSite, type Schema } from '../hooks';
import type { ApiErr } from '../api';

export type F = Schema['entities'][string]['fields'][number];

export const btn = 'inline-flex items-center justify-center gap-1.5 rounded-lg bg-primary px-3.5 py-2 text-sm font-medium text-white shadow-sm transition hover:brightness-110 active:brightness-95 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40';
export const btnGhost = 'inline-flex items-center justify-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3.5 py-2 text-sm font-medium text-slate-700 shadow-sm transition hover:bg-slate-50 hover:text-slate-900 disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/30';
export const inputBase = 'rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm transition placeholder:text-slate-400 focus:border-primary focus:outline-none focus:ring-4 focus:ring-primary/10';
export const inputCls = `w-full ${inputBase}`;
export const card = 'rounded-xl border border-slate-200/80 bg-white shadow-sm';

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });
export const money = (v: unknown) => inr.format(Number(v));
export const isNumeric = (f: F) => f.type === 'number' || f.type === 'money' || f.type === 'formula';

export const labelOf = (r: any): string =>
  r?.name ?? r?.serial_no ?? r?.sku ?? r?.site_location ?? r?.fault ?? (r?.id ? String(r.id).slice(0, 8) : '');

export function useLabels(target?: string) {
  const { siteId } = useSite();
  const q = useList(siteId, target ?? '', {}, !!target);
  const rows: any[] = q.data?.rows ?? [];
  const map = new Map<string, string>(rows.map(r => [r.id, labelOf(r)]));
  return { map, rows };
}

const TONE: Record<string, [string, string]> = {
  draft: ['bg-slate-100 text-slate-600 ring-slate-500/20', 'bg-slate-400'],
  submitted: ['bg-sky-50 text-sky-700 ring-sky-600/20', 'bg-sky-500'],
  approved: ['bg-emerald-50 text-emerald-700 ring-emerald-600/20', 'bg-emerald-500'],
  assigned: ['bg-violet-50 text-violet-700 ring-violet-600/20', 'bg-violet-500'],
  in_repair: ['bg-amber-50 text-amber-700 ring-amber-600/20', 'bg-amber-500'],
  open: ['bg-amber-50 text-amber-700 ring-amber-600/20', 'bg-amber-500'],
  closed: ['bg-slate-100 text-slate-700 ring-slate-600/20', 'bg-slate-500'],
  returned: ['bg-teal-50 text-teal-700 ring-teal-600/20', 'bg-teal-500'],
  rejected: ['bg-rose-50 text-rose-700 ring-rose-600/20', 'bg-rose-500'],
};
export const stateDot = (s: unknown) => TONE[String(s)]?.[1] ?? 'bg-primary';

export function StateBadge({ state }: { state: unknown }) {
  const s = String(state);
  const t = TONE[s];
  return (
    <span className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium capitalize ring-1 ring-inset ${t ? t[0] : 'bg-primary/10 text-primary ring-primary/20'}`}>
      <span className={`h-1.5 w-1.5 rounded-full ${t ? t[1] : 'bg-primary'}`} />
      {s.replace(/_/g, ' ')}
    </span>
  );
}

const CHIP: Record<string, string> = {
  urgent: 'bg-rose-50 text-rose-700 ring-rose-600/20',
  high: 'bg-rose-50 text-rose-700 ring-rose-600/20',
  normal: 'bg-slate-100 text-slate-600 ring-slate-500/20',
  low: 'bg-sky-50 text-sky-700 ring-sky-600/20',
};

function RelationCell({ to, value }: { to?: string; value: string }) {
  const { map } = useLabels(to);
  return <span className="text-slate-800">{map.get(value) ?? String(value).slice(0, 8)}</span>;
}

export function Cell({ field, value }: { field: F; value: unknown }): ReactNode {
  if (value == null || value === '') return <span className="text-slate-300">-</span>;
  if (field.key === 'state') return <StateBadge state={value} />;
  switch (field.type) {
    case 'relation': return <RelationCell to={field.to} value={String(value)} />;
    case 'money': return <span className="tabular">{money(value)}</span>;
    case 'formula': return <span className="tabular">{field.expr?.includes('price') ? money(value) : String(value)}</span>;
    case 'number': return <span className="tabular">{Number(value).toLocaleString('en-IN')}</span>;
    case 'boolean': return value ? <span className="font-medium text-emerald-700">Yes</span> : <span className="text-slate-400">No</span>;
    case 'date': return <>{new Date(String(value)).toLocaleDateString()}</>;
    case 'select': {
      const c = CHIP[String(value).toLowerCase()];
      return <span className={`inline-flex rounded-md px-1.5 py-0.5 text-xs font-medium ring-1 ring-inset ${c ?? 'bg-slate-50 text-slate-700 ring-slate-500/15'}`}>{String(value)}</span>;
    }
    default: return <>{String(value)}</>;
  }
}

function RelationSelect({ field, value, onChange }: { field: F; value: any; onChange: (v: any) => void }) {
  const { rows } = useLabels(field.to);
  return (
    <select value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls}>
      <option value="">Select...</option>
      {rows.map(r => (
        <option key={r.id} value={r.id}>{labelOf(r)}{r.available != null ? ` (${r.available} available)` : ''}</option>
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
    case 'boolean': return <input type="checkbox" checked={!!value} onChange={e => onChange(e.target.checked)} className="h-4 w-4 rounded border-slate-300" />;
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

export function Avatar({ name, size = 'sm' }: { name: unknown; size?: 'sm' | 'md' }) {
  const ini = String(name ?? '?').split(/\s+/).filter(Boolean).map(w => w[0]).join('').slice(0, 2).toUpperCase() || '?';
  return (
    <span className={`inline-flex shrink-0 items-center justify-center rounded-full bg-primary/10 font-semibold text-primary ${size === 'sm' ? 'h-7 w-7 text-[10px]' : 'h-9 w-9 text-xs'}`}>{ini}</span>
  );
}

export function PageHeader({ title, subtitle, actions }: { title: string; subtitle?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-slate-900">{title}</h1>
        {subtitle && <p className="mt-1 text-sm text-slate-500">{subtitle}</p>}
      </div>
      {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
    </div>
  );
}

export function EmptyState({ title, hint }: { title: string; hint?: string }) {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-14 text-center">
      <div className="flex h-12 w-12 items-center justify-center rounded-full bg-slate-100 text-slate-400"><Inbox className="h-6 w-6" /></div>
      <div className="mt-3 text-sm font-medium text-slate-700">{title}</div>
      {hint && <div className="mt-1 max-w-sm text-sm text-slate-500">{hint}</div>}
    </div>
  );
}

export function Skeleton({ rows = 5 }: { rows?: number }) {
  return (
    <div className={`${card} space-y-3 p-5`}>
      {Array.from({ length: rows }, (_, i) => <div key={i} className="h-9 animate-pulse rounded-lg bg-slate-100" />)}
    </div>
  );
}

export function Denial({ err }: { err: ApiErr }) {
  return (
    <div className="flex gap-3 rounded-xl border border-amber-200 bg-amber-50/70 px-4 py-3 text-sm text-amber-900">
      <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />
      <div>
        <div className="font-medium">{err.message}</div>
        {err.suggestion && <div className="mt-0.5 text-amber-800/80">{err.suggestion}</div>}
        {err.code && <div className="mt-1 font-mono text-[10px] uppercase tracking-wide text-amber-600/80">{err.code}</div>}
      </div>
    </div>
  );
}
