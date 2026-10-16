import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { finishLogin } from './otp';
import JSZip from 'jszip';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const SC = '22222222-2222-4222-8222-222222222222';
const DS = '33333333-3333-4333-8333-333333333333';

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  return (await finishLogin(r)) as string;
}
let admin = '', scManager = '', csManager = '';
before(async () => { [admin, scManager, csManager] = await Promise.all(['admin@axel.dev', 'manager@sc.dev', 'manager@cs.dev'].map(login)); });
const H = (t: string, site?: string) => ({ authorization: `Bearer ${t}`, 'content-type': 'application/json', ...(site ? { 'x-site-id': site } : {}) });

test('Isolation Ledger: RLS forced everywhere, app role powerless, live check passes', async () => {
  const l = await (await fetch(`${API}/hub/isolation-ledger`, { headers: H(admin) })).json();
  assert.ok(l.tables.length >= 14);
  for (const t of l.tables) assert.ok(t.rls && t.forced && t.policies > 0, t.table);
  assert.equal(l.role.bypass, false);
  assert.equal(l.role.superuser, false);
  assert.equal(l.role.ownsTables, 0);
  const c = await (await fetch(`${API}/hub/isolation-ledger/check`, { method: 'POST', headers: H(admin) })).json();
  assert.equal(c.passed, true, JSON.stringify(c.checks.filter((x: any) => !x.passed)));
  assert.equal((await fetch(`${API}/hub/isolation-ledger`, { headers: H(scManager) })).status, 403);
});

test('export zip holds Blueprint, README, OpenAPI, data and history', async () => {
  const r = await fetch(`${API}/sites/${DS}/export`, { headers: H(admin, DS) });
  assert.equal(r.status, 200);
  const zip = await JSZip.loadAsync(Buffer.from(await r.arrayBuffer()));
  for (const f of ['blueprint.json', 'README.md', 'openapi.json', 'data.xlsx', 'deployments.json']) assert.ok(zip.file(f), f);
  const bp = JSON.parse(await zip.file('blueprint.json')!.async('string'));
  assert.equal(bp.slug, 'distribution');
  const api = JSON.parse(await zip.file('openapi.json')!.async('string'));
  assert.ok(Object.keys(api.paths).some(p => p.endsWith('/transition')));
});

test('Explain describes the unit in plain language', async () => {
  const t = await (await fetch(`${API}/sites/${SC}/explain`, { headers: H(admin, SC) })).text();
  assert.ok(t.includes('# Service Centre') && t.includes('## Workflow') && t.includes('## Laws'));
});

test('board history finds a serial and refuses other units', async () => {
  const list = await (await fetch(`${API}/${SC}/requests?limit=200`, { headers: H(scManager, SC) })).json();
  const withSerial = list.rows.find((r: any) => r.serial_no);
  assert.ok(withSerial, 'no request with a serial; run pnpm seed');
  const tl = await (await fetch(`${API}/${SC}/timeline?serial=${encodeURIComponent(withSerial.serial_no)}`, { headers: H(scManager, SC) })).json();
  assert.ok(tl.records.length >= 1 && tl.events.length >= 1);
  assert.equal((await fetch(`${API}/${SC}/timeline?serial=PCB-24001`, { headers: H(csManager, SC) })).status, 404);
});
