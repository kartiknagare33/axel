import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { finishLogin } from './otp';
import ExcelJS from 'exceljs';

const API = process.env.API_URL ?? 'http://localhost:4000/api';
const CS = '11111111-1111-4111-8111-111111111111';

async function login(email: string) {
  const r = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email, password: 'demo1234' }) });
  assert.equal(r.status, 200);
  return (await finishLogin(r)) as string;
}
async function upload(token: string, buf: Buffer, dryRun: boolean) {
  const r = await fetch(`${API}/${CS}/excel/import/item?dryRun=${dryRun}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'x-site-id': CS, 'content-type': 'application/octet-stream' },
    body: buf,
  });
  return { status: r.status, body: (await r.json()) as any };
}
async function exportHeaders(token: string) {
  const r = await fetch(`${API}/${CS}/excel/export/item`, { headers: { authorization: `Bearer ${token}`, 'x-site-id': CS } });
  assert.equal(r.status, 200);
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(Buffer.from(await r.arrayBuffer()) as any);
  const h: string[] = [];
  wb.getWorksheet('Data')!.getRow(1).eachCell(c => { h.push(String(c.value)); });
  return h;
}
async function sheet() {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Data');
  ws.addRow(['SKU', 'Name', 'Category', 'Unit price', 'Opening qty']);
  ws.addRow([`XL-${Date.now()}`, 'Imported cable', 'Electrical', 12.5, 40]);
  ws.addRow(['', 'Row without SKU', 'Electrical', 5, 1]);
  ws.addRow(['CS-001', 'Duplicate of an existing SKU', 'Electrical', 5, 1]);
  return Buffer.from(await wb.xlsx.writeBuffer());
}

let manager = '', member = '';
before(async () => { [manager, member] = await Promise.all(['manager@cs.dev', 'member@cs.dev'].map(login)); });

test('dry run reports bad rows by row number and saves nothing', async () => {
  const r = await upload(manager, await sheet(), true);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.valid, 1);
  const rows = [...new Set(r.body.errors.map((e: any) => e.row))];
  assert.deepEqual(rows, [3, 4]);
});

test('commit is all-or-nothing: a file with errors imports nothing', async () => {
  const r = await upload(manager, await sheet(), false);
  assert.equal(r.status, 422);
  assert.equal(r.body.code, 'VALIDATION_FAILED');
});

test('a Member cannot import (Excel policy is enforced by the server)', async () => {
  const r = await upload(member, await sheet(), true);
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'FORBIDDEN');
});

test('export follows the role mask: Member file has no prices, Manager file does', async () => {
  const m = await exportHeaders(member);
  const g = await exportHeaders(manager);
  assert.ok(!m.includes('Unit price') && !m.includes('Stock value'), `member saw: ${m.join(', ')}`);
  assert.ok(g.includes('Unit price') && g.includes('Stock value'), `manager saw: ${g.join(', ')}`);
});
