# Axel - batch 2 file generator (web app + analytics + isolation tests). Run from the axel folder.
$ErrorActionPreference = 'Stop'
function W([string]$Path, [string]$Content) {
  $full = Join-Path $PSScriptRoot $Path
  New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
  $text = $Content.Replace("`r`n", "`n").TrimStart("`n") + "`n"
  [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding $false))
  Write-Host "created $Path"
}

# ============================== ROOT (updated scripts) ==============================
W 'package.json' @'
{
  "name": "axel",
  "private": true,
  "packageManager": "pnpm@9.12.0",
  "scripts": {
    "db:up": "docker compose up -d db",
    "migrate": "pnpm --filter @axel/api migrate",
    "seed": "pnpm --filter @axel/api seed",
    "dev:api": "pnpm --filter @axel/api dev",
    "dev:web": "pnpm --filter @axel/web dev",
    "test:isolation": "pnpm --filter @axel/api test:isolation"
  }
}
'@

# ============================== API additions ==============================
W 'apps/api/package.json' @'
{
  "name": "@axel/api",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "tsx watch --env-file=../../.env src/server.ts",
    "migrate": "tsx --env-file=../../.env src/migrate.ts",
    "seed": "tsx --env-file=../../.env seed/seed.ts",
    "test:isolation": "tsx --env-file=../../.env --test test/isolation.test.ts"
  },
  "dependencies": {
    "@axel/compiler": "workspace:*",
    "bcryptjs": "^2.4.3",
    "express": "^4.21.0",
    "jsonwebtoken": "^9.0.2",
    "pg": "^8.13.0",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "@types/bcryptjs": "^2.4.6",
    "@types/express": "^4.17.21",
    "@types/jsonwebtoken": "^9.0.7",
    "@types/pg": "^8.11.10",
    "tsx": "^4.19.0",
    "typescript": "^5.6.0"
  }
}
'@

W 'apps/api/src/analytics.ts' @'
import { Router } from 'express';
import { canRead } from '@axel/compiler';
import { withSite } from './db';
import { TABLES, toRecord } from './entities';
import { AxelError, ah, notFound } from './errors';

export const analytics = Router({ mergeParams: true });

// GET /api/:siteId/analytics/:widgetId - aggregates respect page visibility and column masks
analytics.get('/analytics/:widgetId', ah(async (req, res) => {
  const { compiled, role, ctx, name } = req.site!;
  const widget = compiled.renderSchema(role).pages.flatMap(p => p.widgets ?? []).find(w => w.id === req.params.widgetId);
  if (!widget) throw notFound();
  const ent = compiled.blueprint.entities[widget.entity];
  const spec = TABLES[widget.entity];
  if (!ent || !spec) throw notFound();

  for (const k of [widget.field, widget.by]) {
    if (!k || k === 'state' || k === 'month') continue;
    const f = ent.fields.find(x => x.key === k);
    if (!f || !canRead(f, role))
      throw new AxelError('FIELD_HIDDEN', 403,
        `You can't see ${f?.label ?? k} in ${name}${f?.reason ? ` (${f.reason})` : ''}. Ask a Manager.`,
        { because: { kind: 'mask', ref: k, reason: f?.reason ?? null } });
  }

  const rows = await withSite(ctx, async c => (await c.query(`SELECT * FROM ${spec.table} ORDER BY created_at LIMIT 5000`)).rows);
  const groups = new Map<string, number[]>();
  for (const row of rows) {
    const rec = compiled.computeFormulas(widget.entity, toRecord(widget.entity, row));
    const key = widget.by === 'month'
      ? new Date(rec.created_at as string).toISOString().slice(0, 7)
      : widget.by ? String(rec[widget.by] ?? 'none') : 'all';
    const v = widget.field ? Number(rec[widget.field] ?? 0) : 1;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(Number.isFinite(v) ? v : 0);
  }
  const sum = (vs: number[]) => vs.reduce((a, b) => a + b, 0);
  const agg = (vs: number[]) => widget.measure === 'count' ? vs.length : widget.measure === 'sum' ? sum(vs) : sum(vs) / (vs.length || 1);
  const data = [...groups].map(([key, vs]) => ({ key, value: Math.round(agg(vs) * 100) / 100 }));
  if (widget.by === 'month') data.sort((a, b) => a.key.localeCompare(b.key));
  res.json({ widget, data });
}));
'@

W 'apps/api/src/server.ts' @'
import express from 'express';
import { authRouter, requireAuth, memberships } from './auth';
import { sitesRouter } from './sites';
import { siteScope } from './site';
import { resources } from './resources';
import { analytics } from './analytics';
import { errorHandler, ah } from './errors';
import { pool } from './db';
import { startPublishListener } from './blueprints';

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '2mb' }));

app.get('/api/health', ah(async (_req, res) => { await pool.query('SELECT 1'); res.json({ ok: true }); }));
app.use('/api/auth', authRouter);
app.get('/api/me', requireAuth, ah(async (req, res) => {
  const u = (await pool.query('SELECT id, email, name, is_hub_admin FROM users WHERE id = $1', [req.user!.id])).rows[0];
  res.json({ user: { id: u.id, email: u.email, name: u.name, hubAdmin: u.is_hub_admin }, memberships: await memberships(u.id) });
}));
app.use('/api/sites', sitesRouter);
app.use('/api/:siteId', requireAuth, siteScope, analytics, resources);
app.use(errorHandler);

await startPublishListener();
const port = Number(process.env.PORT ?? 4000);
app.listen(port, () => console.log(`Axel API on :${port}`));
'@

W 'apps/api/test/isolation.test.ts' @'
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const CS = '11111111-1111-4111-8111-111111111111';
const SC = '22222222-2222-4222-8222-222222222222';
const DS = '33333333-3333-4333-8333-333333333333';
const SLUG: Record<string, string> = { [CS]: 'central-stores', [SC]: 'service-centre', [DS]: 'distribution' };

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  assert.equal(r.status, 200, `login ${email}`);
  return (await r.json()).token as string;
}
async function call(token: string, method: string, site: string, path: string, body?: unknown, header = site) {
  const r = await fetch(`${API}/${site}${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, 'x-site-id': header, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}

let admin = '', scManager = '', scMember = '';
const db = new pg.Client({ connectionString: process.env.DATABASE_URL_APP });

before(async () => {
  [admin, scManager, scMember] = await Promise.all(['admin@axel.dev', 'manager@sc.dev', 'member@sc.dev'].map(login));
  await db.connect();
});
after(() => db.end());

test('API: reading another site returns 404, never 403', async () => {
  for (const path of ['/items', '/components', '/items/00000000-0000-4000-8000-000000000000']) {
    const r = await call(scManager, 'GET', CS, path);
    assert.equal(r.status, 404, path);
  }
});

test('API: writing to another site is refused', async () => {
  const r = await call(scManager, 'POST', CS, '/items', { sku: 'HACK-1', name: 'x' });
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'NO_MEMBERSHIP');
});

test('API: X-Site-Id must match the URL', async () => {
  const r = await call(admin, 'GET', SC, '/items', undefined, CS);
  assert.equal(r.status, 400);
});

test('API: an entity the site does not have is 404', async () => {
  const r = await call(admin, 'GET', CS, '/requests');
  assert.equal(r.status, 404);
});

test('API: Member never receives masked fields', async () => {
  const items = await call(scMember, 'GET', SC, '/items?limit=200');
  assert.equal(items.status, 200);
  assert.ok(items.body.rows.length > 0);
  for (const row of items.body.rows) assert.ok(!('unit_price' in row), 'item.unit_price leaked');
  const reqs = await call(scMember, 'GET', SC, '/requests?limit=200');
  for (const row of reqs.body.rows) { assert.ok(!('unit_price' in row)); assert.ok(!('total' in row)); }
  const mgr = await call(scManager, 'GET', SC, '/requests?limit=200');
  assert.ok(mgr.body.rows.some((r: any) => 'total' in r), 'manager should see total');
});

test('API: Member cannot write a masked field', async () => {
  const items = await call(scMember, 'GET', SC, '/items?limit=1');
  const r = await call(scMember, 'POST', SC, '/requests', { item_id: items.body.rows[0].id, qty: 1, fault: 'test', unit_price: 1 });
  assert.equal(r.status, 422);
  assert.equal(r.body.code, 'FIELD_NOT_WRITABLE');
});

test('API: another site id is indistinguishable from a missing id (FK oracle)', async () => {
  const csItem = (await call(admin, 'GET', CS, '/items?limit=1')).body.rows[0].id;
  const a = await call(scMember, 'POST', SC, '/requests', { item_id: csItem, qty: 1, fault: 'oracle' });
  const b = await call(scMember, 'POST', SC, '/requests', { item_id: '00000000-0000-4000-8000-000000000000', qty: 1, fault: 'oracle' });
  assert.equal(a.status, 422);
  assert.deepEqual(a.body, b.body);
});

test('API: 60 interleaved requests never mix sites (pooled connections)', async () => {
  const sites = [CS, SC, DS];
  const results = await Promise.all(Array.from({ length: 60 }, (_, i) => sites[i % 3])
    .map(async s => ({ s, r: await call(admin, 'GET', s, '/items?limit=200') })));
  for (const { s, r } of results) {
    assert.equal(r.status, 200);
    const markers = r.body.rows.map((x: any) => x.name).filter((n: string) => n.startsWith('MARKER-'));
    assert.deepEqual(markers, [`MARKER-${SLUG[s]}`]);
  }
});

test('DB: no site context means zero rows, not all rows', async () => {
  for (const t of ['items', 'requests', 'stock_movements', 'audit_events', 'site_versions']) {
    const r = await db.query(`SELECT count(*)::int AS n FROM ${t}`);
    assert.equal(r.rows[0].n, 0, t);
  }
});

test('DB: context is transaction-local and cannot write into another site', async () => {
  await db.query('BEGIN');
  await db.query(`SELECT set_config('app.site_id', $1, true)`, [CS]);
  const n = (await db.query('SELECT count(*)::int AS n FROM items')).rows[0].n;
  assert.ok(n > 0);
  await assert.rejects(db.query(`INSERT INTO items (site_id, name) VALUES ($1, 'smuggled')`, [SC]), /row-level security/);
  await db.query('ROLLBACK');
  const afterTx = (await db.query('SELECT count(*)::int AS n FROM items')).rows[0].n;
  assert.equal(afterTx, 0, 'context leaked past the transaction');
});

test('DB: app role cannot bypass RLS and every business table forces it', async () => {
  const r = await db.query(`SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user`);
  assert.equal(r.rows[0].rolbypassrls, false);
  const tables = ['items', 'stock_movements', 'requests', 'approvals', 'assignments', 'consumptions', 'returns', 'repairs', 'audit_events', 'memberships', 'site_versions', 'site_deployments'];
  const t = await db.query(`SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = ANY($1) AND relkind = 'r'`, [tables]);
  assert.equal(t.rowCount, tables.length);
  for (const row of t.rows) assert.ok(row.relrowsecurity && row.relforcerowsecurity, row.relname);
});
'@

# ============================== WEB ==============================
W 'apps/web/package.json' @'
{
  "name": "@axel/web",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "dependencies": {
    "@axel/compiler": "workspace:*",
    "@tanstack/react-query": "^5.59.0",
    "axios": "^1.7.7",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-router-dom": "^6.27.0",
    "recharts": "^2.13.0",
    "zustand": "^5.0.0"
  },
  "devDependencies": {
    "@tailwindcss/vite": "^4.0.0",
    "@types/react": "^18.3.11",
    "@types/react-dom": "^18.3.1",
    "@vitejs/plugin-react": "^4.3.3",
    "tailwindcss": "^4.0.0",
    "typescript": "^5.6.0",
    "vite": "^5.4.10"
  }
}
'@

W 'apps/web/tsconfig.json' @'
{
  "extends": "../../tsconfig.json",
  "compilerOptions": { "jsx": "react-jsx", "lib": ["ES2022", "DOM", "DOM.Iterable"], "noEmit": true },
  "include": ["src"]
}
'@

W 'apps/web/vite.config.ts' @'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwind from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwind()],
  server: { port: 5173, proxy: { '/api': 'http://localhost:4000' } },
});
'@

W 'apps/web/index.html' @'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Axel</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
'@

W 'apps/web/src/index.css' @'
@import "tailwindcss";

/* Site theme tokens arrive as CSS variables set by SiteShell */
@theme inline {
  --color-primary: var(--primary, #4f46e5);
  --color-surface: var(--surface, #f8fafc);
  --radius-site: var(--radius, 8px);
}

body { margin: 0; font-family: Inter, system-ui, sans-serif; }
'@

W 'apps/web/src/queryClient.ts' @'
import { QueryClient } from '@tanstack/react-query';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      staleTime: 10_000,
      retry: (n, e: any) => {
        if (e?.message === 'stale-site-response') return false;
        if (e?.response && e.response.status < 500) return false;
        return n < 2;
      },
    },
  },
});
'@

W 'apps/web/src/store/session.ts' @'
import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import { queryClient } from '../queryClient';

export interface User { id: string; email: string; name: string; hubAdmin: boolean }

// Query keys that are not site-scoped survive a switch; everything else is removed.
const GLOBAL_KEYS = new Set(['sites', 'me']);

interface Session {
  token: string | null;
  user: User | null;
  activeSiteId: string | null;
  generation: number;
  login(token: string, user: User): void;
  logout(): void;
  switchSite(id: string | null): void;
}

export const useSession = create<Session>()(persist((set, get) => ({
  token: null,
  user: null,
  activeSiteId: null,
  generation: 0,
  login: (token, user) => {
    queryClient.clear();
    set({ token, user, activeSiteId: null, generation: get().generation + 1 });
  },
  logout: () => {
    queryClient.clear();
    set({ token: null, user: null, activeSiteId: null, generation: get().generation + 1 });
  },
  switchSite: id => {
    if (get().activeSiteId === id) return;
    // remove (not invalidate) so no row from the previous site can ever paint
    queryClient.removeQueries({ predicate: q => !GLOBAL_KEYS.has(String(q.queryKey[0])) });
    set({ activeSiteId: id, generation: get().generation + 1 });
  },
}), { name: 'axel-session', partialize: s => ({ token: s.token, user: s.user }) as any }));
'@

W 'apps/web/src/api.ts' @'
import axios from 'axios';
import { useSession } from './store/session';

export const STALE = 'stale-site-response';
export const http = axios.create({ baseURL: '/api' });

http.interceptors.request.use(cfg => {
  const t = useSession.getState().token;
  if (t) cfg.headers.set('Authorization', `Bearer ${t}`);
  return cfg;
});
http.interceptors.response.use(r => r, e => {
  if (e.response?.status === 401 && !String(e.config?.url).includes('/auth/login')) useSession.getState().logout();
  return Promise.reject(e);
});

const h = (siteId: string) => ({ headers: { 'X-Site-Id': siteId } });

// Discard any response that started before a site switch.
async function guard<T>(p: () => Promise<T>): Promise<T> {
  const g = useSession.getState().generation;
  const r = await p();
  if (useSession.getState().generation !== g) throw new Error(STALE);
  return r;
}

export const site = {
  get: <T = any>(siteId: string, path: string, params?: object) =>
    guard(() => http.get<T>(`/${siteId}${path}`, { ...h(siteId), params }).then(r => r.data)),
  post: <T = any>(siteId: string, path: string, body?: unknown) =>
    http.post<T>(`/${siteId}${path}`, body, h(siteId)).then(r => r.data),
  patch: <T = any>(siteId: string, path: string, body?: unknown) =>
    http.patch<T>(`/${siteId}${path}`, body, h(siteId)).then(r => r.data),
  schema: (siteId: string) =>
    guard(() => http.get(`/sites/${siteId}/render-schema`, h(siteId)).then(r => r.data)),
};

export interface ApiErr {
  message: string; code?: string;
  errors?: { field: string; message: string }[];
  because?: Record<string, unknown>; suggestion?: string;
}
export const errOf = (e: any): ApiErr => ({
  message: e?.response?.data?.message ?? e?.message ?? 'Something went wrong.',
  code: e?.response?.data?.code,
  errors: e?.response?.data?.errors,
  because: e?.response?.data?.because,
  suggestion: e?.response?.data?.suggestion,
});
'@

W 'apps/web/src/hooks.ts' @'
import { createContext, useContext } from 'react';
import { useQuery } from '@tanstack/react-query';
import type { RenderSchema } from '@axel/compiler';
import { http, site } from './api';

export interface SiteSummary {
  id: string; slug: string; name: string; role: string; versionId: string;
  theme?: { primary: string; layout: string }; modules: string[];
}
export type Schema = RenderSchema & { versionId: string };

export const RANK: Record<string, number> = { Public: 0, Member: 1, Manager: 2, Admin: 3 };

export const useSites = () =>
  useQuery({ queryKey: ['sites'], queryFn: () => http.get<SiteSummary[]>('/sites').then(r => r.data) });

export const useSchema = (siteId: string) =>
  useQuery({ queryKey: ['schema', siteId], queryFn: () => site.schema(siteId) as Promise<Schema> });

// Every site-scoped key starts with [entity, siteId] so a switch can never reuse another site's cache.
export const useList = (siteId: string, entity: string, params: Record<string, unknown> = {}, enabled = true) =>
  useQuery({
    queryKey: [entity, siteId, 'list', params],
    queryFn: () => site.get(siteId, `/${entity}`, { limit: 200, ...params }),
    enabled,
  });

export const useRecord = (siteId: string, entity: string, id: string) =>
  useQuery({ queryKey: [entity, siteId, 'one', id], queryFn: () => site.get(siteId, `/${entity}/${id}`) });

export interface SiteCtxValue { siteId: string; slug: string; name: string; base: string; schema: Schema }
export const SiteCtx = createContext<SiteCtxValue | null>(null);
export const useSite = () => {
  const v = useContext(SiteCtx);
  if (!v) throw new Error('useSite used outside a site');
  return v;
};
'@

W 'apps/web/src/main.tsx' @'
import React from 'react';
import ReactDOM from 'react-dom/client';
import { QueryClientProvider } from '@tanstack/react-query';
import { BrowserRouter } from 'react-router-dom';
import { queryClient } from './queryClient';
import App from './App';
import './index.css';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  </React.StrictMode>,
);
'@

W 'apps/web/src/App.tsx' @'
import { Navigate, Route, Routes } from 'react-router-dom';
import { useSession } from './store/session';
import Login from './pages/Login';
import Hub from './pages/Hub';
import SiteShell from './renderer/SiteShell';

export default function App() {
  const token = useSession(s => s.token);
  return (
    <Routes>
      <Route path="/login" element={token ? <Navigate to="/" replace /> : <Login />} />
      <Route path="/" element={token ? <Hub /> : <Navigate to="/login" replace />} />
      <Route path="/:slug/*" element={token ? <SiteShell /> : <Navigate to="/login" replace />} />
    </Routes>
  );
}
'@

W 'apps/web/src/pages/Login.tsx' @'
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { http, errOf } from '../api';
import { useSession } from '../store/session';

const DEMO: [string, string][] = [
  ['admin@axel.dev', 'Hub admin (all sites)'],
  ['manager@sc.dev', 'Service Centre manager'],
  ['member@sc.dev', 'Service Centre member'],
  ['manager@cs.dev', 'Central Stores manager'],
  ['member@cs.dev', 'Central Stores member'],
  ['field@dist.dev', 'Distribution field member'],
];

export default function Login() {
  const [email, setEmail] = useState('admin@axel.dev');
  const [password, setPassword] = useState('demo1234');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const login = useSession(s => s.login);
  const nav = useNavigate();

  async function submit(em = email) {
    setErr(''); setBusy(true);
    try {
      const r = await http.post('/auth/login', { email: em, password });
      login(r.data.token, r.data.user);
      nav('/');
    } catch (e) {
      setErr(errOf(e).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-md space-y-6">
        <div className="text-center">
          <div className="text-3xl font-bold tracking-tight">Axel</div>
          <div className="text-sm text-slate-500">Every site proven before it runs.</div>
        </div>
        <form onSubmit={e => { e.preventDefault(); submit(); }} className="space-y-3 rounded-xl border bg-white p-6 shadow-sm">
          <label className="block text-sm">
            <span className="mb-1 block text-slate-600">Email</span>
            <input value={email} onChange={e => setEmail(e.target.value)} className="w-full rounded-lg border px-3 py-2" />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-slate-600">Password</span>
            <input type="password" value={password} onChange={e => setPassword(e.target.value)} className="w-full rounded-lg border px-3 py-2" />
          </label>
          {err && <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
          <button disabled={busy} className="w-full rounded-lg bg-slate-900 py-2 font-medium text-white disabled:opacity-50">
            {busy ? 'Signing in...' : 'Sign in'}
          </button>
        </form>
        <div className="rounded-xl border bg-white p-4">
          <div className="mb-2 text-xs font-medium uppercase text-slate-400">Demo accounts (password demo1234)</div>
          <div className="grid gap-1">
            {DEMO.map(([em, label]) => (
              <button key={em} onClick={() => { setEmail(em); submit(em); }} className="flex justify-between rounded-lg px-3 py-1.5 text-left text-sm hover:bg-slate-50">
                <span>{label}</span><span className="text-slate-400">{em}</span>
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
'@

W 'apps/web/src/pages/Hub.tsx' @'
import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import { useSites } from '../hooks';
import { useSession } from '../store/session';

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
      </main>
    </div>
  );
}
'@

W 'apps/web/src/renderer/fields.tsx' @'
import type { ReactNode } from 'react';
import { useList, useSite, type Schema } from '../hooks';
import type { ApiErr } from '../api';

export type F = Schema['entities'][string]['fields'][number];

export const btn = 'rounded-site bg-primary px-3 py-1.5 text-sm font-medium text-white hover:opacity-90 disabled:opacity-50';
export const btnGhost = 'rounded-site border border-slate-300 bg-white px-3 py-1.5 text-sm hover:bg-slate-50 disabled:opacity-50';
const inputCls = 'w-full rounded-site border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary/40';

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', maximumFractionDigits: 2 });
export const money = (v: unknown) => inr.format(Number(v));

export const labelOf = (r: any): string =>
  r?.name ?? r?.serial_no ?? r?.sku ?? r?.site_location ?? r?.fault ?? (r?.id ? String(r.id).slice(0, 8) : '');

export function useLabels(target?: string) {
  const { siteId } = useSite();
  const q = useList(siteId, target ?? '', {}, !!target);
  const rows: any[] = q.data?.rows ?? [];
  const map = new Map<string, string>(rows.map(r => [r.id, labelOf(r)]));
  return { map, rows };
}

export function StateBadge({ state }: { state: unknown }) {
  return (
    <span className="inline-block rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
      {String(state).replace(/_/g, ' ')}
    </span>
  );
}

function RelationCell({ to, value }: { to?: string; value: string }) {
  const { map } = useLabels(to);
  return <>{map.get(value) ?? String(value).slice(0, 8)}</>;
}

export function Cell({ field, value }: { field: F; value: unknown }): ReactNode {
  if (value == null || value === '') return <span className="text-slate-300">-</span>;
  if (field.key === 'state') return <StateBadge state={value} />;
  switch (field.type) {
    case 'relation': return <RelationCell to={field.to} value={String(value)} />;
    case 'money': return <>{money(value)}</>;
    case 'formula': return <>{field.expr?.includes('price') ? money(value) : String(value)}</>;
    case 'boolean': return <>{value ? 'Yes' : 'No'}</>;
    case 'date': return <>{new Date(String(value)).toLocaleDateString()}</>;
    default: return <>{String(value)}</>;
  }
}

function RelationSelect({ field, value, onChange }: { field: F; value: any; onChange: (v: any) => void }) {
  const { rows } = useLabels(field.to);
  return (
    <select value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls}>
      <option value="">Select...</option>
      {rows.map(r => (
        <option key={r.id} value={r.id}>
          {labelOf(r)}{r.available != null ? ` (${r.available} available)` : ''}
        </option>
      ))}
    </select>
  );
}

export function Input({ field, value, onChange }: { field: F; value: any; onChange: (v: any) => void }) {
  switch (field.type) {
    case 'select':
      return (
        <select value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls}>
          <option value="">Select...</option>
          {field.options?.map(o => <option key={o} value={o}>{o}</option>)}
        </select>
      );
    case 'relation': return <RelationSelect field={field} value={value} onChange={onChange} />;
    case 'boolean': return <input type="checkbox" checked={!!value} onChange={e => onChange(e.target.checked)} className="h-4 w-4" />;
    case 'number':
    case 'money':
      return <input type="number" step="any" min={field.min} max={field.max} value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls} />;
    case 'date': return <input type="date" value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls} />;
    default: return <input value={value ?? ''} onChange={e => onChange(e.target.value)} className={inputCls} />;
  }
}

export function columnFields(ent: Schema['entities'][string], columns?: string[]): F[] {
  const by = new Map(ent.fields.map(f => [f.key, f]));
  const keys = columns ?? ent.fields.map(f => f.key);
  return keys
    .map(k => by.get(k) ?? (k === 'state' ? ({ key: 'state', type: 'text', label: 'State', readonly: true } as F) : null))
    .filter(Boolean) as F[];
}

export function Denial({ err }: { err: ApiErr }) {
  return (
    <div className="rounded-site border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
      <div className="font-medium">{err.message}</div>
      {err.suggestion && <div className="text-amber-700">{err.suggestion}</div>}
      {err.code && <div className="mt-1 font-mono text-[10px] text-amber-600">{err.code}</div>}
    </div>
  );
}
'@

W 'apps/web/src/renderer/RecordForm.tsx' @'
import { useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { parse, evaluate } from '@axel/compiler';
import { site, errOf, type ApiErr } from '../api';
import { useSite } from '../hooks';
import { Input, Denial, btn, btnGhost, money } from './fields';

export function RecordForm({ entity, initial, onDone, onCancel }: {
  entity: string; initial?: any; onDone?: (rec: any) => void; onCancel?: () => void;
}) {
  const { siteId, schema } = useSite();
  const qc = useQueryClient();
  const ent = schema.entities[entity];
  const editable = ent.fields.filter(f => !f.readonly);
  const formulas = ent.fields.filter(f => f.type === 'formula');
  const [vals, setVals] = useState<Record<string, any>>(() =>
    Object.fromEntries(editable.map(f => [f.key, initial?.[f.key] ?? (f.type === 'boolean' ? false : '')])));
  const [err, setErr] = useState<ApiErr | null>(null);

  const m = useMutation({
    mutationFn: () => {
      const body: Record<string, unknown> = {};
      for (const f of editable) {
        const v = vals[f.key];
        if (initial) { if (v !== (initial[f.key] ?? '')) body[f.key] = v === '' ? null : v; }
        else if (v !== '' && v != null) body[f.key] = v;
      }
      return initial
        ? site.patch(siteId, `/${entity}/${initial.id}`, { ...body, ifVersion: initial.row_version })
        : site.post(siteId, `/${entity}`, body);
    },
    onSuccess: rec => { qc.invalidateQueries({ queryKey: [entity, siteId] }); onDone?.(rec); },
    onError: e => setErr(errOf(e)),
  });

  const scope = { get: (k: string) => (vals[k] !== undefined && vals[k] !== '' ? vals[k] : initial?.[k]) };
  const fieldErr = (k: string) => err?.errors?.find(e => e.field === k)?.message;

  return (
    <form onSubmit={e => { e.preventDefault(); setErr(null); m.mutate(); }} className="space-y-3 rounded-site border bg-white p-4 shadow-sm">
      <h3 className="font-semibold">{initial ? 'Edit' : 'New'} {ent.label}</h3>
      <div className="grid gap-3 sm:grid-cols-2">
        {editable.map(f => (
          <label key={f.key} className="block">
            <span className="mb-1 block text-xs font-medium text-slate-600">{f.label}{f.required ? ' *' : ''}</span>
            <Input field={f} value={vals[f.key]} onChange={v => setVals(s => ({ ...s, [f.key]: v }))} />
            {fieldErr(f.key) && <span className="text-xs text-red-600">{fieldErr(f.key)}</span>}
          </label>
        ))}
      </div>
      {formulas.map(f => {
        let v: unknown = null;
        try { v = evaluate(parse(f.expr!), scope); } catch { v = null; }
        const shown = typeof v === 'number' && Number.isFinite(v) ? (f.expr?.includes('price') ? money(v) : String(Math.round(v * 100) / 100)) : '-';
        return (
          <div key={f.key} className="flex items-center justify-between rounded-site bg-primary/5 px-3 py-2 text-sm">
            <span>{f.label} <span className="font-mono text-xs text-slate-400">= {f.expr}</span></span>
            <b>{shown}</b>
          </div>
        );
      })}
      {err && <Denial err={err} />}
      <div className="flex gap-2">
        <button disabled={m.isPending} className={btn}>{m.isPending ? 'Saving...' : 'Save'}</button>
        {onCancel && <button type="button" onClick={onCancel} className={btnGhost}>Cancel</button>}
      </div>
    </form>
  );
}
'@

W 'apps/web/src/renderer/views.tsx' @'
import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import {
  ResponsiveContainer, BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  PieChart, Pie, Cell as Slice, LineChart, Line,
} from 'recharts';
import type { Page, Widget } from '@axel/compiler';
import { site, errOf } from '../api';
import { useList, useSite, RANK } from '../hooks';
import { Cell, columnFields, Denial, labelOf, StateBadge, btn, money } from './fields';
import { RecordForm } from './RecordForm';

function useDensity() {
  const { schema } = useSite();
  return schema.theme.density === 'compact' ? 'px-2 py-1 text-xs' : 'px-3 py-2 text-sm';
}
function canCreate(entity?: string) {
  const { schema } = useSite();
  return !!entity && RANK[schema.role] >= 1 && !!schema.entities[entity]?.fields.some(f => !f.readonly);
}

function PageHeader({ title, count, onNew }: { title: string; count?: number; onNew?: () => void }) {
  return (
    <div className="flex items-center justify-between">
      <div>
        <h1 className="text-xl font-semibold">{title}</h1>
        {count != null && <p className="text-xs text-slate-500">{count} records</p>}
      </div>
      {onNew && <button onClick={onNew} className={btn}>+ New</button>}
    </div>
  );
}

function QueryState({ q }: { q: { isLoading: boolean; error: unknown } }) {
  if (q.isLoading) return <div className="space-y-2">{[0, 1, 2, 3].map(i => <div key={i} className="h-8 animate-pulse rounded bg-slate-200" />)}</div>;
  if (q.error) return <Denial err={errOf(q.error)} />;
  return null;
}

function useCreator(entity?: string) {
  const [open, setOpen] = useState(false);
  const allowed = canCreate(entity);
  return {
    onNew: allowed ? () => setOpen(v => !v) : undefined,
    form: open && entity ? <RecordForm entity={entity} onDone={() => setOpen(false)} onCancel={() => setOpen(false)} /> : null,
  };
}

export function TableView({ page }: { page: Page }) {
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const d = useDensity();
  const entity = page.entity!;
  const ent = schema.entities[entity];
  const q = useList(siteId, entity, page.filter ? { filter: page.filter } : {});
  const c = useCreator(entity);
  const cols = columnFields(ent, page.columns);
  const rows: any[] = q.data?.rows ?? [];
  return (
    <>
      <PageHeader title={page.title} count={q.data?.total} onNew={c.onNew} />
      {c.form}
      <QueryState q={q} />
      {!q.isLoading && !q.error && (
        <div className="overflow-x-auto rounded-site border bg-white">
          <table className="w-full text-left">
            <thead className="bg-slate-50 text-slate-500">
              <tr>{cols.map(col => <th key={col.key} className={`${d} font-medium`}>{col.label}</th>)}</tr>
            </thead>
            <tbody>
              {rows.map(r => (
                <tr key={r.id} onClick={() => nav(`${base}/r/${entity}/${r.id}`)} className="cursor-pointer border-t hover:bg-primary/5">
                  {cols.map(col => <td key={col.key} className={d}><Cell field={col} value={r[col.key]} /></td>)}
                </tr>
              ))}
            </tbody>
          </table>
          {!rows.length && <div className="p-6 text-center text-sm text-slate-400">Nothing here yet.</div>}
        </div>
      )}
    </>
  );
}

export function KanbanView({ page }: { page: Page }) {
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const entity = page.entity!;
  const ent = schema.entities[entity];
  const q = useList(siteId, entity);
  const c = useCreator(entity);
  const groupBy = page.groupBy ?? 'state';
  const rows: any[] = q.data?.rows ?? [];
  const states = ent.workflow?.states ?? [...new Set(rows.map(r => String(r[groupBy])))];
  const cols = columnFields(ent, page.columns);
  return (
    <>
      <PageHeader title={page.title} count={q.data?.total} onNew={c.onNew} />
      {c.form}
      <QueryState q={q} />
      {!q.isLoading && !q.error && (
        <div className="flex gap-3 overflow-x-auto pb-2">
          {states.map(s => {
            const inCol = rows.filter(r => String(r[groupBy]) === s);
            return (
              <div key={s} className="w-72 shrink-0 rounded-site bg-slate-100 p-2">
                <div className="mb-2 flex items-center justify-between px-1">
                  <StateBadge state={s} />
                  <span className="text-xs text-slate-500">{inCol.length}</span>
                </div>
                <div className="space-y-2">
                  {inCol.map(r => (
                    <button key={r.id} onClick={() => nav(`${base}/r/${entity}/${r.id}`)}
                      className="block w-full rounded-site border-l-4 border-primary bg-white p-3 text-left text-sm shadow-sm hover:shadow">
                      <div className="font-medium">{labelOf(r)}</div>
                      {cols.slice(1).map(col => (
                        <div key={col.key} className="flex justify-between text-xs text-slate-500">
                          <span>{col.label}</span><span><Cell field={col} value={r[col.key]} /></span>
                        </div>
                      ))}
                    </button>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}

export function QueueView({ page }: { page: Page }) {
  const { siteId, schema, base } = useSite();
  const nav = useNavigate();
  const entity = page.entity!;
  const ent = schema.entities[entity];
  const q = useList(siteId, entity);
  const cols = columnFields(ent, page.columns);
  const rows: any[] = q.data?.rows ?? [];
  return (
    <>
      <PageHeader title={page.title} count={q.data?.total} />
      <QueryState q={q} />
      {!q.isLoading && !q.error && (
        <div className="space-y-2">
          {rows.map(r => (
            <div key={r.id} className="flex items-center justify-between rounded-site border-l-4 border-primary bg-white p-4 shadow-sm">
              <div className="space-y-1 text-sm">
                {cols.map(col => (
                  <div key={col.key}><span className="text-slate-400">{col.label}: </span><Cell field={col} value={r[col.key]} /></div>
                ))}
              </div>
              <button onClick={() => nav(`${base}/r/${entity}/${r.id}`)} className={btn}>Open</button>
            </div>
          ))}
          {!rows.length && (
            <div className="rounded-site border border-dashed bg-white p-8 text-center text-sm text-slate-500">
              Queue is empty. Approved requests appear here once a Manager assigns them.
            </div>
          )}
        </div>
      )}
    </>
  );
}

function WidgetCard({ w }: { w: Widget }) {
  const { siteId, schema } = useSite();
  const color = schema.theme.tokens.primary;
  const q = useQuery({ queryKey: ['analytics', siteId, w.id], queryFn: () => site.get(siteId, `/analytics/${w.id}`) });
  const data: { key: string; value: number }[] = q.data?.data ?? [];
  const isMoney = !!w.field && /price|value|total|cost/.test(w.field);
  return (
    <div className="rounded-site border bg-white p-4 shadow-sm">
      <div className="mb-3 text-sm font-medium text-slate-600">{w.title ?? w.id}</div>
      <QueryState q={q} />
      {!q.isLoading && !q.error && (
        w.type === 'stat' ? (
          <div className="text-3xl font-bold text-primary">
            {isMoney ? money(data.reduce((a, b) => a + b.value, 0)) : data.reduce((a, b) => a + b.value, 0).toLocaleString('en-IN')}
          </div>
        ) : (
          <div className="h-56">
            <ResponsiveContainer width="100%" height="100%">
              {w.type === 'pie' ? (
                <PieChart>
                  <Pie data={data} dataKey="value" nameKey="key" outerRadius={80} label={(e: any) => e.key}>
                    {data.map((_, i) => <Slice key={i} fill={color} fillOpacity={1 - i * (0.7 / Math.max(data.length, 1))} />)}
                  </Pie>
                  <Tooltip />
                </PieChart>
              ) : w.type === 'line' ? (
                <LineChart data={data}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis dataKey="key" fontSize={11} /><YAxis fontSize={11} /><Tooltip />
                  <Line dataKey="value" stroke={color} strokeWidth={2} />
                </LineChart>
              ) : (
                <BarChart data={data}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} />
                  <XAxis dataKey="key" fontSize={11} /><YAxis fontSize={11} allowDecimals={false} /><Tooltip />
                  <Bar dataKey="value" fill={color} radius={[4, 4, 0, 0]} />
                </BarChart>
              )}
            </ResponsiveContainer>
          </div>
        )
      )}
    </div>
  );
}

export function DashboardView({ page }: { page: Page }) {
  return (
    <>
      <PageHeader title={page.title} />
      <div className="grid gap-4 md:grid-cols-2">
        {(page.widgets ?? []).map(w => <WidgetCard key={w.id} w={w} />)}
      </div>
    </>
  );
}

export function PageView({ page }: { page: Page }) {
  const V = ({ table: TableView, kanban: KanbanView, queue: QueueView, dashboard: DashboardView } as Record<string, (p: { page: Page }) => JSX.Element>)[page.view] ?? TableView;
  return <div className="space-y-4"><V page={page} /></div>;
}
'@

W 'apps/web/src/renderer/RecordDetail.tsx' @'
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
'@

W 'apps/web/src/renderer/SiteShell.tsx' @'
import { useEffect, useRef, type CSSProperties, type ReactNode } from 'react';
import { Link, Navigate, NavLink, Route, Routes, useNavigate, useParams } from 'react-router-dom';
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
  const { schema } = useSite();
  const muted = dark ? 'text-white/70 hover:text-white' : 'text-slate-500 hover:text-slate-900';
  return (
    <div className="flex items-center gap-3 text-sm">
      <Link to="/" className={muted}>Hub</Link>
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

function SiteBody({ site }: { site: SiteSummary }) {
  const schema = useSchema(site.id);
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
  const sites = useSites();
  const active = useSession(s => s.activeSiteId);
  const switchSite = useSession(s => s.switchSite);
  const site = sites.data?.find(s => s.slug === slug);

  useEffect(() => { if (site) switchSite(site.id); }, [site?.id, switchSite]);

  if (sites.isLoading) return <Skeleton label="Loading" />;
  if (!site) return <div className="p-6"><Denial err={{ message: 'Not found.' }} /><Link to="/" className="text-sm underline">Back to hub</Link></div>;
  // Render nothing site-specific until the cache wipe for this site has happened.
  if (active !== site.id) return <Skeleton label={site.name} color={site.theme?.primary} />;
  return <SiteBody key={site.id} site={site} />;
}
'@

Write-Host ''
Write-Host 'Batch 2 files created. Next: pnpm install'