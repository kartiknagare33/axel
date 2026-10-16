import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { Link, Navigate, NavLink, Route, Routes, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useSchema, useSites, useSite, SiteCtx, type SiteSummary } from '../hooks';
import { useSession } from '../store/session';
import { errOf } from '../api';
import { Denial } from './fields';
import { PageView } from './views';
import { RecordDetail } from './RecordDetail';

function Skeleton({ label, color }: { label: string; color?: string }) {
  return (
    <div className="min-h-screen bg-slate-50">
      <div className="border-b bg-white px-6 py-3 font-semibold" style={{ borderTop: `3px solid ${color ?? '#cbd5e1'}` }}>{label}</div>
      <div className="space-y-2 p-6">{[0, 1, 2, 3, 4, 5].map(i => <div key={i} className="h-8 animate-pulse rounded bg-slate-200" />)}</div>
    </div>
  );
}

function SiteSwitcher({ dark }: { dark?: boolean }) {
  const sites = useSites();
  const { slug } = useSite();
  const nav = useNavigate();
  const ref = useRef<HTMLSelectElement>(null);
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        ref.current?.focus();
        (ref.current as any)?.showPicker?.();
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, []);
  return (
    <select ref={ref} value={slug} onChange={e => nav(`/${e.target.value}`)} title="Switch site (Ctrl+K)"
      className={`rounded-md px-2 py-1 text-sm ${dark ? 'border border-white/20 bg-white/10 text-white' : 'border border-slate-300 bg-white'}`}>
      {sites.data?.map(s => <option key={s.id} value={s.slug} className="text-slate-900">{s.name}</option>)}
    </select>
  );
}

function UserMenu({ dark }: { dark?: boolean }) {
  const user = useSession(s => s.user);
  const logout = useSession(s => s.logout);
  const { schema, siteId } = useSite();
  const muted = dark ? 'text-white/70 hover:text-white' : 'text-slate-500 hover:text-slate-900';
  return (
    <div className="flex items-center gap-3 text-sm">
      <Link to="/" className={muted}>Hub</Link>
      {schema.role === 'Admin' && <Link to={`/builder/${siteId}`} className={muted}>Builder</Link>}
      <span>{user?.name}</span>
      <span className={`rounded-full px-2 py-0.5 text-xs ${dark ? 'bg-white/20' : 'bg-primary/10 text-primary'}`}>{schema.role}</span>
      <button onClick={logout} className={muted}>Log out</button>
    </div>
  );
}

function NavItems({ variant }: { variant: 'sidebar' | 'top' | 'pill' | 'rail' }) {
  const { schema, base } = useSite();
  const cls = ({ isActive }: { isActive: boolean }) => ({
    sidebar: `block rounded px-3 py-1.5 text-sm ${isActive ? 'bg-primary text-white' : 'hover:bg-slate-800'}`,
    top: `border-b-2 px-1 py-3 text-sm ${isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-slate-500 hover:text-slate-900'}`,
    pill: `rounded-full px-3 py-1 text-sm ${isActive ? 'bg-white font-medium text-primary' : 'text-white/80 hover:bg-white/10'}`,
    rail: `block border-l-4 px-4 py-2 text-sm ${isActive ? 'border-primary bg-primary/5 font-medium text-primary' : 'border-transparent text-slate-600 hover:bg-slate-50'}`,
  })[variant];
  return <>{schema.nav.map(n => <NavLink key={n.path} to={base + n.path} className={cls}>{n.label}</NavLink>)}</>;
}

function SidebarLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="flex min-h-screen">
      <aside className="flex w-56 shrink-0 flex-col bg-slate-900 text-slate-300">
        <div className="flex items-center gap-2 px-4 py-4 font-semibold text-white"><span className="h-3 w-3 rounded-sm bg-primary" />{name}</div>
        <nav className="flex flex-col gap-0.5 px-2"><NavItems variant="sidebar" /></nav>
        <div className="mt-auto p-3"><SiteSwitcher dark /></div>
      </aside>
      <div className="min-w-0 flex-1">
        <header className="flex justify-end border-b bg-white px-4 py-2"><UserMenu /></header>
        <main className="p-4">{children}</main>
      </div>
    </div>
  );
}

function TopbarLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="min-h-screen">
      <header className="flex items-center gap-6 border-b bg-white px-6">
        <div className="py-3 font-semibold">{name}</div>
        <nav className="flex gap-4"><NavItems variant="top" /></nav>
        <div className="ml-auto flex items-center gap-4"><SiteSwitcher /><UserMenu /></div>
      </header>
      <main className="mx-auto max-w-6xl p-6">{children}</main>
    </div>
  );
}

function KanbanFirstLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="min-h-screen">
      <header className="flex items-center gap-6 bg-primary px-6 py-3 text-white">
        <div className="text-lg font-semibold">{name}</div>
        <nav className="flex gap-1"><NavItems variant="pill" /></nav>
        <div className="ml-auto flex items-center gap-4"><SiteSwitcher dark /><UserMenu dark /></div>
      </header>
      <main className="p-6">{children}</main>
    </div>
  );
}

function QueueFirstLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="flex min-h-screen">
      <aside className="w-64 shrink-0 border-r bg-white">
        <div className="bg-primary/10 px-4 py-4">
          <div className="font-semibold text-primary">{name}</div>
          <div className="mt-2"><SiteSwitcher /></div>
        </div>
        <nav className="py-2"><NavItems variant="rail" /></nav>
      </aside>
      <div className="min-w-0 flex-1">
        <header className="flex justify-end border-b bg-white px-6 py-2"><UserMenu /></header>
        <main className="p-6">{children}</main>
      </div>
    </div>
  );
}

const LAYOUTS: Record<string, (p: { children: ReactNode }) => JSX.Element> = {
  sidebar: SidebarLayout,
  topbar: TopbarLayout,
  'kanban-first': KanbanFirstLayout,
  'queue-first': QueueFirstLayout,
};

// Live updates: a publish or a record change on this site refreshes what is on screen.
function useLive(siteId: string, enabled: boolean, onPublished: () => void) {
  const qc = useQueryClient();
  useEffect(() => {
    const token = useSession.getState().token;
    if (!enabled || !token) return;
    const es = new EventSource(`/api/events?token=${encodeURIComponent(token)}`);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const refresh = () => { clearTimeout(timer); timer = setTimeout(() => qc.invalidateQueries({ predicate: q => q.queryKey[1] === siteId }), 300); };
    es.addEventListener('site_published', (e: MessageEvent) => {
      if (JSON.parse(e.data).siteId !== siteId) return;
      qc.invalidateQueries({ predicate: q => q.queryKey[1] === siteId });
      qc.invalidateQueries({ queryKey: ['sites'] });
      onPublished();
    });
    es.addEventListener('record_changed', (e: MessageEvent) => { if (JSON.parse(e.data).siteId === siteId) refresh(); });
    return () => { clearTimeout(timer); es.close(); };
  }, [siteId, enabled]);
}

function SiteBody({ site, preview }: { site: SiteSummary; preview: string | null }) {
  const schema = useSchema(site.id);
  const nav = useNavigate();
  const switchSite = useSession(s => s.switchSite);
  const [toast, setToast] = useState('');
  useLive(site.id, !preview, () => { setToast('This site was just updated to a new version.'); setTimeout(() => setToast(''), 6000); });

  if (schema.isLoading) return <Skeleton label={site.name} color={site.theme?.primary} />;
  if (schema.error || !schema.data) return <div className="p-6"><Denial err={errOf(schema.error)} /></div>;
  const s = schema.data;
  const base = `/${site.slug}`;
  const home = s.pages.some(p => p.path === s.theme.home) ? s.theme.home : s.pages[0]?.path ?? '/';
  const style = {
    '--primary': s.theme.tokens.primary,
    '--surface': s.theme.tokens.surface,
    '--radius': s.theme.tokens.radius,
    fontFamily: s.theme.tokens.font,
  } as CSSProperties;
  const Layout = LAYOUTS[s.theme.layout] ?? TopbarLayout;

  return (
    <SiteCtx.Provider value={{ siteId: site.id, slug: site.slug, name: s.name, base, schema: s }}>
      <div style={style} className="min-h-screen bg-surface text-slate-800">
        {preview && (
          <div className="sticky top-0 z-50 flex items-center justify-between bg-amber-400 px-4 py-1.5 text-sm text-amber-950">
            <span><b>Previewing draft</b> - read-only, using live data. Nothing here is saved.</span>
            <button onClick={() => { switchSite(site.id, null); nav(base); }} className="rounded bg-amber-950 px-2 py-0.5 text-xs text-white">Exit preview</button>
          </div>
        )}
        {toast && <div className="fixed bottom-4 right-4 z-50 rounded-lg bg-slate-900 px-4 py-2 text-sm text-white shadow-lg">{toast}</div>}
        <Layout>
          <Routes>
            <Route index element={<Navigate to={base + home} replace />} />
            {s.pages.map(p => <Route key={p.path} path={p.path.replace(/^\//, '')} element={<PageView page={p} />} />)}
            <Route path="r/:entity/:id" element={<RecordDetail />} />
            <Route path="*" element={<Denial err={{ message: 'That page is not part of this site.' }} />} />
          </Routes>
        </Layout>
      </div>
    </SiteCtx.Provider>
  );
}

export default function SiteShell() {
  const { slug } = useParams();
  const [params] = useSearchParams();
  const sites = useSites();
  const active = useSession(s => s.activeSiteId);
  const storePreview = useSession(s => s.preview);
  const switchSite = useSession(s => s.switchSite);
  const site = sites.data?.find(s => s.slug === slug);
  const wantPreview = params.get('preview') ?? (site && active === site.id ? storePreview : null);

  useEffect(() => { if (site) switchSite(site.id, wantPreview); }, [site?.id, wantPreview, switchSite]);

  if (sites.isLoading) return <Skeleton label="Loading" />;
  if (!site) return <div className="p-6"><Denial err={{ message: 'Not found.' }} /><Link to="/" className="text-sm underline">Back to hub</Link></div>;
  // Render nothing site-specific until the cache wipe for this site (and version) has happened.
  if (active !== site.id || storePreview !== wantPreview) return <Skeleton label={site.name} color={site.theme?.primary} />;
  return <SiteBody key={`${site.id}:${wantPreview ?? 'live'}`} site={site} preview={wantPreview} />;
}
