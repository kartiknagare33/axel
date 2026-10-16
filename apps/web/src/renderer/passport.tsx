import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { RotateCcw, ShieldAlert } from 'lucide-react';
import { site } from '../api';
import { useSite } from '../hooks';
import { card } from './fields';

const d = (v?: string | null) => (v ? new Date(v).toLocaleDateString() : '-');

export function Passport({ p }: { p: any }) {
  const cell = 'rounded-xl bg-slate-50 p-4 ring-1 ring-inset ring-slate-200';
  return (
    <div className={`${card} p-5`}>
      <div className="mb-4 text-sm font-semibold text-slate-900">Board passport</div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className={cell}><div className="text-xs text-slate-500">Visits</div><div className="mt-1 text-2xl font-semibold text-slate-900">{p.requests}</div><div className="text-xs text-slate-500">{p.repairs} repair log{p.repairs === 1 ? '' : 's'}</div></div>
        <div className={cell}><div className="text-xs text-slate-500">Rework rounds</div><div className="mt-1 text-2xl font-semibold text-slate-900">{p.reworks}</div><div className="text-xs text-slate-500">after a failed test</div></div>
        <div className={cell}><div className="text-xs text-slate-500">Last outcome</div><div className="mt-1 text-base font-semibold text-slate-900">{p.lastOutcome ?? '-'}</div><div className="text-xs text-slate-500">closed {d(p.lastClosedAt)}</div></div>
        <div className={`rounded-xl p-4 ring-1 ring-inset ${p.underWarranty ? 'bg-emerald-50 ring-emerald-200' : 'bg-slate-50 ring-slate-200'}`}>
          <div className="text-xs text-slate-500">Warranty</div>
          <div className={`mt-1 text-base font-semibold ${p.underWarranty ? 'text-emerald-700' : 'text-slate-900'}`}>{p.underWarranty ? 'Active' : p.warrantyUntil ? 'Expired' : '-'}</div>
          <div className="text-xs text-slate-500">{p.warrantyUntil ? `until ${d(p.warrantyUntil)}` : 'no completed repair yet'}</div>
        </div>
      </div>
      {!!p.parts?.length && (
        <div className="mt-4 flex flex-wrap items-center gap-1.5 text-xs">
          <span className="text-slate-500">Parts replaced:</span>
          {p.parts.map((x: string, i: number) => <span key={i} className="rounded-md bg-slate-100 px-1.5 py-0.5 text-slate-700">{x}</span>)}
        </div>
      )}
    </div>
  );
}

export function RepeatBanner({ serial, recId }: { serial: string; recId: string }) {
  const { siteId, base } = useSite();
  const q = useQuery({ queryKey: ['timeline', siteId, serial], queryFn: () => site.get(siteId, '/timeline', { serial }) });
  const prev = (q.data?.passport?.history ?? []).filter((h: any) => h.request_id !== recId);
  if (!prev.length) return null;
  const last = prev[0];
  const inW = !!last.warranty_until && new Date(last.warranty_until) > new Date();
  return (
    <div className={`flex gap-3 rounded-xl border px-4 py-3 text-sm ${inW ? 'border-rose-200 bg-rose-50 text-rose-900' : 'border-amber-200 bg-amber-50 text-amber-900'}`}>
      {inW ? <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0 text-rose-500" /> : <RotateCcw className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />}
      <div>
        <div className="font-semibold">{inW ? 'Repeat failure under warranty' : 'This board has been here before'}</div>
        <div className="mt-0.5">
          {prev.length} earlier repair{prev.length === 1 ? '' : 's'}. Last closed on {d(last.closed_at)} ({last.outcome ?? 'Repaired'}){inW ? `; warranty runs until ${d(last.warranty_until)}` : ''}.
        </div>
        <Link to={`${base}/timeline?serial=${encodeURIComponent(serial)}`} className="mt-1 inline-block font-medium underline underline-offset-4">See the board history</Link>
      </div>
    </div>
  );
}
