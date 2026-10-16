import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { ArrowRight, Boxes, Layers, LayoutGrid, LogOut, Plus, ShieldCheck, Users } from 'lucide-react';
import { PRESETS } from '@axel/compiler';
import { useSites, type SiteSummary } from '../hooks';
import { useSession } from '../store/session';
import { http, errOf } from '../api';
import { ChaosCard } from './Chaos';
import { SheetUnit } from './SheetUnit';
import { HelpButton } from '../help/HelpPanel';
import { HubHelp } from '../help/content';
import { GettingStarted } from '../help/GettingStarted';

const CORE = new Set(['auth', 'users', 'dashboard']);
const LAYOUT_LABEL: Record<string, string> = { sidebar: 'Sidebar layout', topbar: 'Top bar layout', 'kanban-first': 'Board layout', 'queue-first': 'Work queue layout' };
const slugify = (s: string) => s.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
const dark = 'inline-flex items-center justify-center gap-1.5 rounded-lg bg-slate-900 px-3.5 py-2 text-sm font-medium text-white shadow-sm transition hover:bg-slate-800 disabled:opacity-50';
const ghost = 'inline-flex items-center justify-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3.5 py-2 text-sm font-medium text-slate-700 shadow-sm transition hover:bg-slate-50';

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
  if (!open) return <button onClick={() => setOpen(true)} className={dark}><Plus className="h-4 w-4" />New unit</button>;
  return (
    <div className="w-[640px] max-w-full space-y-4 rounded-2xl border border-slate-200 bg-white p-5 text-left shadow-sm">
      <div>
        <div className="font-semibold text-slate-900">New unit</div>
        <div className="text-sm text-slate-500">Start from a preset; change anything later in the builder.</div>
      </div>
      <input value={name} onChange={e => setName(e.target.value)} placeholder="Unit name, e.g. Field Maintenance" className="w-full rounded-lg border border-slate-200 px-3 py-2 text-sm shadow-sm outline-none focus:border-slate-400 focus:ring-4 focus:ring-slate-100" />
      <div className="text-xs text-slate-500">Address: /{slugify(name) || 'your-unit'}</div>
      <div className="grid gap-2 sm:grid-cols-3">
        {Object.entries(PRESETS).map(([k, p]) => (
          <button key={k} onClick={() => setPreset(k)} className={`rounded-xl border p-3 text-left text-sm transition ${preset === k ? 'border-slate-900 ring-1 ring-slate-900' : 'border-slate-200 hover:border-slate-300'}`}>
            <div className="font-medium text-slate-900">{p.name}</div><div className="mt-0.5 text-xs text-slate-500">{p.description}</div>
          </button>
        ))}
      </div>
      {err && <div className="rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700">{err}</div>}
      <div className="flex gap-2">
        <button disabled={busy || slugify(name).length < 2} onClick={create} className={dark}>{busy ? 'Creating...' : 'Create and open builder'}</button>
        <button onClick={() => setOpen(false)} className={ghost}>Cancel</button>
      </div>
    </div>
  );
}

function LayoutPreview({ layout, color }: { layout?: string; color?: string }) {
  const c = color ?? '#64748b';
  const bar = (w: string, extra = '') => <div className={`h-1.5 rounded-full bg-slate-200 ${extra}`} style={{ width: w }} />;
  let inner;
  if (layout === 'sidebar') inner = (
    <div className="flex h-full gap-2">
      <div className="w-10 rounded-md bg-slate-900 p-1.5"><div className="mb-1.5 h-2 w-2 rounded-sm" style={{ background: c }} />{[0, 1, 2].map(i => <div key={i} className="mb-1 h-1 rounded-full bg-white/20" />)}</div>
      <div className="flex-1 space-y-1.5 rounded-md bg-white p-2 shadow-sm">{bar('60%')}<div className="flex h-8 items-end gap-1">{[50, 80, 40, 90, 65].map((h, i) => <div key={i} className="flex-1 rounded-sm" style={{ height: `${h}%`, background: c, opacity: 0.8 }} />)}</div></div>
    </div>
  );
  else if (layout === 'kanban-first') inner = (
    <div className="flex h-full flex-col gap-1.5">
      <div className="h-3 rounded-md" style={{ background: c }} />
      <div className="flex flex-1 gap-1.5">{[3, 2, 1].map((n, i) => <div key={i} className="flex-1 space-y-1 rounded-md bg-slate-200/70 p-1">{Array.from({ length: n }, (_, j) => <div key={j} className="h-3 rounded-sm bg-white shadow-sm" />)}</div>)}</div>
    </div>
  );
  else if (layout === 'queue-first') inner = (
    <div className="flex h-full gap-2">
      <div className="w-10 space-y-1 rounded-md bg-white p-1.5 shadow-sm"><div className="h-1.5 rounded-full" style={{ background: c }} />{[0, 1, 2].map(i => <div key={i} className="h-1 rounded-full bg-slate-200" />)}</div>
      <div className="flex-1 space-y-1.5">{[0, 1, 2].map(i => <div key={i} className="flex h-4 items-center gap-1 rounded-md bg-white px-1 shadow-sm"><div className="h-2 w-2 rounded-sm" style={{ background: c, opacity: 0.6 }} />{bar('50%')}</div>)}</div>
    </div>
  );
  else inner = (
    <div className="flex h-full flex-col gap-1.5">
      <div className="flex h-3 items-center gap-1 rounded-md bg-white px-1 shadow-sm"><div className="h-1.5 w-4 rounded-full" style={{ background: c }} />{bar('20%')}</div>
      <div className="grid flex-1 grid-cols-3 gap-1.5">{[0, 1, 2, 3, 4, 5].map(i => <div key={i} className="rounded-sm bg-white shadow-sm" />)}</div>
    </div>
  );
  return <div className="h-28 border-b border-slate-100 p-3" style={{ background: `linear-gradient(135deg, ${c}14, #f8fafc)` }}>{inner}</div>;
}

function UnitCard({ s }: { s: SiteSummary }) {
  const mods = s.modules.filter(m => !CORE.has(m));
  return (
    <div className="group flex flex-col overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm transition hover:-translate-y-0.5 hover:shadow-lg">
      <LayoutPreview layout={s.theme?.layout} color={s.theme?.primary} />
      <div className="flex flex-1 flex-col p-5">
        <div className="flex items-start justify-between gap-2">
          <h3 className="text-base font-semibold text-slate-900">{s.name}</h3>
          <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">{s.role}</span>
        </div>
        <p className="mt-1 text-sm text-slate-500">{LAYOUT_LABEL[s.theme?.layout ?? ''] ?? 'Custom layout'} - {s.modules.length} modules</p>
        <div className="mt-3 flex flex-wrap gap-1">
          {mods.slice(0, 5).map(m => <span key={m} className="rounded-md bg-slate-50 px-1.5 py-0.5 text-[11px] text-slate-600 ring-1 ring-inset ring-slate-200">{m}</span>)}
          {mods.length > 5 && <span className="rounded-md px-1.5 py-0.5 text-[11px] text-slate-400">+{mods.length - 5} more</span>}
        </div>
        <div className="mt-auto flex gap-2 pt-5">
          <Link to={`/${s.slug}`} className={`${dark} flex-1`}>Open<ArrowRight className="h-4 w-4" /></Link>
          {s.role === 'Admin' && <Link to={`/builder/${s.id}`} className={ghost}><Layers className="h-4 w-4" />Builder</Link>}
        </div>
      </div>
    </div>
  );
}

function Stat({ icon, label, value, hint }: { icon: JSX.Element; label: string; value: string; hint: string }) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex items-center justify-between"><span className="text-sm font-medium text-slate-500">{label}</span><span className="flex h-8 w-8 items-center justify-center rounded-lg bg-slate-100 text-slate-600">{icon}</span></div>
      <div className="mt-2 text-2xl font-semibold tracking-tight text-slate-900">{value}</div>
      <div className="mt-0.5 text-xs text-slate-500">{hint}</div>
    </div>
  );
}

export default function Hub() {
  const sites = useSites();
  const user = useSession(s => s.user);
  const logout = useSession(s => s.logout);
  const switchSite = useSession(s => s.switchSite);
  useEffect(() => { switchSite(null); }, [switchSite]);
  const list = sites.data ?? [];
  const instances = list.reduce((n, s) => n + s.modules.length, 0);
  const adminOf = list.filter(s => s.role === 'Admin').length;
  const first = (user?.name ?? '').split(' ')[0];

  return (
    <div className="min-h-screen bg-slate-50">
      <header className="sticky top-0 z-30 border-b border-slate-200 bg-white/80 backdrop-blur">
        <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-6">
          <div className="flex items-center gap-3">
            <span className="flex h-9 w-9 items-center justify-center rounded-lg bg-slate-900 text-sm font-bold text-white">A</span>
            <div className="leading-tight"><div className="text-sm font-semibold text-slate-900">Axel</div><div className="text-xs text-slate-500">Operations hub</div></div>
          </div>
          <div className="flex items-center gap-2">
            <HelpButton title="The hub"><HubHelp /></HelpButton>
            {user?.hubAdmin && <Link to="/hub/ledger" className="inline-flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium text-slate-600 transition hover:bg-slate-100 hover:text-slate-900"><ShieldCheck className="h-4 w-4" />Isolation Ledger</Link>}
            <div className="ml-2 flex items-center gap-2.5 border-l border-slate-200 pl-4">
              <span className="flex h-8 w-8 items-center justify-center rounded-full bg-slate-900 text-xs font-semibold text-white">{(user?.name ?? '?').split(' ').map(w => w[0]).join('').slice(0, 2)}</span>
              <span className="hidden text-sm font-medium text-slate-700 sm:block">{user?.name}</span>
              <button onClick={logout} title="Log out" className="rounded-lg p-2 text-slate-400 transition hover:bg-slate-100 hover:text-slate-700"><LogOut className="h-4 w-4" /></button>
            </div>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-7xl space-y-8 px-6 py-8">
        <div className="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight text-slate-900">Your units</h1>
            <p className="mt-1 text-slate-500">Welcome back{first ? `, ${first}` : ''}. One login, one codebase - every unit runs its own published Blueprint. Press Ctrl+K inside a unit to switch.</p>
          </div>
          {user?.hubAdmin && <div className="flex flex-wrap items-start justify-end gap-2"><SheetUnit /><NewUnit /></div>}
        </div>

        {sites.isLoading && <div className="grid gap-5 sm:grid-cols-2 xl:grid-cols-3">{[0, 1, 2].map(i => <div key={i} className="h-72 animate-pulse rounded-2xl bg-slate-200/70" />)}</div>}
        <div className="grid gap-5 sm:grid-cols-2 xl:grid-cols-3">{list.map(s => <UnitCard key={s.id} s={s} />)}</div>

        {!!list.length && <GettingStarted sites={list} isAdmin={list.some(s => s.role === 'Admin')} />}

        {!!list.length && (
          <div>
            <h2 className="mb-4 text-lg font-semibold text-slate-900">At a glance</h2>
            <div className="grid gap-4 sm:grid-cols-3">
              <Stat icon={<LayoutGrid className="h-4 w-4" />} label="Units" value={String(list.length)} hint="Different products from one codebase" />
              <Stat icon={<Boxes className="h-4 w-4" />} label="Reuse meter" value={`${instances} instances`} hint="Powered by 13 shared module implementations" />
              <Stat icon={<Users className="h-4 w-4" />} label="Your access" value={`Admin in ${adminOf}`} hint={`Member of ${list.length} unit${list.length === 1 ? '' : 's'}`} />
            </div>
          </div>
        )}


        {user?.hubAdmin && <ChaosCard />}
      </main>
    </div>
  );
}
