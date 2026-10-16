import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import type { Page } from '@axel/compiler';
import { site, errOf, type ApiErr } from '../api';
import { useList, useSite, RANK } from '../hooks';
import { Cell, columnFields, Denial, labelOf, StateBadge, btn } from './fields';
import { RecordForm } from './RecordForm';

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
    <>
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">{page.title}</h1>
          <p className="text-xs text-slate-500">{q.data?.total ?? 0} records - drag cards between columns to move them through the workflow</p>
        </div>
        {canNew && <button onClick={() => setCreating(v => !v)} className={btn}>+ New</button>}
      </div>
      {creating && <RecordForm entity={entity} onDone={() => setCreating(false)} onCancel={() => setCreating(false)} />}
      {err && <Denial err={err} />}
      {q.isLoading && <div className="h-40 animate-pulse rounded-site bg-slate-200" />}
      {q.error && <Denial err={errOf(q.error)} />}
      {!q.isLoading && !q.error && (
        <div className="flex gap-3 overflow-x-auto pb-2">
          {states.map(s => {
            const inCol = rows.filter(r => String(r[groupBy]) === s);
            const t = dragging ? stepTo(String(dragging[groupBy]), s) : undefined;
            const ring = over === s ? (t?.allowed ? 'ring-2 ring-primary' : 'ring-2 ring-red-300') : dragging && t?.allowed ? 'ring-1 ring-primary/40' : '';
            return (
              <div key={s}
                onDragOver={e => { if (dragging) { e.preventDefault(); setOver(s); } }}
                onDragLeave={() => setOver(o => (o === s ? null : o))}
                onDrop={() => drop(s)}
                className={`w-72 shrink-0 rounded-site bg-slate-100 p-2 transition ${ring}`}>
                <div className="mb-2 flex items-center justify-between px-1">
                  <StateBadge state={s} />
                  <span className="text-xs text-slate-500">{inCol.length}</span>
                </div>
                <div className="min-h-12 space-y-2">
                  {inCol.map(r => (
                    <div key={r.id} draggable
                      onDragStart={() => { setErr(null); setDragId(r.id); }}
                      onDragEnd={() => { setDragId(null); setOver(null); }}
                      onClick={() => nav(`${base}/r/${entity}/${r.id}`)}
                      className={`cursor-grab rounded-site border-l-4 border-primary bg-white p-3 text-sm shadow-sm hover:shadow ${dragId === r.id ? 'opacity-40' : ''}`}>
                      <div className="font-medium">{labelOf(r)}</div>
                      {cols.slice(1).map(col => (
                        <div key={col.key} className="flex justify-between text-xs text-slate-500">
                          <span>{col.label}</span><span><Cell field={col} value={r[col.key]} /></span>
                        </div>
                      ))}
                    </div>
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
