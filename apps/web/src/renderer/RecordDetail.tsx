import { useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { site, errOf, type ApiErr } from '../api';
import { useSite, RANK } from '../hooks';
import { Cell, Denial, StateBadge, labelOf, btn, btnGhost } from './fields';
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
    <div className="space-y-2 rounded-site border bg-white p-4">
      <div className="text-sm font-medium">Stock movement (ledger)</div>
      <div className="flex gap-2">
        <input type="number" value={qty} onChange={e => setQty(e.target.value)} placeholder="Qty (negative to adjust down)" className="w-64 rounded-site border px-3 py-1.5 text-sm" />
        <button disabled={!qty || Number(qty) <= 0 || m.isPending} onClick={() => m.mutate('receive')} className={btn}>Receive</button>
        <button disabled={!qty || m.isPending} onClick={() => m.mutate('adjust')} className={btnGhost}>Adjust</button>
      </div>
      {err && <Denial err={err} />}
    </div>
  );
}

function EventLine({ e }: { e: any }) {
  const who = e.actor_name ? `${e.actor_name} (${e.actor_role})` : e.actor_role ?? 'system';
  switch (e.kind) {
    case 'create': return <span>Created by {who}</span>;
    case 'update': return <span>Edited by {who}</span>;
    case 'transition':
      return <span><b>{e.from_state}</b> &rarr; <b>{e.to_state}</b> by {who} <span className="font-mono text-xs text-slate-400">{e.transition_id}</span>{e.after?.assigned_to ? ` - assigned to ${e.after.assigned_to}` : ''}</span>;
    case 'reservation_expired':
      return <span className="text-amber-700">Reservation expired; {e.after?.released ?? ''} released. {e.to_state ? <>Back to <b>{e.to_state}</b> for re-approval.</> : null}</span>;
    default: return <span>{String(e.kind).replace(/_/g, ' ')} by {who}</span>;
  }
}

function MoveLine({ m }: { m: any }) {
  const sign = ({ receive: '+', return: '+', commit: '-', consume: '-', reserve: 'hold ', release: 'free ', adjust: '' } as Record<string, string>)[m.kind] ?? '';
  return (
    <span className="text-slate-600">
      Ledger: <b>{m.kind}</b> {sign}{m.qty}{m.reason ? ` (${m.reason})` : ''}
      {m.kind === 'reserve' && m.expires_at && !m.consumed_by ? ` - expires ${new Date(m.expires_at).toLocaleString()}` : ''}
    </span>
  );
}

function Timeline({ entity, id }: { entity: string; id: string }) {
  const { siteId } = useSite();
  const q = useQuery({ queryKey: [entity, siteId, 'timeline', id], queryFn: () => site.get(siteId, `/${entity}/${id}/timeline`), refetchInterval: 5000 });
  if (q.isLoading) return null;
  if (q.error) return <Denial err={errOf(q.error)} />;
  const items = [
    ...(q.data.events as any[]).map(e => ({ at: e.at, node: <EventLine e={e} /> })),
    ...(q.data.movements as any[]).map(m => ({ at: m.at, node: <MoveLine m={m} /> })),
  ].sort((a, b) => +new Date(a.at) - +new Date(b.at));
  return (
    <div className="rounded-site border bg-white p-4">
      <div className="mb-3 text-sm font-medium">Timeline</div>
      <ol className="space-y-3 border-l-2 border-primary/20 pl-4">
        {items.map((x, i) => (
          <li key={i} className="text-sm">
            {x.node}
            <div className="text-xs text-slate-400">{new Date(x.at).toLocaleString()}</div>
          </li>
        ))}
        {!items.length && <li className="text-sm text-slate-400">No history yet.</li>}
      </ol>
    </div>
  );
}

export function RecordDetail() {
  const { entity = '', id = '' } = useParams();
  const { siteId, schema } = useSite();
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
  if (q.isLoading) return <div className="h-40 animate-pulse rounded-site bg-slate-200" />;
  if (q.error) return <Denial err={errOf(q.error)} />;
  const rec = q.data;
  const canEdit = ent.fields.some(f => !f.readonly);
  const transitions: any[] = rec.transitions ?? [];

  return (
    <div className="grid max-w-6xl gap-4 lg:grid-cols-[1fr_380px]">
      <div className="space-y-4">
        <button onClick={() => nav(-1)} className="text-sm text-slate-500 hover:text-slate-900">&lt; Back</button>
        <div className="flex items-start justify-between">
          <div>
            <div className="text-xs uppercase text-slate-400">{ent.label}</div>
            <h1 className="text-xl font-semibold">{labelOf(rec)}</h1>
            <div className="mt-1 flex items-center gap-2 text-xs text-slate-500">
              {rec.state && <StateBadge state={rec.state} />}<span>v{rec.row_version}</span>
            </div>
          </div>
          {canEdit && !editing && <button onClick={() => setEditing(true)} className={btnGhost}>Edit</button>}
        </div>

        {editing ? (
          <RecordForm entity={entity} initial={rec} onDone={() => setEditing(false)} onCancel={() => setEditing(false)} />
        ) : (
          <dl className="grid grid-cols-2 gap-x-6 gap-y-3 rounded-site border bg-white p-4 text-sm">
            {ent.fields.map(f => (
              <div key={f.key}>
                <dt className="text-xs text-slate-400">{f.label}</dt>
                <dd><Cell field={f} value={rec[f.key]} /></dd>
              </div>
            ))}
          </dl>
        )}

        {!!transitions.length && (
          <div className="space-y-2 rounded-site border bg-white p-4">
            <div className="text-sm font-medium">Next steps</div>
            {transitions.some(t => t.to === 'assigned' && t.allowed) && (
              <input value={assignee} onChange={e => setAssignee(e.target.value)} placeholder="Assign to (name)" className="w-64 rounded-site border px-3 py-1.5 text-sm" />
            )}
            <div className="flex flex-wrap gap-2">
              {transitions.map(t => (
                <button key={t.id} disabled={!t.allowed || tr.isPending} title={t.reason} onClick={() => tr.mutate(t.to)}
                  className={t.allowed ? btn : `${btnGhost} cursor-not-allowed`}>{t.label}</button>
              ))}
            </div>
            {transitions.filter(t => !t.allowed).map(t => <div key={t.id} className="text-xs text-slate-500">{t.reason}</div>)}
          </div>
        )}
        {err && <Denial err={err} />}
        {entity === 'item' && RANK[schema.role] >= 2 && <StockBox id={id} />}
      </div>
      <Timeline entity={entity} id={id} />
    </div>
  );
}
