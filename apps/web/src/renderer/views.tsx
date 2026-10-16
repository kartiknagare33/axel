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
