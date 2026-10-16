import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Check, Search } from 'lucide-react';

const FRIENDLY: Record<string, [string, string]> = {
  draft: ['Registered', 'We have recorded your item.'],
  submitted: ['Received', 'Your item is with us and waiting for approval.'],
  approved: ['Approved', 'Approved for repair and waiting for a technician.'],
  assigned: ['Assigned', 'Assigned to a technician.'],
  in_repair: ['In repair', 'A technician is working on it.'],
  testing: ['Testing', 'The repair is being tested.'],
  closed: ['Ready', 'Repair complete and tested.'],
  returned: ['Returned', 'Sent back to you.'],
  rejected: ['Not accepted', 'This item was not accepted. Please contact us.'],
  scrapped: ['Beyond economical repair', 'A repair would cost more than it is worth. Please contact us.'],
};
const label = (s: string) => FRIENDLY[s]?.[0] ?? s.replace(/_/g, ' ');

export default function Track() {
  const { slug } = useParams();
  const [units, setUnits] = useState<{ slug: string; name: string; label: string }[]>([]);
  const [unit, setUnit] = useState(slug ?? '');
  const [ref, setRef] = useState('');
  const [res, setRes] = useState<any>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    fetch('/api/public/track-units').then(r => r.json()).then(u => { setUnits(u); if (!slug && u[0]) setUnit(u[0].slug); }).catch(() => {});
  }, [slug]);
  const current = units.find(u => u.slug === unit);

  async function search(e: React.FormEvent) {
    e.preventDefault();
    setErr(''); setRes(null); setBusy(true);
    try {
      const r = await fetch(`/api/public/track/${unit}?ref=${encodeURIComponent(ref.trim())}`);
      const j = await r.json();
      if (!r.ok) setErr(j.message ?? 'Nothing found.'); else setRes(j);
    } catch { setErr('Could not reach the server.'); } finally { setBusy(false); }
  }
  const reached = (s: string) => res?.steps?.filter((x: any) => x.to_state === s).slice(-1)[0]?.at;
  const idx = res ? res.states.indexOf(res.state) : -1;

  return (
    <div className="relative flex min-h-screen items-center justify-center overflow-hidden bg-slate-50 px-4 py-12">
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_top,rgba(13,148,136,0.12),transparent_60%)]" />
      <div className="relative w-full max-w-md space-y-6">
        <div className="flex flex-col items-center text-center">
          <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-slate-900 text-lg font-bold text-white shadow-lg">A</span>
          <h1 className="mt-5 text-2xl font-semibold tracking-tight text-slate-900">Track a repair</h1>
          <p className="mt-1 text-sm text-slate-500">No sign-in needed. Only the progress is shown.</p>
        </div>

        <form onSubmit={search} className="space-y-4 rounded-2xl border border-slate-200 bg-white p-6 shadow-xl shadow-slate-900/5">
          {units.length > 1 && !slug && (
            <label className="block">
              <span className="mb-1.5 block text-sm font-medium text-slate-700">Service desk</span>
              <select value={unit} onChange={e => setUnit(e.target.value)} className="w-full rounded-lg border border-slate-200 bg-white px-3 py-2.5 text-sm shadow-sm">
                {units.map(u => <option key={u.slug} value={u.slug}>{u.name}</option>)}
              </select>
            </label>
          )}
          <label className="block">
            <span className="mb-1.5 block text-sm font-medium text-slate-700">{current?.label ?? 'Serial number'}{current ? ` - ${current.name}` : ''}</span>
            <input value={ref} onChange={e => setRef(e.target.value)} placeholder="e.g. PCB-24007" autoFocus
              className="w-full rounded-lg border border-slate-200 bg-white px-3 py-2.5 text-sm shadow-sm outline-none focus:border-slate-400 focus:ring-4 focus:ring-slate-100" />
          </label>
          {!units.length && <div className="rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-500">No service desk has public tracking switched on.</div>}
          {err && <div className="rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700">{err}</div>}
          <button disabled={busy || !unit || ref.trim().length < 3} className="inline-flex w-full items-center justify-center gap-2 rounded-lg bg-slate-900 py-2.5 text-sm font-medium text-white shadow-sm transition hover:bg-slate-800 disabled:opacity-50">
            <Search className="h-4 w-4" />{busy ? 'Looking...' : 'Track'}
          </button>
        </form>

        {res && (
          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <div className="text-xs font-semibold uppercase tracking-wider text-slate-400">{res.unit}</div>
            <div className="mt-1 text-lg font-semibold text-slate-900">{res.ref}: {label(res.state)}</div>
            <div className="text-sm text-slate-500">{FRIENDLY[res.state]?.[1]}</div>
            <ol className="mt-5 space-y-3">
              {res.states.map((s: string, i: number) => {
                const done = i < idx, now = i === idx;
                const at = reached(s) ?? (i === 0 ? res.received : null);
                return (
                  <li key={s} className="flex items-center gap-3">
                    <span className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold ${done ? 'bg-slate-900 text-white' : now ? 'bg-white text-slate-900 ring-2 ring-slate-900' : 'bg-slate-100 text-slate-400'}`}>
                      {done ? <Check className="h-3.5 w-3.5" /> : i + 1}
                    </span>
                    <span className={`flex-1 text-sm ${now ? 'font-semibold text-slate-900' : done ? 'text-slate-700' : 'text-slate-400'}`}>{label(s)}</span>
                    <span className="text-xs text-slate-400">{(done || now) && at ? new Date(at).toLocaleDateString() : ''}</span>
                  </li>
                );
              })}
            </ol>
            <div className="mt-4 border-t border-slate-100 pt-3 text-xs text-slate-400">Last update: {new Date(res.updated).toLocaleString()}</div>
          </div>
        )}

        <div className="text-center"><Link to="/login" className="inline-flex items-center gap-1 text-sm text-slate-500 hover:text-slate-900"><ArrowLeft className="h-4 w-4" />Staff sign-in</Link></div>
      </div>
    </div>
  );
}
