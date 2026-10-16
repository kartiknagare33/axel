import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { finishLogin } from './otp';
import pg from 'pg';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const CS = '11111111-1111-4111-8111-111111111111';
const SC = '22222222-2222-4222-8222-222222222222';
const DS = '33333333-3333-4333-8333-333333333333';
const SLUG: Record<string, string> = { [CS]: 'central-stores', [SC]: 'service-centre', [DS]: 'distribution' };

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  assert.equal(r.status, 200, `login ${email}`);
  return (await finishLogin(r)) as string;
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
