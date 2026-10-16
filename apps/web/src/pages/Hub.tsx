import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { PRESETS } from '@axel/compiler';
import { useSites } from '../hooks';
import { useSession } from '../store/session';
import { http, errOf } from '../api';
import { ChaosCard } from './Chaos';
import { SheetUnit } from './SheetUnit';

const CORE = new Set(['auth', 'users', 'dashboard']);
const slugify = (s: string) => s.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);

function NewUnit() {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  const [preset, setPreset] = useState('inventory-starter');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const qc = useQueryClient();
  const nav = useNavigate();
  async function create() {
    setErr(''); setBusy(true);
    try {
      const r = await http.post('/sites', { name, slug: slugify(name), preset });
      await qc.invalidateQueries({ queryKey: ['sites'] });
      nav(`/builder/${r.data.id}`);
    } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  if (!open) return <button onClick={() => setOpen(true)} className="rounded-lg border border-dashed border-slate-300 px-4 py-2 text-sm text-slate-600 hover:bg-white">+ New unit</button>;
  return (
    <div className="space-y-3 rounded-xl border bg-white p-5">
      <div className="font-medium">New unit</div>
      <input value={name} onChange={e => setName(e.target.value)} placeholder="Unit name, e.g. Field Maintenance" className="w-full rounded-lg border px-3 py-2 text-sm" />
      <div className="text-xs text-slate-500">Address: /{slugify(name) || 'your-unit'}</div>
      <div className="grid gap-2 sm:grid-cols-3">
        {Object.entries(PRESETS).map(([k, p]) => (
          <button key={k} onClick={() => setPreset(k)} className={`rounded-lg border p-3 text-left text-sm ${preset === k ? 'border-slate-900 ring-1 ring-slate-900' : ''}`}>
            <div className="font-medium">{p.name}</div><div className="text-xs text-slate-500">{p.description}</div>
          </button>
        ))}
      </div>
      {err && <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
      <div className="flex gap-2">
        <button disabled={busy || slugify(name).length < 2} onClick={create} className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">{busy ? 'Creating...' : 'Create and open builder'}</button>
        <button onClick={() => setOpen(false)} className="rounded-lg border px-4 py-2 text-sm">Cancel</button>
      </div>
    </div>
  );
}

export default function Hub() {
  const sites = useSites();
  const user = useSession(s => s.user);
  const logout = useSession(s => s.logout);
  const switchSite = useSession(s => s.switchSite);
  useEffect(() => { switchSite(null); }, [switchSite]);
  const instances = sites.data?.reduce((n, s) => n + s.modules.length, 0) ?? 0;

  return (
    <div className="min-h-screen bg-slate-50">
      <header className="flex items-center justify-between border-b bg-white px-6 py-3">
        <div className="text-lg font-bold">Axel <span className="font-normal text-slate-400">hub</span></div>
        <div className="flex items-center gap-4 text-sm">
          {user?.hubAdmin && <Link to="/hub/ledger" className="text-slate-500 hover:text-slate-900">Isolation Ledger</Link>}
          <span>{user?.name}</span>
          <button onClick={logout} className="text-slate-500 hover:text-slate-900">Log out</button>
        </div>
      </header>
      <main className="mx-auto max-w-5xl space-y-6 p-6">
        <div className="flex items-end justify-between">
          <div>
            <h1 className="text-2xl font-semibold">Your units</h1>
            <p className="text-sm text-slate-500">One login, one codebase. Each unit runs its own published Blueprint.</p>
          </div>
          {user?.hubAdmin && <div className="flex flex-col items-end gap-2"><NewUnit /><SheetUnit /></div>}
        </div>
        {sites.isLoading && <div className="h-32 animate-pulse rounded-xl bg-slate-200" />}
        <div className="grid gap-4 sm:grid-cols-3">
          {sites.data?.map(s => (
            <div key={s.id} className="flex flex-col rounded-xl border bg-white p-5 shadow-sm">
              <div className="h-2 w-12 rounded-full" style={{ background: s.theme?.primary }} />
              <h2 className="mt-3 text-lg font-semibold">{s.name}</h2>
              <p className="text-xs text-slate-500">{s.theme?.layout} layout - {s.modules.length} modules - you are {s.role}</p>
              <div className="mt-3 flex flex-wrap gap-1">
                {s.modules.filter(m => !CORE.has(m)).map(m => <span key={m} className="rounded bg-slate-100 px-1.5 py-0.5 text-[10px] text-slate-600">{m}</span>)}
              </div>
              <div className="mt-4 flex gap-2 pt-1">
                <Link to={`/${s.slug}`} className="rounded-lg bg-slate-900 px-3 py-1.5 text-sm text-white">Open</Link>
                {s.role === 'Admin' && <Link to={`/builder/${s.id}`} className="rounded-lg border px-3 py-1.5 text-sm">Builder</Link>}
              </div>
            </div>
          ))}
        </div>
        {!!sites.data?.length && (
          <div className="rounded-xl border bg-white p-5">
            <div className="text-xs font-medium uppercase text-slate-400">Reuse meter</div>
            <div className="mt-1 text-2xl font-bold">{instances} module instances, 13 implementations</div>
            <p className="text-sm text-slate-500">Without a shared hub, every unit rebuilds every module it uses.</p>
          </div>
        )}
        {user?.hubAdmin && <ChaosCard />}
      </main>
    </div>
  );
}
