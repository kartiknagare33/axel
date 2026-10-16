import { test, before } from 'node:test';
import assert from 'node:assert/strict';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const SC = '22222222-2222-4222-8222-222222222222';
const DS = '33333333-3333-4333-8333-333333333333';

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  assert.equal(r.status, 200);
  return (await r.json()).token as string;
}
async function call(token: string, method: string, path: string, site?: string, body?: unknown) {
  const headers: Record<string, string> = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
  if (site) headers['x-site-id'] = site;
  const r = await fetch(`${API}${site ? `/${site}` : ''}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}

let admin = '', scManager = '', csManager = '';
before(async () => { [admin, scManager, csManager] = await Promise.all(['admin@axel.dev', 'manager@sc.dev', 'manager@cs.dev'].map(login)); });

test('brief endpoints respond for the right site', async () => {
  assert.ok((await call(admin, 'GET', '/sites')).body.length >= 3, 'list sites');
  assert.ok((await call(scManager, 'GET', '/components', SC)).body.some((m: any) => m.id === 'approval'), 'components');
  assert.equal((await call(scManager, 'GET', '/requests', SC)).status, 200, 'requests');
  assert.equal((await call(scManager, 'GET', '/approvals', SC)).status, 200, 'approvals');
  assert.equal((await call(admin, 'GET', '/assignments', DS)).status, 200, 'assignments');
  const x = await fetch(`${API}/${SC}/excel/export/request`, { headers: { authorization: `Bearer ${scManager}`, 'x-site-id': SC } });
  assert.equal(x.status, 200, 'excel export');
});

test('create site validates input and is limited to hub admins', async () => {
  assert.equal((await call(admin, 'POST', '/sites', undefined, { name: 'X', slug: 'Bad Slug!' })).status, 422);
  assert.equal((await call(scManager, 'POST', '/sites', undefined, { name: 'Sneaky', slug: 'sneaky' })).status, 403);
});

test('POST /approvals runs the real workflow engine', async t => {
  const req = (await call(scManager, 'GET', '/requests?filter%5Bstate%5D=submitted', SC)).body.rows?.[0];
  if (!req) return t.skip('no submitted requests; run pnpm seed');
  const r = await call(scManager, 'POST', '/approvals', SC, { requestId: req.id, decision: 'rejected', note: 'api test' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.record.state, 'rejected');
});

test('every brief endpoint refuses another site (404 to read, 403 to write)', async () => {
  for (const p of ['/components', '/requests', '/approvals', '/excel/export/request'])
    assert.equal((await call(csManager, 'GET', p, SC)).status, 404, `GET ${p}`);
  assert.equal((await call(csManager, 'GET', '/assignments', DS)).status, 404, 'GET /assignments');
  const fake = '00000000-0000-4000-8000-000000000000';
  assert.equal((await call(csManager, 'POST', '/approvals', SC, { requestId: fake, decision: 'approved' })).status, 403);
  assert.equal((await call(csManager, 'POST', '/assignments', DS, { requestId: fake })).status, 403);
});
