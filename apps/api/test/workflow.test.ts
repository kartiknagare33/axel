import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { finishLogin } from './otp';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const SC = '22222222-2222-4222-8222-222222222222';

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  assert.equal(r.status, 200);
  return (await finishLogin(r)) as string;
}
async function call(token: string, method: string, site: string, path: string, body?: unknown) {
  const r = await fetch(`${API}/${site}${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, 'x-site-id': site, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}

let admin = '', scManager = '', scMember = '';
before(async () => { [admin, scManager, scMember] = await Promise.all(['admin@axel.dev', 'manager@sc.dev', 'member@sc.dev'].map(login)); });

const submitted = async () =>
  (await call(scManager, 'GET', SC, '/requests?filter%5Bstate%5D=submitted&limit=50')).body.rows as any[];

test('chaos: 50 concurrent approvals against 10 units, exactly 10 succeed', async () => {
  const r = await fetch(`${API}/hub/chaos`, {
    method: 'POST',
    headers: { authorization: `Bearer ${admin}`, 'content-type': 'application/json' },
    body: JSON.stringify({ concurrency: 50, stock: 10 }),
  });
  const b = await r.json();
  assert.equal(r.status, 200, JSON.stringify(b));
  assert.equal(b.outcomes.ok, 10);
  assert.equal(b.outcomes.INSUFFICIENT_STOCK, 40);
  assert.equal(b.item.reserved, 10);
  assert.equal(b.passed, true);
});

test('a Member cannot approve (role on transition)', async t => {
  const req = (await submitted())[0];
  if (!req) return t.skip('no submitted requests; run pnpm seed');
  const r = await call(scMember, 'POST', SC, `/requests/${req.id}/transition`, { to: 'approved', idempotencyKey: `member-${Date.now()}` });
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'TRANSITION_NOT_ALLOWED');
});

test('stale ifVersion is refused', async t => {
  const req = (await submitted())[0];
  if (!req) return t.skip('no submitted requests; run pnpm seed');
  const r = await call(scManager, 'POST', SC, `/requests/${req.id}/transition`, { to: 'rejected', idempotencyKey: `stale-${Date.now()}`, ifVersion: req.row_version - 1 });
  assert.equal(r.status, 409);
  assert.equal(r.body.code, 'STALE_RECORD');
});

test('double-click approve is idempotent: one reservation only', async t => {
  const req = (await submitted())[0];
  if (!req) return t.skip('no submitted requests; run pnpm seed');
  const key = `dbl-${Date.now()}`;
  const [a, b] = await Promise.all([1, 2].map(() =>
    call(scManager, 'POST', SC, `/requests/${req.id}/transition`, { to: 'approved', idempotencyKey: key })));
  assert.deepEqual([a.status, b.status].sort(), [200, 201]);
  const tl = await call(scManager, 'GET', SC, `/requests/${req.id}/timeline`);
  assert.equal(tl.body.movements.filter((m: any) => m.kind === 'reserve').length, 1);
});
