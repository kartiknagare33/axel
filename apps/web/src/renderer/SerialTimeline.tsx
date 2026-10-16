import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { site, errOf } from '../api';
import { useSite } from '../hooks';
import { Denial, StateBadge, btn } from './fields';
import { Passport } from './passport';

export function SerialTimeline() {
  const { siteId, base } = useSite();
  const [params, setParams] = useSearchParams();
  const serial = params.get('serial') ?? '';
  const [input, setInput] = useState(serial);
  const q = useQuery({ queryKey: ['timeline', siteId, serial], queryFn: () => site.get(siteId, '/timeline', { serial }), enabled: !!serial });
  const items = q.data ? [
    ...q.data.events.map((e: any) => ({ at: e.at, text: e.kind === 'transition' ? `${e.from_state} to ${e.to_state}` : String(e.kind).replace(/_/g, ' '), who: e.actor_name ? `${e.actor_name} (${e.actor_role})` : e.actor_role ?? 'system', kind: 'event' })),
    ...q.data.moves.map((m: any) => ({ at: m.at, text: `Stock ${m.kind} ${m.qty} of ${m.item}${m.reason ? ` (${m.reason})` : ''}`, who: 'ledger', kind: 'move' })),
  ].sort((a, b) => +new Date(a.at) - +new Date(b.at)) : [];

  return (
    <div className="max-w-4xl space-y-4">
      <h1 className="text-xl font-semibold">Board history</h1>
      <form onSubmit={e => { e.preventDefault(); setParams(input.trim() ? { serial: input.trim() } : {}); }} className="flex gap-2">
        <input value={input} onChange={e => setInput(e.target.value)} placeholder="Serial number, e.g. PCB-24001" className="w-72 rounded-site border px-3 py-2 text-sm" />
        <button className={btn}>Show history</button>
      </form>
      {q.isLoading && serial && <div className="h-24 animate-pulse rounded-site bg-slate-200" />}
      {q.error && <Denial err={errOf(q.error)} />}
      {q.data && !q.data.records.length && <div className="text-sm text-slate-500">No record in this unit has serial {serial}.</div>}
      {!!q.data?.records.length && q.data.passport && <Passport p={q.data.passport} />}
      {!!q.data?.records.length && (
        <div className="grid gap-4 md:grid-cols-[1fr_1.3fr]">
          <div className="space-y-2">
            {q.data.records.map((r: any) => (
              <Link key={String(r.rec.id)} to={`${base}/r/${r.entity}/${r.rec.id}`} className="block rounded-site border bg-white p-3 text-sm hover:shadow">
                <div className="flex items-center justify-between"><span className="font-medium">{r.label}</span>{r.rec.state && <StateBadge state={r.rec.state} />}</div>
                <div className="text-xs text-slate-500">{[r.rec.fault, r.rec.diagnosis].filter(Boolean).join(' - ') || String(r.rec.id).slice(0, 8)}</div>
              </Link>
            ))}
          </div>
          <ol className="space-y-3 rounded-site border-l-2 border-primary/30 bg-white p-4">
            {items.map((x, i) => (
              <li key={i} className="text-sm">
                <div className={x.kind === 'move' ? 'text-slate-600' : ''}>{x.text}</div>
                <div className="text-xs text-slate-400">{new Date(x.at).toLocaleString()} - {x.who}</div>
              </li>
            ))}
          </ol>
        </div>
      )}
    </div>
  );
}
