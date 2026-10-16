import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { Link, Navigate, NavLink, Route, Routes, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import {
  Activity, Building2, ChevronDown, Circle, ClipboardList, Columns3, Eye, History, Layers, LayoutDashboard,
  LayoutGrid, ListTodo, LogOut, Package, Sparkles, Table2, Undo2, Wrench, type LucideIcon,
} from 'lucide-react';
import { useSchema, useSites, useSite, SiteCtx, type SiteSummary, type Schema } from '../hooks';
import { useSession } from '../store/session';
import { errOf } from '../api';
import { Denial } from './fields';
import { PageView } from './views';
import { RecordDetail } from './RecordDetail';
import { SerialTimeline } from './SerialTimeline';
import { markDone } from '../help/progress';
import { HelpButton } from '../help/HelpPanel';
import { SiteHelp } from '../help/content';

const initials = (s: string) => s.split(/\s+/).filter(Boolean).map(w => w[0]).join('').slice(0, 2).toUpperCase();

function Mark({ light }: { light?: boolean }) {
  const { name } = useSite();
  return (
    <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-sm font-bold ${light ? 'bg-white/15 text-white ring-1 ring-inset ring-white/20' : 'bg-primary text-white shadow-sm'}`}>
      {initials(name)}
    </span>
  );
}

function Skeleton({ label, color }: { label: string; color?: string }) {
  return (
    <div className="min-h-screen bg-slate-50">
      <div className="flex h-14 items-center gap-3 border-b border-slate-200 bg-white px-6">
        <span className="h-8 w-8 animate-pulse rounded-lg" style={{ background: color ?? '#cbd5e1' }} />
        <span className="text-sm font-semibold text-slate-700">{label}</span>
      </div>
      <div className="mx-auto max-w-7xl space-y-3 p-6">
        <div className="h-8 w-56 animate-pulse rounded-lg bg-slate-200" />
        {[0, 1, 2, 3, 4].map(i => <div key={i} className="h-12 animate-pulse rounded-xl bg-slate-200/70" />)}
      </div>
    </div>
  );
}

function iconFor(schema: Schema, path: string): LucideIcon {
  if (path === '/timeline') return History;
  const p = schema.pages.find(x => x.path === path);
  if (!p) return Circle;
  if (p.view === 'dashboard') return LayoutDashboard;
  if (p.view === 'kanban') return Columns3;
  if (p.view === 'queue') return ListTodo;
  if (p.path.includes('return')) return Undo2;
  return ({ item: Package, request: ClipboardList, repair: Wrench, consumption: Activity, assignment: ListTodo } as Record<string, LucideIcon>)[p.entity ?? ''] ?? Table2;
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
    <div className="relative w-full">
      <Building2 className={`pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 ${dark ? 'text-white/60' : 'text-slate-400'}`} />
      <select ref={ref} value={slug} onChange={e => nav(`/${e.target.value}`)} title="Switch unit (Ctrl+K)"
        className={`w-full cursor-pointer appearance-none rounded-lg py-1.5 pl-8 pr-8 text-sm font-medium outline-none transition ${dark ? 'border border-white/15 bg-white/10 text-white hover:bg-white/15' : 'border border-slate-200 bg-white text-slate-700 shadow-sm hover:border-slate-300'}`}>
        {sites.data?.map(s => <option key={s.id} value={s.slug} className="text-slate-900">{s.name}</option>)}
      </select>
      <ChevronDown className={`pointer-events-none absolute right-2.5 top-1/2 h-4 w-4 -translate-y-1/2 ${dark ? 'text-white/60' : 'text-slate-400'}`} />
    </div>
  );
}

function UserMenu({ dark }: { dark?: boolean }) {
  const user = useSession(s => s.user);
  const logout = useSession(s => s.logout);
  const { schema, siteId } = useSite();
  const link = `inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-sm font-medium transition ${dark ? 'text-white/80 hover:bg-white/10 hover:text-white' : 'text-slate-500 hover:bg-slate-100 hover:text-slate-900'}`;
  return (
    <div className="flex items-center gap-1">
      <HelpButton title="What can I do here?" dark={dark}><SiteHelp /></HelpButton>
      <Link to="/" className={link}><LayoutGrid className="h-4 w-4" />Hub</Link>
      {schema.role === 'Admin' && <Link to={`/builder/${siteId}`} className={link}><Layers className="h-4 w-4" />Builder</Link>}
      <div className={`ml-2 flex items-center gap-2.5 border-l pl-3 ${dark ? 'border-white/15' : 'border-slate-200'}`}>
        <span className={`flex h-8 w-8 items-center justify-center rounded-full text-xs font-semibold ${dark ? 'bg-white/20 text-white' : 'bg-primary/10 text-primary'}`}>{initials(user?.name ?? '?')}</span>
        <div className="hidden leading-tight md:block">
          <div className={`text-sm font-medium ${dark ? 'text-white' : 'text-slate-800'}`}>{user?.name}</div>
          <div className={`text-xs ${dark ? 'text-white/60' : 'text-slate-500'}`}>{schema.role}</div>
        </div>
        <button onClick={logout} title="Log out" className={`ml-1 rounded-lg p-2 transition ${dark ? 'text-white/70 hover:bg-white/10 hover:text-white' : 'text-slate-400 hover:bg-slate-100 hover:text-slate-700'}`}><LogOut className="h-4 w-4" /></button>
      </div>
    </div>
  );
}

function NavItems({ variant }: { variant: 'sidebar' | 'top' | 'pill' | 'rail' }) {
  const { schema, base } = useSite();
  const items = schema.modules.includes('pcb-repair') ? [...schema.nav, { label: 'Board history', path: '/timeline' }] : schema.nav;
  const cls = (a: boolean) => ({
    sidebar: `flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition ${a ? 'bg-white/10 text-white' : 'text-slate-400 hover:bg-white/5 hover:text-slate-100'}`,
    top: `flex items-center gap-2 border-b-2 px-1 py-[18px] text-sm font-medium transition ${a ? 'border-primary text-slate-900' : 'border-transparent text-slate-500 hover:text-slate-900'}`,
    pill: `flex items-center gap-2 rounded-full px-3.5 py-1.5 text-sm font-medium transition ${a ? 'bg-white text-primary shadow-sm' : 'text-white/80 hover:bg-white/10 hover:text-white'}`,
    rail: `flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition ${a ? 'bg-primary/10 text-primary' : 'text-slate-600 hover:bg-slate-100 hover:text-slate-900'}`,
  })[variant];
  return (
    <>
      {items.map(n => {
        const Icon = iconFor(schema, n.path);
        return (
          <NavLink key={n.path} to={base + n.path} className={({ isActive }) => cls(isActive)}>
            {({ isActive }) => <><Icon className={`h-4 w-4 shrink-0 ${variant === 'sidebar' && isActive ? 'text-primary' : ''}`} /><span>{n.label}</span></>}
          </NavLink>
        );
      })}
    </>
  );
}

function TopBar() {
  const { name } = useSite();
  return (
    <header className="sticky top-0 z-30 flex h-14 items-center justify-between border-b border-slate-200/80 bg-white/80 px-6 backdrop-blur">
      <div className="flex items-center gap-2 text-sm">
        <Link to="/" className="text-slate-400 transition hover:text-slate-700">Hub</Link>
        <span className="text-slate-300">/</span>
        <span className="font-medium text-slate-700">{name}</span>
      </div>
      <UserMenu />
    </header>
  );
}

function SidebarLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="flex min-h-screen">
      <aside className="sticky top-0 flex h-screen w-64 shrink-0 flex-col bg-slate-950">
        <div className="flex items-center gap-3 px-5 py-5">
          <Mark />
          <div className="min-w-0">
            <div className="truncate text-sm font-semibold text-white">{name}</div>
            <div className="text-xs text-slate-500">Operations unit</div>
          </div>
        </div>
        <div className="px-5 pb-2 text-[11px] font-semibold uppercase tracking-wider text-slate-600">Menu</div>
        <nav className="flex-1 space-y-0.5 px-3"><NavItems variant="sidebar" /></nav>
        <div className="border-t border-white/5 p-3"><SiteSwitcher dark /></div>
      </aside>
      <div className="min-w-0 flex-1">
        <TopBar />
        <main className="mx-auto max-w-7xl px-6 py-6">{children}</main>
      </div>
    </div>
  );
}

function TopbarLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-30 border-b border-slate-200 bg-white/90 backdrop-blur">
        <div className="mx-auto flex max-w-7xl items-center gap-6 px-6">
          <div className="flex items-center gap-3 py-3"><Mark /><span className="text-sm font-semibold text-slate-900">{name}</span></div>
          <nav className="flex gap-5"><NavItems variant="top" /></nav>
          <div className="ml-auto flex items-center gap-3"><div className="w-48"><SiteSwitcher /></div><UserMenu /></div>
        </div>
      </header>
      <main className="mx-auto max-w-7xl px-6 py-6">{children}</main>
    </div>
  );
}

function KanbanFirstLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-30 bg-primary text-white shadow-sm">
        <div className="flex items-center gap-6 px-6 py-3">
          <div className="flex items-center gap-3"><Mark light /><span className="text-base font-semibold">{name}</span></div>
          <nav className="flex flex-wrap gap-1"><NavItems variant="pill" /></nav>
          <div className="ml-auto flex items-center gap-3"><div className="w-48"><SiteSwitcher dark /></div><UserMenu dark /></div>
        </div>
      </header>
      <main className="px-6 py-6">{children}</main>
    </div>
  );
}

function QueueFirstLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="flex min-h-screen">
      <aside className="sticky top-0 flex h-screen w-64 shrink-0 flex-col border-r border-slate-200 bg-white">
        <div className="border-b border-slate-100 bg-primary/5 px-4 py-4">
          <div className="flex items-center gap-3">
            <Mark />
            <div className="min-w-0">
              <div className="truncate text-sm font-semibold text-slate-900">{name}</div>
              <div className="text-xs text-slate-500">Field operations</div>
            </div>
          </div>
          <div className="mt-3"><SiteSwitcher /></div>
        </div>
        <nav className="flex-1 space-y-0.5 p-3"><NavItems variant="rail" /></nav>
      </aside>
      <div className="min-w-0 flex-1">
        <TopBar />
        <main className="mx-auto max-w-6xl px-6 py-6">{children}</main>
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
  useEffect(() => { markDone('openedUnit'); }, []);
  useLive(site.id, !preview, () => { setToast('This unit was just updated to a new version.'); setTimeout(() => setToast(''), 6000); });

  if (schema.isLoading) return <Skeleton label={site.name} color={site.theme?.primary} />;
  if (schema.error || !schema.data) return <div className="p-6"><Denial err={errOf(schema.error)} /></div>;
  const s = schema.data;
  const base = `/${site.slug}`;
  const home = s.pages.some(p => p.path === s.theme.home) ? s.theme.home : s.pages[0]?.path ?? '/';
  const style = {
    '--primary': s.theme.tokens.primary,
    '--surface': s.theme.tokens.surface,
    '--radius': s.theme.tokens.radius,
    fontFamily: `'Inter Variable', ${s.theme.tokens.font}, ui-sans-serif, system-ui, sans-serif`,
  } as CSSProperties;
  const Layout = LAYOUTS[s.theme.layout] ?? TopbarLayout;

  return (
    <SiteCtx.Provider value={{ siteId: site.id, slug: site.slug, name: s.name, base, schema: s }}>
      <div style={style} className="min-h-screen bg-surface text-slate-800">
        {preview && (
          <div className="sticky top-0 z-50 flex items-center justify-between gap-3 bg-amber-400 px-4 py-2 text-sm text-amber-950">
            <span className="flex items-center gap-2"><Eye className="h-4 w-4" /><b>Previewing a draft</b> - read-only, using live data. Nothing here is saved.</span>
            <button onClick={() => { switchSite(site.id, null); nav(base); }} className="rounded-md bg-amber-950 px-2.5 py-1 text-xs font-medium text-white">Exit preview</button>
          </div>
        )}
        {toast && (
          <div className="fixed bottom-5 right-5 z-50 flex items-center gap-3 rounded-xl bg-slate-900 px-4 py-3 text-sm text-white shadow-xl">
            <Sparkles className="h-4 w-4 text-amber-300" />{toast}
          </div>
        )}
        <Layout>
          <Routes>
            <Route index element={<Navigate to={base + home} replace />} />
            {s.pages.map(p => <Route key={p.path} path={p.path.replace(/^\//, '')} element={<PageView page={p} />} />)}
            <Route path="r/:entity/:id" element={<RecordDetail />} />
            <Route path="timeline" element={<SerialTimeline />} />
            <Route path="*" element={<Denial err={{ message: 'That page is not part of this unit.' }} />} />
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
  if (!site) return <div className="space-y-3 p-6"><Denial err={{ message: 'Not found.' }} /><Link to="/" className="text-sm text-slate-600 underline">Back to hub</Link></div>;
  // Render nothing site-specific until the cache wipe for this site (and version) has happened.
  if (active !== site.id || storePreview !== wantPreview) return <Skeleton label={site.name} color={site.theme?.primary} />;
  return <SiteBody key={`${site.id}:${wantPreview ?? 'live'}`} site={site} preview={wantPreview} />;
}
