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
