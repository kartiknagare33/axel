import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { finishLogin } from './otp';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const SC = '22222222-2222-4222-8222-222222222222';
let admin = '', manager = '';

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  return (await finishLogin(r)) as string;
}
async function call(token: string, method: string, path: string, body?: unknown) {
  const r = await fetch(`${API}${path}`, {
    method, headers: { authorization: `Bearer ${token}`, 'x-site-id': SC, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}
before(async () => { [admin, manager] = await Promise.all(['admin@axel.dev', 'manager@sc.dev'].map(login)); });

test('a shortcut that skips testing is blocked by a Law', async () => {
  const b = await call(admin, 'GET', `/sites/${SC}/builder`);
  const bp = structuredClone(b.body.published.config);
  bp.workflows.request.transitions.push({ id: 't99', from: 'in_repair', to: 'closed', label: 'Quick close', roles: ['Manager', 'Admin'] });
  const d = await call(admin, 'POST', `/sites/${SC}/versions`, { config: bp, reason: 'repair test' });
  try {
    const g = await call(admin, 'POST', `/sites/${SC}/versions/${d.body.id}/gate`, { steps: 30 });
    assert.equal(g.body.passed, false);
    assert.ok(g.body.laws.some((l: any) => l.template === 'via_state' && !l.passed), JSON.stringify(g.body.laws));
  } finally { await call(admin, 'DELETE', `/sites/${SC}/versions/${d.body.id}`); }
});

test('fail test sends a board back for rework; pass test closes it with outcome', async t => {
  const req = (await call(manager, 'GET', `/${SC}/requests?filter%5Bstate%5D=approved`)).body.rows?.[0];
  if (!req) return t.skip('no approved requests; run pnpm seed');
  const go = async (to: string) => {
    const r = await call(manager, 'POST', `/${SC}/requests/${req.id}/transition`, { to, idempotencyKey: `rp-${req.id}-${to}-${Math.random()}` });
    assert.ok(r.status === 201, `${to}: ${JSON.stringify(r.body)}`);
  };
  for (const to of ['in_repair', 'testing', 'in_repair', 'testing', 'closed']) await go(to);
  const reps = (await call(manager, 'GET', `/${SC}/repairs?limit=200`)).body.rows;
  const rep = reps.find((r: any) => r.request_id === req.id);
  assert.ok(rep, 'repair log exists');
  assert.equal(rep.test_result, 'Pass');
  assert.equal(rep.reworks, 1);
  assert.equal(rep.outcome, 'Repaired');
  assert.equal(rep.state, 'closed');
});

test('public tracking shows only the stage, never private data', async () => {
  const r = await fetch(`${API}/public/track/service-centre?ref=PCB-24007`);
  const b: any = await r.json();
  assert.equal(r.status, 200, JSON.stringify(b));
  assert.ok(b.state && Array.isArray(b.states));
  for (const k of ['unit_price', 'total', 'customer', 'requested_by', 'id']) assert.ok(!(k in b), `leaked ${k}`);
  assert.equal((await fetch(`${API}/public/track/service-centre?ref=NOPE-000`)).status, 404);
  assert.equal((await fetch(`${API}/public/track/distribution?ref=PCB-24007`)).status, 404);
});

test('board passport counts repeat visits', async () => {
  const r = await call(manager, 'GET', `/${SC}/timeline?serial=PCB-24007`);
  assert.equal(r.status, 200);
  assert.ok(r.body.passport.requests >= 2, JSON.stringify(r.body.passport));
  assert.ok(r.body.passport.history.length >= 1);
});
