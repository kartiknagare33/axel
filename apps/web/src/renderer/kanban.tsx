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
