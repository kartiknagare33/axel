import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { finishLogin } from './otp';
import ExcelJS from 'exceljs';
import { infer, compile, type Sheet } from '@axel/compiler';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const DS = '33333333-3333-4333-8333-333333333333';
const L = 'ABCDEFGHIJKLMNOP'.split('');

function sheet(name: string, headers: string[], rows: unknown[][], formulas?: (string | null)[][]): Sheet {
  return { name, headers, letters: L.slice(0, headers.length), rows, formulas: formulas ?? rows.map(r => r.map(() => null)), lists: headers.map(() => null), money: headers.map(h => /price/i.test(h)) };
}

test('a repair register infers approval, repair, returns and a mapped formula', () => {
  const parts = sheet('Parts', ['SKU', 'Part Name', 'Stock', 'Unit Price'], Array.from({ length: 6 }, (_, i) => [`P-${i}`, `Board ${i}`, 10 + i, 100 * (i + 1)]));
  const statuses = ['Pending', 'Sanctioned', 'Repairing', 'Closed', 'Returned', 'Rejected'];
  const rows = Array.from({ length: 24 }, (_, i) => [`T-${i}`, `Board ${i % 6}`, 1 + (i % 3), `PCB-${i}`, 'No power', statuses[i % 6], i % 6 ? 'Priya' : null, 100, null]);
  const formulas = rows.map((_, i) => [null, null, null, null, null, null, null, null, `C${i + 2}*H${i + 2}`]);
  const repairs = sheet('Repairs', ['Ticket No', 'Part Name', 'Qty', 'Serial No', 'Fault', 'Status', 'Sanctioned By', 'Unit Price', 'Total'], rows, formulas);
  const r = infer([parts, repairs], { name: 'Repairs Test' });
  const bp = r.blueprint;
  for (const m of ['approval', 'pcb-repair', 'returns']) assert.ok(bp.modules.includes(m), `module ${m}`);
  for (const s of ['approved', 'in_repair', 'closed', 'returned', 'rejected']) assert.ok(bp.workflows.request.states.includes(s), `state ${s}`);
  assert.equal(bp.entities.request.fields.find(f => f.key === 'total')?.expr, 'qty * unit_price');
  assert.equal(bp.theme.layout, 'kanban-first');
  assert.deepEqual(compile(bp).diagnostics.filter(d => d.severity === 'error'), []);
  assert.ok(r.inferences.every(i => i.explanation.length > 10 && i.confidence > 0));
});

test('a stock sheet alone infers a sidebar inventory site', () => {
  const rows = Array.from({ length: 20 }, (_, i) => [`S-${i}`, `Thing ${i}`, ['A', 'B', 'C'][i % 3], i * 2, 10 + i, null]);
  const formulas = rows.map((_, i) => [null, null, null, null, null, `D${i + 2}*E${i + 2}`]);
  const r = infer([sheet('Stock', ['SKU', 'Item Name', 'Category', 'Stock Qty', 'Unit Price', 'Stock Value'], rows, formulas)], { name: 'Stores Test' });
  assert.equal(r.blueprint.theme.layout, 'sidebar');
  assert.ok(!r.blueprint.entities.request);
  assert.equal(r.blueprint.entities.item.fields.find(f => f.key === 'stock_value')?.expr, 'on_hand * unit_price');
  assert.ok(r.inferences.some(i => i.rule === 'LAW_NON_NEGATIVE'));
  assert.deepEqual(compile(r.blueprint).diagnostics.filter(d => d.severity === 'error'), []);
});

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  return (await finishLogin(r)) as string;
}
let admin = '', manager = '', member = '';
before(async () => { [admin, manager, member] = await Promise.all(['admin@axel.dev', 'manager@sc.dev', 'member@cs.dev'].map(login)); });

test('the upload endpoint reads a workbook and is hub-admin only', async () => {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Tool Requests');
  ws.addRow(['Ref', 'Tool', 'Qty', 'Requested By', 'Status']);
  for (let i = 0; i < 12; i++) ws.addRow([`W-${i}`, ['Drill', 'Meter'][i % 2], 1, 'Anil', ['Pending', 'Approved', 'Issued', 'Returned'][i % 4]]);
  const buf = Buffer.from(await wb.xlsx.writeBuffer());
  const post = (token: string) => fetch(`${API}/sites/infer?name=Tools%20Test`, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/octet-stream' }, body: buf });
  const ok = await post(admin);
  const body = await ok.json();
  assert.equal(ok.status, 200, JSON.stringify(body));
  assert.ok(body.blueprint.modules.includes('material-assignment'));
  assert.ok(body.inferences.length > 5);
  assert.deepEqual(body.diagnostics.filter((d: any) => d.severity === 'error'), []);
  assert.equal((await post(manager)).status, 403);
});

test('members can be added, re-roled and removed, but nobody changes their own role', async () => {
  const H = (t: string) => ({ authorization: `Bearer ${t}`, 'x-site-id': DS, 'content-type': 'application/json' });
  const me = await (await fetch(`${API}/me`, { headers: { authorization: `Bearer ${admin}` } })).json();
  const add = await fetch(`${API}/sites/${DS}/members`, { method: 'POST', headers: H(admin), body: JSON.stringify({ email: 'member@cs.dev', role: 'Member' }) });
  assert.ok([201, 409].includes(add.status));
  const list = await (await fetch(`${API}/sites/${DS}/members`, { headers: H(admin) })).json();
  const target = list.find((m: any) => m.email === 'member@cs.dev');
  try {
    const sites = await (await fetch(`${API}/sites`, { headers: { authorization: `Bearer ${member}` } })).json();
    assert.ok(sites.some((s: any) => s.id === DS), 'new member sees the unit');
    const self = await fetch(`${API}/sites/${DS}/members/${me.user.id}`, { method: 'PATCH', headers: H(admin), body: JSON.stringify({ role: 'Member' }) });
    assert.equal(self.status, 403);
    const up = await fetch(`${API}/sites/${DS}/members/${target.user_id}`, { method: 'PATCH', headers: H(admin), body: JSON.stringify({ role: 'Manager' }) });
    assert.equal(up.status, 200);
  } finally {
    const del = await fetch(`${API}/sites/${DS}/members/${target.user_id}`, { method: 'DELETE', headers: H(admin) });
    assert.equal(del.status, 200);
  }
  const after = await (await fetch(`${API}/sites`, { headers: { authorization: `Bearer ${member}` } })).json();
  assert.ok(!after.some((s: any) => s.id === DS));
});
