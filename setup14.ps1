# Axel - UI redesign (font, icons, layouts, views, record page, hub, login). Run from the axel folder.
$ErrorActionPreference = 'Stop'
function W([string]$Path, [string]$Content) {
  $full = Join-Path $PSScriptRoot $Path
  New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
  $text = $Content.Replace("`r`n", "`n").TrimStart("`n") + "`n"
  [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding $false))
  Write-Host "created $Path"
}
function Patch([string]$Path, [string]$Old, [string]$New) {
  $full = Join-Path $PSScriptRoot $Path
  $text = [System.IO.File]::ReadAllText($full).Replace("`r`n", "`n")
  $Old = $Old.Replace("`r`n", "`n"); $New = $New.Replace("`r`n", "`n")
  if ($text.Contains($New)) { Write-Host "already patched $Path"; return }
  if (-not $text.Contains($Old)) { throw "patch target not found in $Path" }
  [System.IO.File]::WriteAllText($full, $text.Replace($Old, $New), (New-Object System.Text.UTF8Encoding $false))
  Write-Host "patched $Path"
}

# ============================== deps + font ==============================
Patch 'apps/web/package.json' @'
    "axios": "^1.7.7",
'@ @'
    "@fontsource-variable/inter": "^5.1.0",
    "axios": "^1.7.7",
    "lucide-react": "^0.460.0",
'@

Patch 'apps/web/src/main.tsx' @'
import './index.css';
'@ @'
import '@fontsource-variable/inter';
import './index.css';
'@

W 'apps/web/src/index.css' @'
@import "tailwindcss";

/* Site theme tokens arrive as CSS variables set by SiteShell */
@theme inline {
  --color-primary: var(--primary, #4f46e5);
  --color-surface: var(--surface, #f8fafc);
  --radius-site: var(--radius, 10px);
  --font-sans: 'Inter Variable', ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif;
}

html, body { margin: 0; }
body {
  font-family: 'Inter Variable', ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif;
  color: #0f172a;
  background: #f8fafc;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
  font-feature-settings: 'cv11', 'ss01';
}
.tabular { font-variant-numeric: tabular-nums; }
::selection { background: rgba(99, 102, 241, 0.18); }
*::-webkit-scrollbar { width: 10px; height: 10px; }
*::-webkit-scrollbar-thumb { background: #cbd5e1; border-radius: 999px; border: 3px solid transparent; background-clip: content-box; }
*::-webkit-scrollbar-thumb:hover { background: #94a3b8; border: 3px solid transparent; background-clip: content-box; }
*::-webkit-scrollbar-track { background: transparent; }
'@

# ============================== shared UI pieces ==============================
W 'apps/web/src/renderer/fields.tsx' @'
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
'@

# ============================== views ==============================
W 'apps/web/src/renderer/views.tsx' @'
import { useMemo, useState, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Activity, ArrowRight, Hash, Package, Plus, Search, TrendingUp } from 'lucide-react';
import {
  ResponsiveContainer, BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  PieChart, Pie, Cell as Slice, LineChart, Line, Legend,
} from 'recharts';
import type { Page, Widget } from '@axel/compiler';
import { site, errOf } from '../api';
import { useList, useSite, RANK } from '../hooks';
import {
  Cell, columnFields, Denial, btn, money, card, PageHeader, EmptyState, Skeleton, isNumeric, Avatar, inputBase, type F,
} from './fields';
import { RecordForm } from './RecordForm';
import { KanbanBoard } from './kanban';
import { ExcelBar } from './excel';

function useDense() {
  const { schema } = useSite();
  return schema.theme.density === 'compact';
}
function canCreate(entity?: string) {
  const { schema } = useSite();
  return !!entity && RANK[schema.role] >= 1 && !!schema.entities[entity]?.fields.some(f => !f.readonly);
}
function useCreator(entity?: string) {
  const [open, setOpen] = useState(false);
  const allowed = canCreate(entity);
  return {
    newButton: allowed ? <button onClick={() => setOpen(v => !v)} className={btn}><Plus className="h-4 w-4" />New</button> : null,
    form: open && entity ? <RecordForm entity={entity} onDone={() => setOpen(false)} onCancel={() => setOpen(false)} /> : null,
  };
}
function useFiltered(rows: any[], cols: F[]) {
  const [query, setQuery] = useState('');
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter(r => cols.some(c => String(r[c.key] ?? '').toLowerCase().includes(q)));
  }, [rows, cols, query]);
  return { query, setQuery, filtered };
}
function SearchBox({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <div className="relative">
      <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
      <input value={value} onChange={e => onChange(e.target.value)} placeholder="Search" className={`${inputBase} w-56 pl-9`} />
    </div>
  );
}

export function TableView({ page }: { page: Page }) {
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const dense = useDense();
  const entity = page.entity!;
  const ent = schema.entities[entity];
  const q = useList(siteId, entity, page.filter ? { filter: page.filter } : {});
  const c = useCreator(entity);
  const cols = columnFields(ent, page.columns);
  const rows: any[] = q.data?.rows ?? [];
  const { query, setQuery, filtered } = useFiltered(rows, cols);
  const pad = dense ? 'px-4 py-2' : 'px-4 py-3';
  return (
    <div className="space-y-5">
      <PageHeader title={page.title} subtitle={`${q.data?.total ?? 0} records`} actions={<><SearchBox value={query} onChange={setQuery} />{c.newButton}</>} />
      {c.form}
      <ExcelBar entity={entity} />
      {q.isLoading ? <Skeleton /> : q.error ? <Denial err={errOf(q.error)} /> : (
        <div className={`${card} overflow-hidden`}>
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead>
                <tr className="border-b border-slate-200 bg-slate-50/70">
                  {cols.map(col => (
                    <th key={col.key} className={`${pad} whitespace-nowrap text-[11px] font-semibold uppercase tracking-wider text-slate-500 ${isNumeric(col) ? 'text-right' : ''}`}>{col.label}</th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {filtered.map(r => (
                  <tr key={r.id} onClick={() => nav(`${base}/r/${entity}/${r.id}`)} className="cursor-pointer transition hover:bg-slate-50/80">
                    {cols.map((col, i) => (
                      <td key={col.key} className={`${pad} whitespace-nowrap ${isNumeric(col) ? 'text-right' : ''} ${i === 0 ? 'font-medium text-slate-900' : 'text-slate-600'}`}>
                        <Cell field={col} value={r[col.key]} />
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {!filtered.length && <EmptyState title={query ? 'No matches' : 'Nothing here yet'} hint={query ? 'Try a different search.' : 'Records you add will appear here.'} />}
        </div>
      )}
    </div>
  );
}

export function QueueView({ page }: { page: Page }) {
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const entity = page.entity!;
  const ent = schema.entities[entity];
  const q = useList(siteId, entity);
  const cols = columnFields(ent, page.columns).filter(c => c.key !== 'assigned_to');
  const rows: any[] = q.data?.rows ?? [];
  const { query, setQuery, filtered } = useFiltered(rows, cols);
  return (
    <div className="space-y-5">
      <PageHeader title={page.title} subtitle={`${q.data?.total ?? 0} in the queue`} actions={<SearchBox value={query} onChange={setQuery} />} />
      {q.isLoading ? <Skeleton /> : q.error ? <Denial err={errOf(q.error)} /> : (
        <div className="space-y-3">
          {filtered.map(r => (
            <div key={r.id} className={`${card} flex items-center gap-4 p-4 transition hover:shadow-md`}>
              <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary"><Package className="h-5 w-5" /></div>
              <div className="min-w-0 flex-1">
                <div className="font-medium text-slate-900">{cols[0] ? <Cell field={cols[0]} value={r[cols[0].key]} /> : String(r.id).slice(0, 8)}</div>
                <div className="mt-1 flex flex-wrap gap-x-5 gap-y-1 text-sm text-slate-500">
                  {cols.slice(1).map(col => (
                    <span key={col.key}><span className="text-slate-400">{col.label}</span> <span className="text-slate-700"><Cell field={col} value={r[col.key]} /></span></span>
                  ))}
                </div>
              </div>
              {r.assigned_to
                ? <div className="hidden items-center gap-2 text-sm text-slate-700 sm:flex"><Avatar name={r.assigned_to} />{r.assigned_to}</div>
                : <span className="hidden rounded-full bg-amber-50 px-2.5 py-1 text-xs font-medium text-amber-700 ring-1 ring-inset ring-amber-600/20 sm:inline">Unassigned</span>}
              <button onClick={() => nav(`${base}/r/${entity}/${r.id}`)} className={btn}>Open<ArrowRight className="h-4 w-4" /></button>
            </div>
          ))}
          {!filtered.length && (
            <div className={card}><EmptyState title={query ? 'No matches' : 'The queue is empty'} hint={query ? 'Try a different search.' : 'Approved requests appear here once a Manager assigns them.'} /></div>
          )}
        </div>
      )}
    </div>
  );
}

function useWidget(w: Widget) {
  const { siteId } = useSite();
  return useQuery({ queryKey: ['analytics', siteId, w.id], queryFn: () => site.get(siteId, `/analytics/${w.id}`) });
}
const isMoneyWidget = (w: Widget) => !!w.field && /price|value|total|cost/.test(w.field);

function StatCard({ w }: { w: Widget }) {
  const q = useWidget(w);
  const data: { key: string; value: number }[] = q.data?.data ?? [];
  const total = data.reduce((a, b) => a + b.value, 0);
  return (
    <div className={`${card} p-5`}>
      <div className="flex items-center justify-between">
        <div className="text-sm font-medium text-slate-500">{w.title ?? w.id}</div>
        <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-primary/10 text-primary"><Hash className="h-4 w-4" /></div>
      </div>
      {q.isLoading ? <div className="mt-3 h-9 w-32 animate-pulse rounded-lg bg-slate-100" />
        : q.error ? <div className="mt-3"><Denial err={errOf(q.error)} /></div>
        : <div className="tabular mt-2 text-3xl font-semibold tracking-tight text-slate-900">{isMoneyWidget(w) ? money(total) : total.toLocaleString('en-IN')}</div>}
    </div>
  );
}

const axis = { fontSize: 12, fill: '#94a3b8' };
function ChartCard({ w }: { w: Widget }) {
  const { schema } = useSite();
  const color = schema.theme.tokens.primary;
  const q = useWidget(w);
  const data: { key: string; value: number }[] = q.data?.data ?? [];
  let chart: ReactNode;
  if (w.type === 'pie') chart = (
    <PieChart>
      <Pie data={data} dataKey="value" nameKey="key" innerRadius={55} outerRadius={90} paddingAngle={2} stroke="none">
        {data.map((_, i) => <Slice key={i} fill={color} fillOpacity={1 - i * (0.65 / Math.max(data.length, 1))} />)}
      </Pie>
      <Tooltip contentStyle={{ borderRadius: 10, border: '1px solid #e2e8f0', fontSize: 12 }} />
      <Legend iconType="circle" wrapperStyle={{ fontSize: 12 }} />
    </PieChart>
  );
  else if (w.type === 'line') chart = (
    <LineChart data={data}>
      <CartesianGrid stroke="#f1f5f9" vertical={false} />
      <XAxis dataKey="key" tick={axis} axisLine={false} tickLine={false} />
      <YAxis tick={axis} axisLine={false} tickLine={false} width={40} />
      <Tooltip contentStyle={{ borderRadius: 10, border: '1px solid #e2e8f0', fontSize: 12 }} />
      <Line dataKey="value" stroke={color} strokeWidth={2.5} dot={false} />
    </LineChart>
  );
  else chart = (
    <BarChart data={data}>
      <CartesianGrid stroke="#f1f5f9" vertical={false} />
      <XAxis dataKey="key" tick={axis} axisLine={false} tickLine={false} />
      <YAxis tick={axis} axisLine={false} tickLine={false} allowDecimals={false} width={40} />
      <Tooltip cursor={{ fill: '#f8fafc' }} contentStyle={{ borderRadius: 10, border: '1px solid #e2e8f0', fontSize: 12 }} />
      <Bar dataKey="value" fill={color} radius={[6, 6, 0, 0]} maxBarSize={44} />
    </BarChart>
  );
  return (
    <div className={`${card} p-5`}>
      <div className="mb-4 flex items-center justify-between">
        <div className="text-sm font-semibold text-slate-900">{w.title ?? w.id}</div>
        {w.type === 'line' ? <TrendingUp className="h-4 w-4 text-slate-400" /> : <Activity className="h-4 w-4 text-slate-400" />}
      </div>
      {q.isLoading ? <div className="h-64 animate-pulse rounded-lg bg-slate-100" />
        : q.error ? <Denial err={errOf(q.error)} />
        : <div className="h-64"><ResponsiveContainer width="100%" height="100%">{chart as any}</ResponsiveContainer></div>}
    </div>
  );
}

export function DashboardView({ page }: { page: Page }) {
  const widgets = page.widgets ?? [];
  const stats = widgets.filter(w => w.type === 'stat');
  const charts = widgets.filter(w => w.type !== 'stat');
  return (
    <div className="space-y-5">
      <PageHeader title={page.title} subtitle="Live figures for this unit" />
      {!!stats.length && <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">{stats.map(w => <StatCard key={w.id} w={w} />)}</div>}
      <div className="grid gap-4 lg:grid-cols-2">{charts.map(w => <ChartCard key={w.id} w={w} />)}</div>
    </div>
  );
}

export function PageView({ page }: { page: Page }) {
  const V = ({ table: TableView, kanban: KanbanBoard, queue: QueueView, dashboard: DashboardView } as Record<string, (p: { page: Page }) => JSX.Element>)[page.view] ?? TableView;
  return <V page={page} />;
}
'@

W 'apps/web/src/renderer/kanban.tsx' @'
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { GripVertical, Plus } from 'lucide-react';
import type { Page } from '@axel/compiler';
import { site, errOf, type ApiErr } from '../api';
import { useList, useSite, RANK } from '../hooks';
import { Cell, columnFields, Denial, labelOf, btn, PageHeader, stateDot, Skeleton } from './fields';
import { RecordForm } from './RecordForm';
import { ExcelBar } from './excel';

// Kanban grouped by workflow state. Dropping a card on a column runs the matching transition.
export function KanbanBoard({ page }: { page: Page }) {
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const qc = useQueryClient();
  const entity = page.entity!;
  const ent = schema.entities[entity];
  const wf = ent.workflow;
  const q = useList(siteId, entity);
  const [creating, setCreating] = useState(false);
  const [dragId, setDragId] = useState<string | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const [err, setErr] = useState<ApiErr | null>(null);
  const rows: any[] = q.data?.rows ?? [];
  const groupBy = page.groupBy ?? 'state';
  const states = wf?.states ?? [...new Set(rows.map(r => String(r[groupBy])))];
  const cols = columnFields(ent, page.columns);
  const canNew = RANK[schema.role] >= 1 && ent.fields.some(f => !f.readonly);
  const dragging = rows.find(r => r.id === dragId);
  const stepTo = (from: string, to: string) => wf?.transitions.find(t => t.from === from && t.to === to);

  const m = useMutation({
    mutationFn: ({ row, to }: { row: any; to: string }) => {
      const payload = to === 'assigned' ? { assigned_to: window.prompt('Assign to (name)') ?? '' } : undefined;
      return site.post(siteId, `/${entity}/${row.id}/transition`, { to, idempotencyKey: crypto.randomUUID(), ifVersion: row.row_version, payload });
    },
    onSuccess: () => { setErr(null); qc.invalidateQueries({ predicate: x => x.queryKey[1] === siteId }); },
    onError: e => setErr(errOf(e)),
  });

  function drop(col: string) {
    const row = dragging;
    setOver(null); setDragId(null);
    if (!row || String(row[groupBy]) === col) return;
    const t = stepTo(String(row[groupBy]), col);
    if (!t) return setErr({ message: `There is no step from '${row[groupBy]}' to '${col}' in this workflow.`, code: 'TRANSITION_NOT_ALLOWED' });
    if (!t.allowed) return setErr({ message: `Your role (${schema.role}) cannot ${t.label.toLowerCase()} here (transition ${t.id}).`, code: 'TRANSITION_NOT_ALLOWED' });
    m.mutate({ row, to: col });
  }

  return (
    <div className="space-y-5">
      <PageHeader
        title={page.title}
        subtitle={`${q.data?.total ?? 0} records - drag a card to another column to move it to that step`}
        actions={canNew ? <button onClick={() => setCreating(v => !v)} className={btn}><Plus className="h-4 w-4" />New</button> : undefined}
      />
      {creating && <RecordForm entity={entity} onDone={() => setCreating(false)} onCancel={() => setCreating(false)} />}
      <ExcelBar entity={entity} />
      {err && <Denial err={err} />}
      {q.isLoading && <Skeleton />}
      {q.error && <Denial err={errOf(q.error)} />}
      {!q.isLoading && !q.error && (
        <div className="-mx-6 overflow-x-auto px-6 pb-4">
          <div className="flex min-w-max gap-4">
            {states.map(s => {
              const inCol = rows.filter(r => String(r[groupBy]) === s);
              const t = dragging ? stepTo(String(dragging[groupBy]), s) : undefined;
              const ring = over === s ? (t?.allowed ? 'ring-2 ring-primary/60 bg-primary/5' : 'ring-2 ring-rose-300') : dragging && t?.allowed ? 'ring-1 ring-primary/30' : '';
              return (
                <div key={s}
                  onDragOver={e => { if (dragging) { e.preventDefault(); setOver(s); } }}
                  onDragLeave={() => setOver(o => (o === s ? null : o))}
                  onDrop={() => drop(s)}
                  className={`flex w-80 shrink-0 flex-col rounded-xl bg-slate-100/70 p-2.5 transition ${ring}`}>
                  <div className="mb-2.5 flex items-center justify-between px-1.5 pt-1">
                    <div className="flex items-center gap-2">
                      <span className={`h-2 w-2 rounded-full ${stateDot(s)}`} />
                      <span className="text-sm font-semibold capitalize text-slate-700">{s.replace(/_/g, ' ')}</span>
                    </div>
                    <span className="rounded-full bg-white px-2 py-0.5 text-xs font-medium text-slate-500 shadow-sm">{inCol.length}</span>
                  </div>
                  <div className="flex min-h-24 flex-1 flex-col gap-2">
                    {inCol.map(r => (
                      <div key={r.id} draggable
                        onDragStart={() => { setErr(null); setDragId(r.id); }}
                        onDragEnd={() => { setDragId(null); setOver(null); }}
                        onClick={() => nav(`${base}/r/${entity}/${r.id}`)}
                        className={`group cursor-grab rounded-lg border border-slate-200 bg-white p-3.5 shadow-sm transition hover:border-slate-300 hover:shadow-md active:cursor-grabbing ${dragId === r.id ? 'opacity-40' : ''}`}>
                        <div className="flex items-start justify-between gap-2">
                          <div className="text-sm font-medium text-slate-900">{labelOf(r)}</div>
                          <GripVertical className="h-4 w-4 shrink-0 text-slate-300 opacity-0 transition group-hover:opacity-100" />
                        </div>
                        <div className="mt-2 space-y-1">
                          {cols.slice(1, 5).map(col => (
                            <div key={col.key} className="flex items-center justify-between gap-3 text-xs">
                              <span className="text-slate-400">{col.label}</span>
                              <span className="truncate text-slate-700"><Cell field={col} value={r[col.key]} /></span>
                            </div>
                          ))}
                        </div>
                      </div>
                    ))}
                    {!inCol.length && <div className="rounded-lg border-2 border-dashed border-slate-200 px-3 py-6 text-center text-xs text-slate-400">Drop here</div>}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
'@

W 'apps/web/src/renderer/RecordForm.tsx' @'
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
'@

W 'apps/web/src/renderer/RecordDetail.tsx' @'
import { useState, type ReactNode } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ArrowLeft, ArrowRight, Check, Clock, History, Lock, Package, Pencil, Plus, Undo2, Upload } from 'lucide-react';
import { site, errOf, type ApiErr } from '../api';
import { useSite, RANK } from '../hooks';
import { Cell, Denial, StateBadge, labelOf, btn, btnGhost, card, inputBase } from './fields';
import { RecordForm } from './RecordForm';

function StockBox({ id }: { id: string }) {
  const { siteId } = useSite();
  const qc = useQueryClient();
  const [qty, setQty] = useState('');
  const [err, setErr] = useState<ApiErr | null>(null);
  const m = useMutation({
    mutationFn: (kind: 'receive' | 'adjust') =>
      site.post(siteId, `/item/${id}/stock`, { kind, qty: Number(qty), idempotencyKey: crypto.randomUUID() }),
    onSuccess: () => { setQty(''); setErr(null); qc.invalidateQueries({ predicate: x => x.queryKey[1] === siteId }); },
    onError: e => setErr(errOf(e)),
  });
  return (
    <div className={`${card} p-5`}>
      <div className="flex items-center gap-2 text-sm font-semibold text-slate-900"><Package className="h-4 w-4 text-slate-400" />Stock movement</div>
      <p className="mt-0.5 text-sm text-slate-500">Every change is written to the stock ledger.</p>
      <div className="mt-4 flex flex-wrap gap-2">
        <input type="number" value={qty} onChange={e => setQty(e.target.value)} placeholder="Quantity (negative to adjust down)" className={`${inputBase} w-72`} />
        <button disabled={!qty || Number(qty) <= 0 || m.isPending} onClick={() => m.mutate('receive')} className={btn}>Receive</button>
        <button disabled={!qty || m.isPending} onClick={() => m.mutate('adjust')} className={btnGhost}>Adjust</button>
      </div>
      {err && <div className="mt-3"><Denial err={err} /></div>}
    </div>
  );
}

function Stepper({ states, current }: { states: string[]; current: string }) {
  const path = states.filter(s => s !== 'rejected');
  const idx = path.indexOf(current);
  return (
    <ol className="flex flex-wrap items-center gap-y-3">
      {path.map((s, i) => {
        const done = idx > i;
        const now = idx === i;
        return (
          <li key={s} className="flex items-center">
            <span className={`flex h-6 w-6 items-center justify-center rounded-full text-[11px] font-semibold ${done ? 'bg-primary text-white' : now ? 'bg-white text-primary ring-2 ring-primary' : 'bg-slate-100 text-slate-400'}`}>
              {done ? <Check className="h-3.5 w-3.5" /> : i + 1}
            </span>
            <span className={`ml-2 text-xs font-medium capitalize ${now ? 'text-slate-900' : done ? 'text-slate-600' : 'text-slate-400'}`}>{s.replace(/_/g, ' ')}</span>
            {i < path.length - 1 && <span className={`mx-3 h-px w-8 ${done ? 'bg-primary' : 'bg-slate-200'}`} />}
          </li>
        );
      })}
      {current === 'rejected' && <li className="ml-2"><StateBadge state="rejected" /></li>}
    </ol>
  );
}

type Row = { at: string; icon: ReactNode; tone: string; title: ReactNode; meta: string };
const ic = 'h-3.5 w-3.5';

function eventRow(e: any): Row {
  const who = e.actor_name ? `${e.actor_name} (${e.actor_role})` : e.actor_role ?? 'system';
  const meta = `${new Date(e.at).toLocaleString()} - ${who}`;
  switch (e.kind) {
    case 'transition':
      return { at: e.at, meta, icon: <ArrowRight className={ic} />, tone: 'bg-primary text-white',
        title: <span>Moved from <b className="capitalize">{String(e.from_state).replace(/_/g, ' ')}</b> to <b className="capitalize">{String(e.to_state).replace(/_/g, ' ')}</b> <span className="font-mono text-xs text-slate-400">{e.transition_id}</span>{e.after?.assigned_to ? <span className="text-slate-500"> - assigned to {e.after.assigned_to}</span> : null}</span> };
    case 'create': return { at: e.at, meta, icon: <Plus className={ic} />, tone: 'bg-emerald-100 text-emerald-700', title: 'Created' };
    case 'update': return { at: e.at, meta, icon: <Pencil className={ic} />, tone: 'bg-slate-100 text-slate-600', title: 'Edited' };
    case 'import': return { at: e.at, meta, icon: <Upload className={ic} />, tone: 'bg-sky-100 text-sky-700', title: 'Imported from a spreadsheet' };
    case 'reservation_expired':
      return { at: e.at, meta, icon: <Clock className={ic} />, tone: 'bg-amber-100 text-amber-700',
        title: <span>Reservation expired; {e.after?.released ?? ''} released.{e.to_state ? <> Back to <b className="capitalize">{e.to_state}</b> for re-approval.</> : null}</span> };
    case 'rollback_map':
      return { at: e.at, meta, icon: <Undo2 className={ic} />, tone: 'bg-violet-100 text-violet-700',
        title: <span>Moved from <b>{e.from_state}</b> to <b>{e.to_state}</b> by a rollback plan</span> };
    default: return { at: e.at, meta, icon: <Package className={ic} />, tone: 'bg-slate-100 text-slate-600', title: String(e.kind).replace(/_/g, ' ') };
  }
}
function moveRow(m: any): Row {
  const sign = ({ receive: '+', return: '+', commit: '-', consume: '-', reserve: 'hold ', release: 'free ', adjust: '' } as Record<string, string>)[m.kind] ?? '';
  return {
    at: m.at, icon: <Package className={ic} />, tone: 'bg-slate-100 text-slate-600',
    title: <span className="text-slate-600">Ledger: <b className="text-slate-800">{m.kind}</b> {sign}{m.qty}{m.reason ? ` (${m.reason})` : ''}</span>,
    meta: `${new Date(m.at).toLocaleString()}${m.kind === 'reserve' && m.expires_at && !m.consumed_by ? ` - expires ${new Date(m.expires_at).toLocaleString()}` : ''}`,
  };
}

function Timeline({ entity, id }: { entity: string; id: string }) {
  const { siteId } = useSite();
  const q = useQuery({ queryKey: [entity, siteId, 'timeline', id], queryFn: () => site.get(siteId, `/${entity}/${id}/timeline`), refetchInterval: 5000 });
  if (q.isLoading) return <div className={`${card} h-64 animate-pulse`} />;
  if (q.error) return <Denial err={errOf(q.error)} />;
  const rows: Row[] = [...(q.data.events as any[]).map(eventRow), ...(q.data.movements as any[]).map(moveRow)]
    .sort((a, b) => +new Date(a.at) - +new Date(b.at));
  return (
    <div className={`${card} p-5`}>
      <div className="mb-5 flex items-center gap-2 text-sm font-semibold text-slate-900"><History className="h-4 w-4 text-slate-400" />Timeline</div>
      {rows.length ? (
        <ol className="relative space-y-5 before:absolute before:bottom-2 before:left-[13px] before:top-2 before:w-px before:bg-slate-200">
          {rows.map((x, i) => (
            <li key={i} className="relative flex gap-3">
              <span className={`relative z-10 flex h-7 w-7 shrink-0 items-center justify-center rounded-full ring-4 ring-white ${x.tone}`}>{x.icon}</span>
              <div className="min-w-0 pt-0.5">
                <div className="text-sm text-slate-700">{x.title}</div>
                <div className="mt-0.5 text-xs text-slate-400">{x.meta}</div>
              </div>
            </li>
          ))}
        </ol>
      ) : <div className="text-sm text-slate-400">No history yet.</div>}
    </div>
  );
}

export function RecordDetail() {
  const { entity = '', id = '' } = useParams();
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const qc = useQueryClient();
  const ent = schema.entities[entity];
  const q = useQuery({ queryKey: [entity, siteId, 'one', id], queryFn: () => site.get(siteId, `/${entity}/${id}`), refetchInterval: 5000 });
  const [editing, setEditing] = useState(false);
  const [assignee, setAssignee] = useState('');
  const [err, setErr] = useState<ApiErr | null>(null);

  const tr = useMutation({
    mutationFn: (to: string) => site.post(siteId, `/${entity}/${id}/transition`, {
      to, idempotencyKey: crypto.randomUUID(), ifVersion: q.data?.row_version,
      payload: to === 'assigned' && assignee ? { assigned_to: assignee } : undefined,
    }),
    onSuccess: () => { setErr(null); qc.invalidateQueries({ predicate: x => x.queryKey[1] === siteId }); },
    onError: e => setErr(errOf(e)),
  });

  if (!ent) return <Denial err={{ message: 'This site has no such record type.' }} />;
  if (q.isLoading) return <div className={`${card} h-48 animate-pulse`} />;
  if (q.error) return <Denial err={errOf(q.error)} />;
  const rec = q.data;
  const canEdit = ent.fields.some(f => !f.readonly);
  const transitions: any[] = rec.transitions ?? [];
  const wf = ent.workflow;

  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_380px]">
      <div className="space-y-5">
        <button onClick={() => nav(-1)} className="inline-flex items-center gap-1.5 text-sm text-slate-500 transition hover:text-slate-900"><ArrowLeft className="h-4 w-4" />Back</button>

        <div className={`${card} p-6`}>
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <div className="text-xs font-semibold uppercase tracking-wider text-primary">{ent.label}</div>
              <h1 className="mt-1 text-2xl font-semibold tracking-tight text-slate-900">{labelOf(rec)}</h1>
              <div className="mt-2 flex items-center gap-2">
                {rec.state && <StateBadge state={rec.state} />}
                <span className="rounded-md bg-slate-100 px-1.5 py-0.5 font-mono text-[11px] text-slate-500">v{rec.row_version}</span>
              </div>
            </div>
            <div className="flex gap-2">
              {rec.serial_no && <Link to={`${base}/timeline?serial=${encodeURIComponent(rec.serial_no)}`} className={btnGhost}><History className="h-4 w-4" />Board history</Link>}
              {canEdit && !editing && <button onClick={() => setEditing(true)} className={btnGhost}><Pencil className="h-4 w-4" />Edit</button>}
            </div>
          </div>
          {wf && rec.state && <div className="mt-6 border-t border-slate-100 pt-5"><Stepper states={wf.states} current={rec.state} /></div>}
        </div>

        {!!transitions.length && (
          <div className={`${card} p-5`}>
            <div className="text-sm font-semibold text-slate-900">Next steps</div>
            <p className="mt-0.5 text-sm text-slate-500">Each step is checked against this unit's rules and stock before it happens.</p>
            {transitions.some(t => t.to === 'assigned' && t.allowed) && (
              <input value={assignee} onChange={e => setAssignee(e.target.value)} placeholder="Assign to (name)" className={`${inputBase} mt-4 w-72`} />
            )}
            <div className="mt-4 flex flex-wrap gap-2">
              {transitions.map(t => (
                <button key={t.id} disabled={!t.allowed || tr.isPending} title={t.reason} onClick={() => tr.mutate(t.to)}
                  className={t.allowed ? btn : `${btnGhost} cursor-not-allowed`}>
                  {!t.allowed && <Lock className="h-3.5 w-3.5" />}{t.label}
                </button>
              ))}
            </div>
            {transitions.filter(t => !t.allowed).map(t => <div key={t.id} className="mt-2 text-xs text-slate-500">{t.reason}</div>)}
          </div>
        )}
        {err && <Denial err={err} />}

        {editing ? (
          <RecordForm entity={entity} initial={rec} onDone={() => setEditing(false)} onCancel={() => setEditing(false)} />
        ) : (
          <div className={`${card} p-6`}>
            <div className="mb-5 text-sm font-semibold text-slate-900">Details</div>
            <dl className="grid gap-x-8 gap-y-5 sm:grid-cols-2 xl:grid-cols-3">
              {ent.fields.map(f => (
                <div key={f.key}>
                  <dt className="text-xs font-medium uppercase tracking-wide text-slate-400">{f.label}</dt>
                  <dd className="mt-1 text-sm text-slate-900"><Cell field={f} value={rec[f.key]} /></dd>
                </div>
              ))}
            </dl>
          </div>
        )}
        {entity === 'item' && RANK[schema.role] >= 2 && <StockBox id={id} />}
      </div>
      <div className="lg:sticky lg:top-20 lg:self-start"><Timeline entity={entity} id={id} /></div>
    </div>
  );
}
'@

# ============================== site shell (four layouts) ==============================
W 'apps/web/src/renderer/SiteShell.tsx' @'
import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { Link, Navigate, NavLink, Route, Routes, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import {
  Activity, Building2, ChevronDown, Circle, ClipboardList, Columns3, Eye, History, Layers, LayoutDashboard,
  LayoutGrid, ListTodo, LogOut, Package, Sparkles, Table2, Undo2, Wrench, type LucideIcon,
} from 'lucide-react';
import { useSchema, useSites, useSite, SiteCtx, type SiteSummary, type Schema } from '../hooks';
import { useSession } from '../store/session';
import { errOf } from '../api';
import { Denial } from './fields';
import { PageView } from './views';
import { RecordDetail } from './RecordDetail';
import { SerialTimeline } from './SerialTimeline';

const initials = (s: string) => s.split(/\s+/).filter(Boolean).map(w => w[0]).join('').slice(0, 2).toUpperCase();

function Mark({ light }: { light?: boolean }) {
  const { name } = useSite();
  return (
    <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-sm font-bold ${light ? 'bg-white/15 text-white ring-1 ring-inset ring-white/20' : 'bg-primary text-white shadow-sm'}`}>
      {initials(name)}
    </span>
  );
}

function Skeleton({ label, color }: { label: string; color?: string }) {
  return (
    <div className="min-h-screen bg-slate-50">
      <div className="flex h-14 items-center gap-3 border-b border-slate-200 bg-white px-6">
        <span className="h-8 w-8 animate-pulse rounded-lg" style={{ background: color ?? '#cbd5e1' }} />
        <span className="text-sm font-semibold text-slate-700">{label}</span>
      </div>
      <div className="mx-auto max-w-7xl space-y-3 p-6">
        <div className="h-8 w-56 animate-pulse rounded-lg bg-slate-200" />
        {[0, 1, 2, 3, 4].map(i => <div key={i} className="h-12 animate-pulse rounded-xl bg-slate-200/70" />)}
      </div>
    </div>
  );
}

function iconFor(schema: Schema, path: string): LucideIcon {
  if (path === '/timeline') return History;
  const p = schema.pages.find(x => x.path === path);
  if (!p) return Circle;
  if (p.view === 'dashboard') return LayoutDashboard;
  if (p.view === 'kanban') return Columns3;
  if (p.view === 'queue') return ListTodo;
  if (p.path.includes('return')) return Undo2;
  return ({ item: Package, request: ClipboardList, repair: Wrench, consumption: Activity, assignment: ListTodo } as Record<string, LucideIcon>)[p.entity ?? ''] ?? Table2;
}

function SiteSwitcher({ dark }: { dark?: boolean }) {
  const sites = useSites();
  const { slug } = useSite();
  const nav = useNavigate();
  const ref = useRef<HTMLSelectElement>(null);
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        ref.current?.focus();
        (ref.current as any)?.showPicker?.();
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, []);
  return (
    <div className="relative w-full">
      <Building2 className={`pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 ${dark ? 'text-white/60' : 'text-slate-400'}`} />
      <select ref={ref} value={slug} onChange={e => nav(`/${e.target.value}`)} title="Switch unit (Ctrl+K)"
        className={`w-full cursor-pointer appearance-none rounded-lg py-1.5 pl-8 pr-8 text-sm font-medium outline-none transition ${dark ? 'border border-white/15 bg-white/10 text-white hover:bg-white/15' : 'border border-slate-200 bg-white text-slate-700 shadow-sm hover:border-slate-300'}`}>
        {sites.data?.map(s => <option key={s.id} value={s.slug} className="text-slate-900">{s.name}</option>)}
      </select>
      <ChevronDown className={`pointer-events-none absolute right-2.5 top-1/2 h-4 w-4 -translate-y-1/2 ${dark ? 'text-white/60' : 'text-slate-400'}`} />
    </div>
  );
}

function UserMenu({ dark }: { dark?: boolean }) {
  const user = useSession(s => s.user);
  const logout = useSession(s => s.logout);
  const { schema, siteId } = useSite();
  const link = `inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-sm font-medium transition ${dark ? 'text-white/80 hover:bg-white/10 hover:text-white' : 'text-slate-500 hover:bg-slate-100 hover:text-slate-900'}`;
  return (
    <div className="flex items-center gap-1">
      <Link to="/" className={link}><LayoutGrid className="h-4 w-4" />Hub</Link>
      {schema.role === 'Admin' && <Link to={`/builder/${siteId}`} className={link}><Layers className="h-4 w-4" />Builder</Link>}
      <div className={`ml-2 flex items-center gap-2.5 border-l pl-3 ${dark ? 'border-white/15' : 'border-slate-200'}`}>
        <span className={`flex h-8 w-8 items-center justify-center rounded-full text-xs font-semibold ${dark ? 'bg-white/20 text-white' : 'bg-primary/10 text-primary'}`}>{initials(user?.name ?? '?')}</span>
        <div className="hidden leading-tight md:block">
          <div className={`text-sm font-medium ${dark ? 'text-white' : 'text-slate-800'}`}>{user?.name}</div>
          <div className={`text-xs ${dark ? 'text-white/60' : 'text-slate-500'}`}>{schema.role}</div>
        </div>
        <button onClick={logout} title="Log out" className={`ml-1 rounded-lg p-2 transition ${dark ? 'text-white/70 hover:bg-white/10 hover:text-white' : 'text-slate-400 hover:bg-slate-100 hover:text-slate-700'}`}><LogOut className="h-4 w-4" /></button>
      </div>
    </div>
  );
}

function NavItems({ variant }: { variant: 'sidebar' | 'top' | 'pill' | 'rail' }) {
  const { schema, base } = useSite();
  const items = schema.modules.includes('pcb-repair') ? [...schema.nav, { label: 'Board history', path: '/timeline' }] : schema.nav;
  const cls = (a: boolean) => ({
    sidebar: `flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition ${a ? 'bg-white/10 text-white' : 'text-slate-400 hover:bg-white/5 hover:text-slate-100'}`,
    top: `flex items-center gap-2 border-b-2 px-1 py-[18px] text-sm font-medium transition ${a ? 'border-primary text-slate-900' : 'border-transparent text-slate-500 hover:text-slate-900'}`,
    pill: `flex items-center gap-2 rounded-full px-3.5 py-1.5 text-sm font-medium transition ${a ? 'bg-white text-primary shadow-sm' : 'text-white/80 hover:bg-white/10 hover:text-white'}`,
    rail: `flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition ${a ? 'bg-primary/10 text-primary' : 'text-slate-600 hover:bg-slate-100 hover:text-slate-900'}`,
  })[variant];
  return (
    <>
      {items.map(n => {
        const Icon = iconFor(schema, n.path);
        return (
          <NavLink key={n.path} to={base + n.path} className={({ isActive }) => cls(isActive)}>
            {({ isActive }) => <><Icon className={`h-4 w-4 shrink-0 ${variant === 'sidebar' && isActive ? 'text-primary' : ''}`} /><span>{n.label}</span></>}
          </NavLink>
        );
      })}
    </>
  );
}

function TopBar() {
  const { name } = useSite();
  return (
    <header className="sticky top-0 z-30 flex h-14 items-center justify-between border-b border-slate-200/80 bg-white/80 px-6 backdrop-blur">
      <div className="flex items-center gap-2 text-sm">
        <Link to="/" className="text-slate-400 transition hover:text-slate-700">Hub</Link>
        <span className="text-slate-300">/</span>
        <span className="font-medium text-slate-700">{name}</span>
      </div>
      <UserMenu />
    </header>
  );
}

function SidebarLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="flex min-h-screen">
      <aside className="sticky top-0 flex h-screen w-64 shrink-0 flex-col bg-slate-950">
        <div className="flex items-center gap-3 px-5 py-5">
          <Mark />
          <div className="min-w-0">
            <div className="truncate text-sm font-semibold text-white">{name}</div>
            <div className="text-xs text-slate-500">Operations unit</div>
          </div>
        </div>
        <div className="px-5 pb-2 text-[11px] font-semibold uppercase tracking-wider text-slate-600">Menu</div>
        <nav className="flex-1 space-y-0.5 px-3"><NavItems variant="sidebar" /></nav>
        <div className="border-t border-white/5 p-3"><SiteSwitcher dark /></div>
      </aside>
      <div className="min-w-0 flex-1">
        <TopBar />
        <main className="mx-auto max-w-7xl px-6 py-6">{children}</main>
      </div>
    </div>
  );
}

function TopbarLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-30 border-b border-slate-200 bg-white/90 backdrop-blur">
        <div className="mx-auto flex max-w-7xl items-center gap-6 px-6">
          <div className="flex items-center gap-3 py-3"><Mark /><span className="text-sm font-semibold text-slate-900">{name}</span></div>
          <nav className="flex gap-5"><NavItems variant="top" /></nav>
          <div className="ml-auto flex items-center gap-3"><div className="w-48"><SiteSwitcher /></div><UserMenu /></div>
        </div>
      </header>
      <main className="mx-auto max-w-7xl px-6 py-6">{children}</main>
    </div>
  );
}

function KanbanFirstLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-30 bg-primary text-white shadow-sm">
        <div className="flex items-center gap-6 px-6 py-3">
          <div className="flex items-center gap-3"><Mark light /><span className="text-base font-semibold">{name}</span></div>
          <nav className="flex flex-wrap gap-1"><NavItems variant="pill" /></nav>
          <div className="ml-auto flex items-center gap-3"><div className="w-48"><SiteSwitcher dark /></div><UserMenu dark /></div>
        </div>
      </header>
      <main className="px-6 py-6">{children}</main>
    </div>
  );
}

function QueueFirstLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="flex min-h-screen">
      <aside className="sticky top-0 flex h-screen w-64 shrink-0 flex-col border-r border-slate-200 bg-white">
        <div className="border-b border-slate-100 bg-primary/5 px-4 py-4">
          <div className="flex items-center gap-3">
            <Mark />
            <div className="min-w-0">
              <div className="truncate text-sm font-semibold text-slate-900">{name}</div>
              <div className="text-xs text-slate-500">Field operations</div>
            </div>
          </div>
          <div className="mt-3"><SiteSwitcher /></div>
        </div>
        <nav className="flex-1 space-y-0.5 p-3"><NavItems variant="rail" /></nav>
      </aside>
      <div className="min-w-0 flex-1">
        <TopBar />
        <main className="mx-auto max-w-6xl px-6 py-6">{children}</main>
      </div>
    </div>
  );
}

const LAYOUTS: Record<string, (p: { children: ReactNode }) => JSX.Element> = {
  sidebar: SidebarLayout,
  topbar: TopbarLayout,
  'kanban-first': KanbanFirstLayout,
  'queue-first': QueueFirstLayout,
};

// Live updates: a publish or a record change on this site refreshes what is on screen.
function useLive(siteId: string, enabled: boolean, onPublished: () => void) {
  const qc = useQueryClient();
  useEffect(() => {
    const token = useSession.getState().token;
    if (!enabled || !token) return;
    const es = new EventSource(`/api/events?token=${encodeURIComponent(token)}`);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const refresh = () => { clearTimeout(timer); timer = setTimeout(() => qc.invalidateQueries({ predicate: q => q.queryKey[1] === siteId }), 300); };
    es.addEventListener('site_published', (e: MessageEvent) => {
      if (JSON.parse(e.data).siteId !== siteId) return;
      qc.invalidateQueries({ predicate: q => q.queryKey[1] === siteId });
      qc.invalidateQueries({ queryKey: ['sites'] });
      onPublished();
    });
    es.addEventListener('record_changed', (e: MessageEvent) => { if (JSON.parse(e.data).siteId === siteId) refresh(); });
    return () => { clearTimeout(timer); es.close(); };
  }, [siteId, enabled]);
}

function SiteBody({ site, preview }: { site: SiteSummary; preview: string | null }) {
  const schema = useSchema(site.id);
  const nav = useNavigate();
  const switchSite = useSession(s => s.switchSite);
  const [toast, setToast] = useState('');
  useLive(site.id, !preview, () => { setToast('This unit was just updated to a new version.'); setTimeout(() => setToast(''), 6000); });

  if (schema.isLoading) return <Skeleton label={site.name} color={site.theme?.primary} />;
  if (schema.error || !schema.data) return <div className="p-6"><Denial err={errOf(schema.error)} /></div>;
  const s = schema.data;
  const base = `/${site.slug}`;
  const home = s.pages.some(p => p.path === s.theme.home) ? s.theme.home : s.pages[0]?.path ?? '/';
  const style = {
    '--primary': s.theme.tokens.primary,
    '--surface': s.theme.tokens.surface,
    '--radius': s.theme.tokens.radius,
    fontFamily: `'Inter Variable', ${s.theme.tokens.font}, ui-sans-serif, system-ui, sans-serif`,
  } as CSSProperties;
  const Layout = LAYOUTS[s.theme.layout] ?? TopbarLayout;

  return (
    <SiteCtx.Provider value={{ siteId: site.id, slug: site.slug, name: s.name, base, schema: s }}>
      <div style={style} className="min-h-screen bg-surface text-slate-800">
        {preview && (
          <div className="sticky top-0 z-50 flex items-center justify-between gap-3 bg-amber-400 px-4 py-2 text-sm text-amber-950">
            <span className="flex items-center gap-2"><Eye className="h-4 w-4" /><b>Previewing a draft</b> - read-only, using live data. Nothing here is saved.</span>
            <button onClick={() => { switchSite(site.id, null); nav(base); }} className="rounded-md bg-amber-950 px-2.5 py-1 text-xs font-medium text-white">Exit preview</button>
          </div>
        )}
        {toast && (
          <div className="fixed bottom-5 right-5 z-50 flex items-center gap-3 rounded-xl bg-slate-900 px-4 py-3 text-sm text-white shadow-xl">
            <Sparkles className="h-4 w-4 text-amber-300" />{toast}
          </div>
        )}
        <Layout>
          <Routes>
            <Route index element={<Navigate to={base + home} replace />} />
            {s.pages.map(p => <Route key={p.path} path={p.path.replace(/^\//, '')} element={<PageView page={p} />} />)}
            <Route path="r/:entity/:id" element={<RecordDetail />} />
            <Route path="timeline" element={<SerialTimeline />} />
            <Route path="*" element={<Denial err={{ message: 'That page is not part of this unit.' }} />} />
          </Routes>
        </Layout>
      </div>
    </SiteCtx.Provider>
  );
}

export default function SiteShell() {
  const { slug } = useParams();
  const [params] = useSearchParams();
  const sites = useSites();
  const active = useSession(s => s.activeSiteId);
  const storePreview = useSession(s => s.preview);
  const switchSite = useSession(s => s.switchSite);
  const site = sites.data?.find(s => s.slug === slug);
  const wantPreview = params.get('preview') ?? (site && active === site.id ? storePreview : null);

  useEffect(() => { if (site) switchSite(site.id, wantPreview); }, [site?.id, wantPreview, switchSite]);

  if (sites.isLoading) return <Skeleton label="Loading" />;
  if (!site) return <div className="space-y-3 p-6"><Denial err={{ message: 'Not found.' }} /><Link to="/" className="text-sm text-slate-600 underline">Back to hub</Link></div>;
  // Render nothing site-specific until the cache wipe for this site (and version) has happened.
  if (active !== site.id || storePreview !== wantPreview) return <Skeleton label={site.name} color={site.theme?.primary} />;
  return <SiteBody key={`${site.id}:${wantPreview ?? 'live'}`} site={site} preview={wantPreview} />;
}
'@

# ============================== hub, chaos, login ==============================
W 'apps/web/src/pages/Hub.tsx' @'
import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { ArrowRight, Boxes, Layers, LayoutGrid, LogOut, Plus, ShieldCheck, Users } from 'lucide-react';
import { PRESETS } from '@axel/compiler';
import { useSites, type SiteSummary } from '../hooks';
import { useSession } from '../store/session';
import { http, errOf } from '../api';
import { ChaosCard } from './Chaos';
import { SheetUnit } from './SheetUnit';

const CORE = new Set(['auth', 'users', 'dashboard']);
const LAYOUT_LABEL: Record<string, string> = { sidebar: 'Sidebar layout', topbar: 'Top bar layout', 'kanban-first': 'Board layout', 'queue-first': 'Work queue layout' };
const slugify = (s: string) => s.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
const dark = 'inline-flex items-center justify-center gap-1.5 rounded-lg bg-slate-900 px-3.5 py-2 text-sm font-medium text-white shadow-sm transition hover:bg-slate-800 disabled:opacity-50';
const ghost = 'inline-flex items-center justify-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3.5 py-2 text-sm font-medium text-slate-700 shadow-sm transition hover:bg-slate-50';

function NewUnit() {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  const [preset, setPreset] = useState('inventory-starter');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const qc = useQueryClient();
  const nav = useNavigate();
  async function create() {
    setErr(''); setBusy(true);
    try {
      const r = await http.post('/sites', { name, slug: slugify(name), preset });
      await qc.invalidateQueries({ queryKey: ['sites'] });
      nav(`/builder/${r.data.id}`);
    } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  if (!open) return <button onClick={() => setOpen(true)} className={dark}><Plus className="h-4 w-4" />New unit</button>;
  return (
    <div className="w-[640px] max-w-full space-y-4 rounded-2xl border border-slate-200 bg-white p-5 text-left shadow-sm">
      <div>
        <div className="font-semibold text-slate-900">New unit</div>
        <div className="text-sm text-slate-500">Start from a preset; change anything later in the builder.</div>
      </div>
      <input value={name} onChange={e => setName(e.target.value)} placeholder="Unit name, e.g. Field Maintenance" className="w-full rounded-lg border border-slate-200 px-3 py-2 text-sm shadow-sm outline-none focus:border-slate-400 focus:ring-4 focus:ring-slate-100" />
      <div className="text-xs text-slate-500">Address: /{slugify(name) || 'your-unit'}</div>
      <div className="grid gap-2 sm:grid-cols-3">
        {Object.entries(PRESETS).map(([k, p]) => (
          <button key={k} onClick={() => setPreset(k)} className={`rounded-xl border p-3 text-left text-sm transition ${preset === k ? 'border-slate-900 ring-1 ring-slate-900' : 'border-slate-200 hover:border-slate-300'}`}>
            <div className="font-medium text-slate-900">{p.name}</div><div className="mt-0.5 text-xs text-slate-500">{p.description}</div>
          </button>
        ))}
      </div>
      {err && <div className="rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700">{err}</div>}
      <div className="flex gap-2">
        <button disabled={busy || slugify(name).length < 2} onClick={create} className={dark}>{busy ? 'Creating...' : 'Create and open builder'}</button>
        <button onClick={() => setOpen(false)} className={ghost}>Cancel</button>
      </div>
    </div>
  );
}

function LayoutPreview({ layout, color }: { layout?: string; color?: string }) {
  const c = color ?? '#64748b';
  const bar = (w: string, extra = '') => <div className={`h-1.5 rounded-full bg-slate-200 ${extra}`} style={{ width: w }} />;
  let inner;
  if (layout === 'sidebar') inner = (
    <div className="flex h-full gap-2">
      <div className="w-10 rounded-md bg-slate-900 p-1.5"><div className="mb-1.5 h-2 w-2 rounded-sm" style={{ background: c }} />{[0, 1, 2].map(i => <div key={i} className="mb-1 h-1 rounded-full bg-white/20" />)}</div>
      <div className="flex-1 space-y-1.5 rounded-md bg-white p-2 shadow-sm">{bar('60%')}<div className="flex h-8 items-end gap-1">{[50, 80, 40, 90, 65].map((h, i) => <div key={i} className="flex-1 rounded-sm" style={{ height: `${h}%`, background: c, opacity: 0.8 }} />)}</div></div>
    </div>
  );
  else if (layout === 'kanban-first') inner = (
    <div className="flex h-full flex-col gap-1.5">
      <div className="h-3 rounded-md" style={{ background: c }} />
      <div className="flex flex-1 gap-1.5">{[3, 2, 1].map((n, i) => <div key={i} className="flex-1 space-y-1 rounded-md bg-slate-200/70 p-1">{Array.from({ length: n }, (_, j) => <div key={j} className="h-3 rounded-sm bg-white shadow-sm" />)}</div>)}</div>
    </div>
  );
  else if (layout === 'queue-first') inner = (
    <div className="flex h-full gap-2">
      <div className="w-10 space-y-1 rounded-md bg-white p-1.5 shadow-sm"><div className="h-1.5 rounded-full" style={{ background: c }} />{[0, 1, 2].map(i => <div key={i} className="h-1 rounded-full bg-slate-200" />)}</div>
      <div className="flex-1 space-y-1.5">{[0, 1, 2].map(i => <div key={i} className="flex h-4 items-center gap-1 rounded-md bg-white px-1 shadow-sm"><div className="h-2 w-2 rounded-sm" style={{ background: c, opacity: 0.6 }} />{bar('50%')}</div>)}</div>
    </div>
  );
  else inner = (
    <div className="flex h-full flex-col gap-1.5">
      <div className="flex h-3 items-center gap-1 rounded-md bg-white px-1 shadow-sm"><div className="h-1.5 w-4 rounded-full" style={{ background: c }} />{bar('20%')}</div>
      <div className="grid flex-1 grid-cols-3 gap-1.5">{[0, 1, 2, 3, 4, 5].map(i => <div key={i} className="rounded-sm bg-white shadow-sm" />)}</div>
    </div>
  );
  return <div className="h-28 border-b border-slate-100 p-3" style={{ background: `linear-gradient(135deg, ${c}14, #f8fafc)` }}>{inner}</div>;
}

function UnitCard({ s }: { s: SiteSummary }) {
  const mods = s.modules.filter(m => !CORE.has(m));
  return (
    <div className="group flex flex-col overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm transition hover:-translate-y-0.5 hover:shadow-lg">
      <LayoutPreview layout={s.theme?.layout} color={s.theme?.primary} />
      <div className="flex flex-1 flex-col p-5">
        <div className="flex items-start justify-between gap-2">
          <h3 className="text-base font-semibold text-slate-900">{s.name}</h3>
          <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">{s.role}</span>
        </div>
        <p className="mt-1 text-sm text-slate-500">{LAYOUT_LABEL[s.theme?.layout ?? ''] ?? 'Custom layout'} - {s.modules.length} modules</p>
        <div className="mt-3 flex flex-wrap gap-1">
          {mods.slice(0, 5).map(m => <span key={m} className="rounded-md bg-slate-50 px-1.5 py-0.5 text-[11px] text-slate-600 ring-1 ring-inset ring-slate-200">{m}</span>)}
          {mods.length > 5 && <span className="rounded-md px-1.5 py-0.5 text-[11px] text-slate-400">+{mods.length - 5} more</span>}
        </div>
        <div className="mt-auto flex gap-2 pt-5">
          <Link to={`/${s.slug}`} className={`${dark} flex-1`}>Open<ArrowRight className="h-4 w-4" /></Link>
          {s.role === 'Admin' && <Link to={`/builder/${s.id}`} className={ghost}><Layers className="h-4 w-4" />Builder</Link>}
        </div>
      </div>
    </div>
  );
}

function Stat({ icon, label, value, hint }: { icon: JSX.Element; label: string; value: string; hint: string }) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex items-center justify-between"><span className="text-sm font-medium text-slate-500">{label}</span><span className="flex h-8 w-8 items-center justify-center rounded-lg bg-slate-100 text-slate-600">{icon}</span></div>
      <div className="mt-2 text-2xl font-semibold tracking-tight text-slate-900">{value}</div>
      <div className="mt-0.5 text-xs text-slate-500">{hint}</div>
    </div>
  );
}

export default function Hub() {
  const sites = useSites();
  const user = useSession(s => s.user);
  const logout = useSession(s => s.logout);
  const switchSite = useSession(s => s.switchSite);
  useEffect(() => { switchSite(null); }, [switchSite]);
  const list = sites.data ?? [];
  const instances = list.reduce((n, s) => n + s.modules.length, 0);
  const adminOf = list.filter(s => s.role === 'Admin').length;
  const first = (user?.name ?? '').split(' ')[0];

  return (
    <div className="min-h-screen bg-slate-50">
      <header className="sticky top-0 z-30 border-b border-slate-200 bg-white/80 backdrop-blur">
        <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-6">
          <div className="flex items-center gap-3">
            <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-slate-900 text-sm font-bold text-white">A</span>
            <div className="leading-tight"><div className="text-sm font-semibold text-slate-900">Axel</div><div className="text-xs text-slate-500">Operations hub</div></div>
          </div>
          <div className="flex items-center gap-2">
            {user?.hubAdmin && <Link to="/hub/ledger" className="inline-flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium text-slate-600 transition hover:bg-slate-100 hover:text-slate-900"><ShieldCheck className="h-4 w-4" />Isolation Ledger</Link>}
            <div className="ml-2 flex items-center gap-2.5 border-l border-slate-200 pl-4">
              <span className="flex h-8 w-8 items-center justify-center rounded-full bg-slate-900 text-xs font-semibold text-white">{(user?.name ?? '?').split(' ').map(w => w[0]).join('').slice(0, 2)}</span>
              <span className="hidden text-sm font-medium text-slate-700 sm:block">{user?.name}</span>
              <button onClick={logout} title="Log out" className="rounded-lg p-2 text-slate-400 transition hover:bg-slate-100 hover:text-slate-700"><LogOut className="h-4 w-4" /></button>
            </div>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-7xl space-y-8 px-6 py-8">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight text-slate-900">Welcome back{first ? `, ${first}` : ''}</h1>
            <p className="mt-1 text-slate-500">One login, one codebase. Every unit runs its own published Blueprint.</p>
          </div>
          {user?.hubAdmin && <div className="flex flex-wrap items-start justify-end gap-2"><SheetUnit /><NewUnit /></div>}
        </div>

        {!!list.length && (
          <div className="grid gap-4 sm:grid-cols-3">
            <Stat icon={<LayoutGrid className="h-4 w-4" />} label="Units" value={String(list.length)} hint="Different products from one codebase" />
            <Stat icon={<Boxes className="h-4 w-4" />} label="Reuse meter" value={`${instances} instances`} hint="Powered by 13 shared module implementations" />
            <Stat icon={<Users className="h-4 w-4" />} label="Your access" value={`Admin in ${adminOf}`} hint={`Member of ${list.length} unit${list.length === 1 ? '' : 's'}`} />
          </div>
        )}

        <div>
          <div className="mb-4 flex items-center justify-between">
            <h2 className="text-lg font-semibold text-slate-900">Your units</h2>
            <span className="text-sm text-slate-500">Press Ctrl+K inside a unit to switch</span>
          </div>
          {sites.isLoading && <div className="grid gap-5 sm:grid-cols-2 xl:grid-cols-3">{[0, 1, 2].map(i => <div key={i} className="h-72 animate-pulse rounded-2xl bg-slate-200/70" />)}</div>}
          <div className="grid gap-5 sm:grid-cols-2 xl:grid-cols-3">{list.map(s => <UnitCard key={s.id} s={s} />)}</div>
        </div>

        {user?.hubAdmin && <ChaosCard />}
      </main>
    </div>
  );
}
'@

W 'apps/web/src/pages/Chaos.tsx' @'
import { useState } from 'react';
import { useMutation } from '@tanstack/react-query';
import { Zap } from 'lucide-react';
import { http, errOf } from '../api';

export function ChaosCard() {
  const [res, setRes] = useState<any>(null);
  const [err, setErr] = useState('');
  const m = useMutation({
    mutationFn: () => http.post('/hub/chaos', { concurrency: 50, stock: 10 }).then(r => r.data),
    onSuccess: d => { setErr(''); setRes(d); },
    onError: e => setErr(errOf(e).message),
  });
  const box = 'rounded-xl bg-slate-50 p-4 text-sm ring-1 ring-inset ring-slate-200';
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div className="flex items-start gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-amber-50 text-amber-600 ring-1 ring-inset ring-amber-200"><Zap className="h-5 w-5" /></span>
          <div>
            <div className="font-semibold text-slate-900">Chaos test</div>
            <div className="text-sm text-slate-500">Fire 50 concurrent approvals at an item with 10 in stock. Exactly 10 may succeed.</div>
          </div>
        </div>
        <button onClick={() => m.mutate()} disabled={m.isPending} className="inline-flex items-center gap-1.5 rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white shadow-sm transition hover:bg-slate-800 disabled:opacity-50">
          <Zap className="h-4 w-4" />{m.isPending ? 'Running...' : 'Run chaos'}
        </button>
      </div>
      {err && <div className="mt-4 rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700">{err}</div>}
      {res && (
        <div className="mt-5 grid gap-3 sm:grid-cols-4">
          <div className={`rounded-xl p-4 text-center ring-1 ring-inset ${res.passed ? 'bg-emerald-50 text-emerald-800 ring-emerald-200' : 'bg-rose-50 text-rose-800 ring-rose-200'}`}>
            <div className="text-2xl font-bold tracking-tight">{res.passed ? 'PASS' : 'FAIL'}</div>
            <div className="mt-0.5 text-xs">{res.site} - {res.durationMs} ms</div>
          </div>
          <div className={box}>
            <div className="mb-1 text-xs font-medium uppercase tracking-wide text-slate-400">Outcomes</div>
            {Object.entries(res.outcomes).map(([k, v]) => <div key={k} className="flex justify-between"><span className="text-slate-600">{k}</span><b className="tabular">{String(v)}</b></div>)}
          </div>
          <div className={box}>
            <div className="mb-1 text-xs font-medium uppercase tracking-wide text-slate-400">Item after</div>
            <div className="flex justify-between"><span className="text-slate-600">On hand</span><b className="tabular">{res.item.on_hand}</b></div>
            <div className="flex justify-between"><span className="text-slate-600">Reserved</span><b className="tabular">{res.item.reserved}</b></div>
          </div>
          <div className={box}>
            <div className="mb-1 text-xs font-medium uppercase tracking-wide text-slate-400">Ledger recomputed</div>
            <div className="flex justify-between"><span className="text-slate-600">On hand</span><b className="tabular">{res.ledger.on_hand}</b></div>
            <div className="flex justify-between"><span className="text-slate-600">Reserved</span><b className="tabular">{res.ledger.reserved}</b></div>
            <div className="flex justify-between"><span className="text-slate-600">Reserve rows</span><b className="tabular">{res.reserveMovements}</b></div>
          </div>
        </div>
      )}
    </div>
  );
}
'@

W 'apps/web/src/pages/Login.tsx' @'
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ArrowLeft, ArrowRight, Check, ShieldCheck } from 'lucide-react';
import { http, errOf } from '../api';
import { useSession } from '../store/session';

const DEMO: [string, string, string][] = [
  ['admin@axel.dev', 'Hub admin', 'All units'],
  ['manager@sc.dev', 'Service Centre', 'Manager'],
  ['member@sc.dev', 'Service Centre', 'Member'],
  ['manager@cs.dev', 'Central Stores', 'Manager'],
  ['member@cs.dev', 'Central Stores', 'Member'],
  ['field@dist.dev', 'Distribution', 'Field member'],
];
const PILLARS: [string, string][] = [
  ['Derived', 'Built from the spreadsheets a unit already keeps.'],
  ['Proven', 'Every change is checked against rules and real history.'],
  ['Reversible', 'Roll back any release without losing data.'],
];
const field = 'w-full rounded-lg border border-slate-200 bg-white px-3 py-2.5 text-sm text-slate-900 shadow-sm outline-none transition placeholder:text-slate-400 focus:border-slate-400 focus:ring-4 focus:ring-slate-100';
const primary = 'inline-flex w-full items-center justify-center gap-2 rounded-lg bg-slate-900 py-2.5 text-sm font-medium text-white shadow-sm transition hover:bg-slate-800 disabled:opacity-50';

function PoweredBy() {
  return (
    <a href="https://minimoth.dev?utm_source=powered_by" target="_blank" rel="noopener" className="inline-block">
      <img src="https://minimoth.dev/powered-by/powered-by-light.svg" alt="Powered by MiniMoth" height="18" style={{ height: 18 }} className="opacity-60 transition hover:opacity-100" />
    </a>
  );
}

export default function Login() {
  const [email, setEmail] = useState('admin@axel.dev');
  const [password, setPassword] = useState('demo1234');
  const [otp, setOtp] = useState<null | { challenge: string; phoneHint: string; mode: string }>(null);
  const [code, setCode] = useState('');
  const [err, setErr] = useState('');
  const [info, setInfo] = useState('');
  const [busy, setBusy] = useState(false);
  const login = useSession(s => s.login);
  const nav = useNavigate();
  const finish = (d: any) => { login(d.token, d.user); nav('/'); };

  async function submit(em = email) {
    setErr(''); setInfo(''); setBusy(true);
    try {
      const r = await http.post('/auth/login', { email: em, password });
      if (r.data.otpRequired) { setOtp({ challenge: r.data.challenge, phoneHint: r.data.phoneHint, mode: r.data.mode }); setCode(''); }
      else finish(r.data);
    } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  async function verify() {
    if (!otp) return;
    setErr(''); setInfo(''); setBusy(true);
    try { finish((await http.post('/auth/verify-otp', { challenge: otp.challenge, code })).data); }
    catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  async function resend() {
    if (!otp) return;
    setErr(''); setInfo(''); setBusy(true);
    try { await http.post('/auth/resend-otp', { challenge: otp.challenge }); setInfo('A new code is on its way.'); }
    catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }

  return (
    <div className="grid min-h-screen lg:grid-cols-[1.1fr_1fr]">
      <div className="relative hidden flex-col justify-between overflow-hidden bg-slate-950 p-12 text-white lg:flex">
        <div className="pointer-events-none absolute -left-32 -top-32 h-[28rem] w-[28rem] rounded-full bg-indigo-600/30 blur-3xl" />
        <div className="pointer-events-none absolute -bottom-40 right-0 h-[26rem] w-[26rem] rounded-full bg-teal-500/20 blur-3xl" />
        <div className="relative flex items-center gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-white text-base font-bold text-slate-950">A</span>
          <span className="text-lg font-semibold">Axel</span>
        </div>
        <div className="relative max-w-lg space-y-8">
          <h1 className="text-5xl font-semibold leading-[1.1] tracking-tight">Every site proven<br />before it runs.</h1>
          <p className="text-lg text-slate-400">One hub for every operations unit. Stock rooms, repair desks and field teams, each with its own system, all from one codebase.</p>
          <ul className="space-y-4">
            {PILLARS.map(([t, d]) => (
              <li key={t} className="flex gap-3">
                <span className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-white/10 ring-1 ring-inset ring-white/20"><Check className="h-3.5 w-3.5" /></span>
                <div><div className="font-medium">{t}</div><div className="text-sm text-slate-400">{d}</div></div>
              </li>
            ))}
          </ul>
        </div>
        <div className="relative text-xs text-slate-500">PS 03 OpsHub - Team Breaking Bytes</div>
      </div>

      <div className="flex items-center justify-center bg-slate-50 p-6">
        <div className="w-full max-w-md space-y-6">
          <div className="flex items-center gap-3 lg:hidden">
            <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-slate-900 text-base font-bold text-white">A</span>
            <span className="text-lg font-semibold text-slate-900">Axel</span>
          </div>

          {otp ? (
            <form onSubmit={e => { e.preventDefault(); verify(); }} className="space-y-5 rounded-2xl border border-slate-200 bg-white p-7 shadow-sm">
              <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-slate-100 text-slate-700"><ShieldCheck className="h-5 w-5" /></div>
              <div>
                <h2 className="text-xl font-semibold tracking-tight text-slate-900">Check your phone</h2>
                <p className="mt-1 text-sm text-slate-500">We sent a 6-digit code to {otp.phoneHint} on WhatsApp (SMS if WhatsApp does not go through).</p>
              </div>
              <input value={code} onChange={e => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))} inputMode="numeric" autoFocus placeholder="000000"
                className="w-full rounded-xl border border-slate-200 bg-white px-3 py-3.5 text-center font-mono text-2xl tracking-[0.5em] text-slate-900 shadow-sm outline-none transition placeholder:text-slate-300 focus:border-slate-400 focus:ring-4 focus:ring-slate-100" />
              {otp.mode === 'test' && <div className="rounded-lg bg-sky-50 px-3 py-2 text-xs text-sky-800 ring-1 ring-inset ring-sky-200">Test mode: no message is sent. The code is 000000.</div>}
              {err && <div className="rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700">{err}</div>}
              {info && <div className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800">{info}</div>}
              <button disabled={busy || code.length !== 6} className={primary}>{busy ? 'Checking...' : 'Verify and sign in'}</button>
              <div className="flex items-center justify-between text-sm">
                <button type="button" onClick={() => { setOtp(null); setErr(''); setInfo(''); }} className="inline-flex items-center gap-1 text-slate-500 hover:text-slate-900"><ArrowLeft className="h-4 w-4" />Back</button>
                <button type="button" onClick={resend} disabled={busy} className="text-slate-500 hover:text-slate-900">Send a new code</button>
              </div>
              <div className="flex justify-center border-t border-slate-100 pt-4"><PoweredBy /></div>
            </form>
          ) : (
            <>
              <form onSubmit={e => { e.preventDefault(); submit(); }} className="space-y-5 rounded-2xl border border-slate-200 bg-white p-7 shadow-sm">
                <div>
                  <h2 className="text-xl font-semibold tracking-tight text-slate-900">Sign in</h2>
                  <p className="mt-1 text-sm text-slate-500">Password first, then a one-time code on your phone.</p>
                </div>
                <label className="block">
                  <span className="mb-1.5 block text-sm font-medium text-slate-700">Email</span>
                  <input value={email} onChange={e => setEmail(e.target.value)} className={field} />
                </label>
                <label className="block">
                  <span className="mb-1.5 block text-sm font-medium text-slate-700">Password</span>
                  <input type="password" value={password} onChange={e => setPassword(e.target.value)} className={field} />
                </label>
                {err && <div className="rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700">{err}</div>}
                <button disabled={busy} className={primary}>{busy ? 'Signing in...' : <>Continue<ArrowRight className="h-4 w-4" /></>}</button>
                <div className="flex justify-center"><PoweredBy /></div>
              </form>
              <div className="rounded-2xl border border-slate-200 bg-white p-3 shadow-sm">
                <div className="px-2 pb-2 pt-1 text-xs font-medium uppercase tracking-wide text-slate-400">Demo accounts - password demo1234</div>
                <div className="grid gap-0.5">
                  {DEMO.map(([em, unit, role]) => (
                    <button key={em} onClick={() => { setEmail(em); submit(em); }} className="flex items-center gap-3 rounded-lg px-2 py-2 text-left transition hover:bg-slate-50">
                      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-slate-100 text-[11px] font-semibold text-slate-600">{unit.split(' ').map(w => w[0]).join('').slice(0, 2)}</span>
                      <span className="min-w-0 flex-1">
                        <span className="block text-sm font-medium text-slate-800">{unit}</span>
                        <span className="block truncate text-xs text-slate-400">{em}</span>
                      </span>
                      <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs text-slate-600">{role}</span>
                    </button>
                  ))}
                </div>
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
'@

Write-Host ''
Write-Host 'Redesign done. Next: pnpm install, .\restore.ps1, .\start.ps1'