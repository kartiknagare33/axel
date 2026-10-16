import { useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { site, errOf, type ApiErr } from '../api';
import { useRecord, useSite, RANK } from '../hooks';
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
    onSuccess: () => { setQty(''); setErr(null); qc.invalidateQueries({ queryKey: ['item', siteId] }); },
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

export function RecordDetail() {
  const { entity = '', id = '' } = useParams();
  const { siteId, schema } = useSite();
  const nav = useNavigate();
  const qc = useQueryClient();
  const ent = schema.entities[entity];
  const q = useRecord(siteId, entity, id);
  const [editing, setEditing] = useState(false);
  const [err, setErr] = useState<ApiErr | null>(null);

  const tr = useMutation({
    mutationFn: (to: string) => site.post(siteId, `/${entity}/${id}/transition`, {
      to, idempotencyKey: crypto.randomUUID(), ifVersion: q.data?.row_version,
    }),
    onSuccess: () => { setErr(null); qc.invalidateQueries({ queryKey: [entity, siteId] }); qc.invalidateQueries({ queryKey: ['item', siteId] }); },
    onError: e => setErr(errOf(e)),
  });

  if (!ent) return <Denial err={{ message: 'This site has no such record type.' }} />;
  if (q.isLoading) return <div className="h-40 animate-pulse rounded-site bg-slate-200" />;
  if (q.error) return <Denial err={errOf(q.error)} />;
  const rec = q.data;
  const canEdit = ent.fields.some(f => !f.readonly);

  return (
    <div className="max-w-3xl space-y-4">
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

      {!!rec.allowedTransitions?.length && (
        <div className="flex flex-wrap gap-2">
          {rec.allowedTransitions.map((t: any) => (
            <button key={t.id} disabled={tr.isPending} onClick={() => tr.mutate(t.to)} className={btn}>{t.label}</button>
          ))}
        </div>
      )}
      {err && <Denial err={err} />}
      {entity === 'item' && RANK[schema.role] >= 2 && <StockBox id={id} />}
    </div>
  );
}
