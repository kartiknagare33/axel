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
let admin = '';
async function call(method: string, path: string, site: string, body?: unknown) {
  const r = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${admin}`, 'x-site-id': site, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}
async function withDraft(site: string, mutate: (bp: any) => void, fn: (id: string) => Promise<void>) {
  const b = await call('GET', `/sites/${site}/builder`, site);
  assert.equal(b.status, 200);
  const bp = structuredClone(b.body.published.config);
  mutate(bp);
  const d = await call('POST', `/sites/${site}/versions`, site, { config: bp, reason: 'gate test' });
  assert.equal(d.status, 201, JSON.stringify(d.body));
  try { await fn(d.body.id); } finally { await call('DELETE', `/sites/${site}/versions/${d.body.id}`, site); }
}

before(async () => { admin = await login('admin@axel.dev'); });

test('an unchanged site passes the gate', () => withDraft(DS, () => {}, async id => {
  const g = await call('POST', `/sites/${DS}/versions/${id}/gate`, DS, { steps: 200, seed: 42 });
  assert.equal(g.status, 200);
  assert.equal(g.body.passed, true, JSON.stringify(g.body.counterExample ?? g.body.laws.filter((l: any) => !l.passed)));
}));

test('making unit price visible to Members is blocked by a Law', () => withDraft(SC, bp => {
  bp.entities.request.fields.find((f: any) => f.key === 'unit_price').roles.read.push('Member');
}, async id => {
  const g = await call('POST', `/sites/${SC}/versions/${id}/gate`, SC, { steps: 50 });
  assert.equal(g.body.passed, false);
  assert.ok(g.body.laws.some((l: any) => l.template === 'hidden_from' && !l.passed));
}));

test('a shortcut that skips approval is caught with a counter-example', () => withDraft(DS, bp => {
  bp.workflows.request.transitions.push({ id: 't99', from: 'submitted', to: 'assigned', label: 'Fast-track', roles: ['Manager', 'Admin'] });
}, async id => {
  const g = await call('POST', `/sites/${DS}/versions/${id}/gate`, DS, { steps: 1500, seed: 7 });
  assert.equal(g.body.passed, false, 'gate should block the shortcut');
  assert.equal(g.body.counterExample?.lawId, 'l2', JSON.stringify(g.body.counterExample));
  assert.ok(g.body.counterExample.trace.length > 0);
}));

test('publishing without a passing gate is refused', () => withDraft(DS, bp => { bp.theme.tokens.primary = '#123456'; }, async id => {
  const p = await call('POST', `/sites/${DS}/publish`, DS, { versionId: id });
  assert.equal(p.status, 422);
  assert.equal(p.body.code, 'GATE_NOT_PASSED');
}));
