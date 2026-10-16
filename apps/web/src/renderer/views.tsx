import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import {
  ResponsiveContainer, BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  PieChart, Pie, Cell as Slice, LineChart, Line,
} from 'recharts';
import type { Page, Widget } from '@axel/compiler';
import { site, errOf } from '../api';
import { useList, useSite, RANK } from '../hooks';
import { Cell, columnFields, Denial, labelOf, StateBadge, btn, money } from './fields';
import { RecordForm } from './RecordForm';

function useDensity() {
  const { schema } = useSite();
  return schema.theme.density === 'compact' ? 'px-2 py-1 text-xs' : 'px-3 py-2 text-sm';
}
function canCreate(entity?: string) {
  const { schema } = useSite();
  return !!entity && RANK[schema.role] >= 1 && !!schema.entities[entity]?.fields.some(f => !f.readonly);
}

function PageHeader({ title, count, onNew }: { title: string; count?: number; onNew?: () => void }) {
  return (
    <div className="flex items-center justify-between">
      <div>
        <h1 className="text-xl font-semibold">{title}</h1>
        {count != null && <p className="text-xs text-slate-500">{count} records</p>}
      </div>
      {onNew && <button onClick={onNew} className={btn}>+ New</button>}
    </div>
  );
}

function QueryState({ q }: { q: { isLoading: boolean; error: unknown } }) {
  if (q.isLoading) return <div className="space-y-2">{[0, 1, 2, 3].map(i => <div key={i} className="h-8 animate-pulse rounded bg-slate-200" />)}</div>;
  if (q.error) return <Denial err={errOf(q.error)} />;
  return null;
}

function useCreator(entity?: string) {
  const [open, setOpen] = useState(false);
  const allowed = canCreate(entity);
  return {
    onNew: allowed ? () => setOpen(v => !v) : undefined,
    form: open && entity ? <RecordForm entity={entity} onDone={() => setOpen(false)} onCancel={() => setOpen(false)} /> : null,
  };
}

export function TableView({ page }: { page: Page }) {
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const d = useDensity();
  const entity = page.entity!;
  const ent = schema.entities[entity];
  const q = useList(siteId, entity, page.filter ? { filter: page.filter } : {});
  const c = useCreator(entity);
  const cols = columnFields(ent, page.columns);
  const rows: any[] = q.data?.rows ?? [];
  return (
    <>
      <PageHeader title={page.title} count={q.data?.total} onNew={c.onNew} />
      {c.form}
      <QueryState q={q} />
      {!q.isLoading && !q.error && (
        <div className="overflow-x-auto rounded-site border bg-white">
          <table className="w-full text-left">
            <thead className="bg-slate-50 text-slate-500">
              <tr>{cols.map(col => <th key={col.key} className={`${d} font-medium`}>{col.label}</th>)}</tr>
            </thead>
            <tbody>
              {rows.map(r => (
                <tr key={r.id} onClick={() => nav(`${base}/r/${entity}/${r.id}`)} className="cursor-pointer border-t hover:bg-primary/5">
                  {cols.map(col => <td key={col.key} className={d}><Cell field={col} value={r[col.key]} /></td>)}
                </tr>
              ))}
            </tbody>
          </table>
          {!rows.length && <div className="p-6 text-center text-sm text-slate-400">Nothing here yet.</div>}
        </div>
      )}
    </>
  );
}

export function KanbanView({ page }: { page: Page }) {
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const entity = page.entity!;
  const ent = schema.entities[entity];
  const q = useList(siteId, entity);
  const c = useCreator(entity);
  const groupBy = page.groupBy ?? 'state';
  const rows: any[] = q.data?.rows ?? [];
  const states = ent.workflow?.states ?? [...new Set(rows.map(r => String(r[groupBy])))];
  const cols = columnFields(ent, page.columns);
  return (
    <>
      <PageHeader title={page.title} count={q.data?.total} onNew={c.onNew} />
      {c.form}
      <QueryState q={q} />
      {!q.isLoading && !q.error && (
        <div className="flex gap-3 overflow-x-auto pb-2">
          {states.map(s => {
            const inCol = rows.filter(r => String(r[groupBy]) === s);
            return (
              <div key={s} className="w-72 shrink-0 rounded-site bg-slate-100 p-2">
                <div className="mb-2 flex items-center justify-between px-1">
                  <StateBadge state={s} />
                  <span className="text-xs text-slate-500">{inCol.length}</span>
                </div>
                <div className="space-y-2">
                  {inCol.map(r => (
                    <button key={r.id} onClick={() => nav(`${base}/r/${entity}/${r.id}`)}
                      className="block w-full rounded-site border-l-4 border-primary bg-white p-3 text-left text-sm shadow-sm hover:shadow">
                      <div className="font-medium">{labelOf(r)}</div>
                      {cols.slice(1).map(col => (
                        <div key={col.key} className="flex justify-between text-xs text-slate-500">
                          <span>{col.label}</span><span><Cell field={col} value={r[col.key]} /></span>
                        </div>
                      ))}
                    </button>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}

export function QueueView({ page }: { page: Page }) {
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const entity = page.entity!;
  const ent = schema.entities[entity];
  const q = useList(siteId, entity);
  const cols = columnFields(ent, page.columns);
  const rows: any[] = q.data?.rows ?? [];
  return (
    <>
      <PageHeader title={page.title} count={q.data?.total} />
      <QueryState q={q} />
      {!q.isLoading && !q.error && (
        <div className="space-y-2">
          {rows.map(r => (
            <div key={r.id} className="flex items-center justify-between rounded-site border-l-4 border-primary bg-white p-4 shadow-sm">
              <div className="space-y-1 text-sm">
                {cols.map(col => (
                  <div key={col.key}><span className="text-slate-400">{col.label}: </span><Cell field={col} value={r[col.key]} /></div>
                ))}
              </div>
              <button onClick={() => nav(`${base}/r/${entity}/${r.id}`)} className={btn}>Open</button>
            </div>
          ))}
          {!rows.length && (
            <div className="rounded-site border border-dashed bg-white p-8 text-center text-sm text-slate-500">
              Queue is empty. Approved requests appear here once a Manager assigns them.
            </div>
          )}
        </div>
      )}
    </>
  );
}

function WidgetCard({ w }: { w: Widget }) {
  const { siteId, schema } = useSite();
  const color = schema.theme.tokens.primary;
  const q = useQuery({ queryKey: ['analytics', siteId, w.id], queryFn: () => site.get(siteId, `/analytics/${w.id}`) });
  const data: { key: string; value: number }[] = q.data?.data ?? [];
  const isMoney = !!w.field && /price|value|total|cost/.test(w.field);
  return (
    <div className="rounded-site border bg-white p-4 shadow-sm">
      <div className="mb-3 text-sm font-medium text-slate-600">{w.title ?? w.id}</div>
      <QueryState q={q} />
      {!q.isLoading && !q.error && (
        w.type === 'stat' ? (
          <div className="text-3xl font-bold text-primary">
            {isMoney ? money(data.reduce((a, b) => a + b.value, 0)) : data.reduce((a, b) => a + b.value, 0).toLocaleString('en-IN')}
          </div>
        ) : (
          <div className="h-56">
            <ResponsiveContainer width="100%" height="100%">
              {w.type === 'pie' ? (
                <PieChart>
                  <Pie data={data} dataKey="value" nameKey="key" outerRadius={80} label={(e: any) => e.key}>
                    {data.map((_, i) => <Slice key={i} fill={color} fillOpacity={1 - i * (0.7 / Math.max(data.length, 1))} />)}
                  </Pie>
                  <Tooltip />
                </PieChart>
              ) : w.type === 'line' ? (
                <LineChart data={data}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis dataKey="key" fontSize={11} /><YAxis fontSize={11} /><Tooltip />
                  <Line dataKey="value" stroke={color} strokeWidth={2} />
                </LineChart>
              ) : (
                <BarChart data={data}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} />
                  <XAxis dataKey="key" fontSize={11} /><YAxis fontSize={11} allowDecimals={false} /><Tooltip />
                  <Bar dataKey="value" fill={color} radius={[4, 4, 0, 0]} />
                </BarChart>
              )}
            </ResponsiveContainer>
          </div>
        )
      )}
    </div>
  );
}

export function DashboardView({ page }: { page: Page }) {
  return (
    <>
      <PageHeader title={page.title} />
      <div className="grid gap-4 md:grid-cols-2">
        {(page.widgets ?? []).map(w => <WidgetCard key={w.id} w={w} />)}
      </div>
    </>
  );
}

export function PageView({ page }: { page: Page }) {
  const V = ({ table: TableView, kanban: KanbanView, queue: QueueView, dashboard: DashboardView } as Record<string, (p: { page: Page }) => JSX.Element>)[page.view] ?? TableView;
  return <div className="space-y-4"><V page={page} /></div>;
}
