import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import { useSites } from '../hooks';
import { useSession } from '../store/session';
import { ChaosCard } from './Chaos';

const CORE = new Set(['auth', 'users', 'dashboard']);

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
          <span>{user?.name}</span>
          <button onClick={logout} className="text-slate-500 hover:text-slate-900">Log out</button>
        </div>
      </header>
      <main className="mx-auto max-w-5xl space-y-6 p-6">
        <div>
          <h1 className="text-2xl font-semibold">Your units</h1>
          <p className="text-sm text-slate-500">One login, one codebase. Each unit runs its own published Blueprint.</p>
        </div>
        {sites.isLoading && <div className="h-32 animate-pulse rounded-xl bg-slate-200" />}
        <div className="grid gap-4 sm:grid-cols-3">
          {sites.data?.map(s => (
            <Link key={s.id} to={`/${s.slug}`} className="rounded-xl border bg-white p-5 shadow-sm transition hover:shadow-md">
              <div className="h-2 w-12 rounded-full" style={{ background: s.theme?.primary }} />
              <h2 className="mt-3 text-lg font-semibold">{s.name}</h2>
              <p className="text-xs text-slate-500">{s.theme?.layout} layout - {s.modules.length} modules - you are {s.role}</p>
              <div className="mt-3 flex flex-wrap gap-1">
                {s.modules.filter(m => !CORE.has(m)).map(m => (
                  <span key={m} className="rounded bg-slate-100 px-1.5 py-0.5 text-[10px] text-slate-600">{m}</span>
                ))}
              </div>
            </Link>
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
