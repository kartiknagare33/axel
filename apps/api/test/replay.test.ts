import { test, before } from 'node:test';
import assert from 'node:assert/strict';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const SC = '22222222-2222-4222-8222-222222222222';
let admin = '';

async function call(method: string, path: string, site: string, body?: unknown) {
  const r = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${admin}`, 'x-site-id': site, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
}
async function withDraft(mutate: (bp: any) => void, fn: (id: string) => Promise<void>) {
  const b = await call('GET', `/sites/${SC}/builder`, SC);
  const bp = structuredClone(b.body.published.config);
  mutate(bp);
  const d = await call('POST', `/sites/${SC}/versions`, SC, { config: bp, reason: 'replay test' });
  assert.equal(d.status, 201, JSON.stringify(d.body));
  try { await fn(d.body.id); } finally { await call('DELETE', `/sites/${SC}/versions/${d.body.id}`, SC); }
}
const dropRejected = (bp: any) => {
  const w = bp.workflows.request;
  w.states = w.states.filter((s: string) => s !== 'rejected');
  w.transitions = w.transitions.filter((t: any) => t.to !== 'rejected');
  w.terminal = w.terminal.filter((s: string) => s !== 'rejected');
};

before(async () => {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: 'admin@axel.dev', password: 'demo1234' }) });
  admin = (await r.json()).token;
});

test('an unchanged draft replays identically', () => withDraft(() => {}, async id => {
  const r = await call('POST', `/sites/${SC}/versions/${id}/replay`, SC, { sample: 30 });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.sampled > 0, 'no history to replay; run pnpm seed');
  assert.equal(r.body.divergent.length, 0, JSON.stringify(r.body.divergent.slice(0, 3)));
}));

test('a stricter rule on Approve shows which past requests it would block', () => withDraft(bp => {
  bp.workflows.request.transitions.find((t: any) => t.to === 'approved').guard = 'qty <= 1';
}, async id => {
  const r = await call('POST', `/sites/${SC}/versions/${id}/replay`, SC, { sample: 50 });
  assert.equal(r.status, 200);
  assert.ok(r.body.divergent.some((d: any) => d.draft === 'blocked_by_guard'), JSON.stringify(r.body.summary));
  assert.ok(r.body.impact.some((i: any) => i.kind === 'step_guard'));
}));

test('a removed state that holds records is reported with plan options', () => withDraft(dropRejected, async id => {
  const r = await call('GET', `/sites/${SC}/versions/${id}/impact`, SC);
  assert.equal(r.status, 200);
  const item = r.body.impact.find((i: any) => i.kind === 'state_removed' && i.state === 'rejected');
  assert.ok(item, 'state_removed for rejected');
  assert.equal(item.class, 'destructive');
  assert.ok(item.options.includes('keep') && item.options.includes('map:closed'));
}));

test('publishing that removal without a plan is refused', t => withDraft(dropRejected, async id => {
  const imp = await call('GET', `/sites/${SC}/versions/${id}/impact`, SC);
  if (!imp.body.impact.find((i: any) => i.kind === 'state_removed' && i.state === 'rejected')?.count) return t.skip('no rejected requests; run pnpm seed');
  const g = await call('POST', `/sites/${SC}/versions/${id}/gate`, SC, { steps: 30 });
  assert.equal(g.body.passed, true, JSON.stringify(g.body.laws?.filter((l: any) => !l.passed)));
  const p = await call('POST', `/sites/${SC}/publish`, SC, { versionId: id });
  assert.equal(p.status, 409);
  assert.equal(p.body.code, 'DESTRUCTIVE_CHANGE_UNPLANNED');
}));
