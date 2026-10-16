import ExcelJS from 'exceljs';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const out = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'demo', 'registers');
mkdirSync(out, { recursive: true });
let seed = 42;
const rnd = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647; };
const pick = <T,>(a: T[]): T => a[Math.floor(rnd() * a.length)];
const int = (a: number, b: number) => a + Math.floor(rnd() * (b - a + 1));
const MONEY = '"Rs "#,##0.00';
const day = (n: number) => new Date(Date.UTC(2026, 7, 1 + n));
const people = ['Anil', 'Bhavna', 'Chirag', 'Divya', 'Esha', 'Farhan', 'Gauri', 'Harsh'];
const bold = (ws: ExcelJS.Worksheet) => { ws.getRow(1).font = { bold: true }; ws.views = [{ state: 'frozen', ySplit: 1 }]; };

async function stores() {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Stock');
  ws.columns = [
    { header: 'SKU', width: 10 }, { header: 'Item Name', width: 26 }, { header: 'Category', width: 14 }, { header: 'Bin', width: 8 },
    { header: 'Stock Qty', width: 10 }, { header: 'Unit Price', width: 12 }, { header: 'Stock Value', width: 14 },
  ];
  const names = ['Copper wire 2.5mm', 'MCB 16A', 'Hex bolt M8', 'Bearing 6204', 'Cable ties', 'Insulation tape', 'Relay 12V', 'Gear oil 1L', 'Safety gloves', 'Fuse 10A'];
  for (let i = 0; i < 40; i++) {
    const qty = int(0, 150);
    const price = int(5, 900);
    const row = ws.addRow([`ST-${100 + i}`, `${names[i % names.length]}${i >= names.length ? ` (${Math.floor(i / names.length) + 1})` : ''}`, pick(['Electrical', 'Mechanical', 'Consumable', 'Safety']), `${pick(['A', 'B', 'C'])}${int(1, 9)}`, qty, price]);
    row.getCell(7).value = { formula: `E${row.number}*F${row.number}`, result: qty * price } as any;
    row.getCell(3).dataValidation = { type: 'list', allowBlank: true, formulae: ['"Electrical,Mechanical,Consumable,Safety"'] };
  }
  ws.getColumn(6).numFmt = MONEY; ws.getColumn(7).numFmt = MONEY; bold(ws);
  const f = path.join(out, 'CentralStores_Stock.xlsx'); await wb.xlsx.writeFile(f); console.log(f);
}

async function service() {
  const wb = new ExcelJS.Workbook();
  const parts = wb.addWorksheet('Parts');
  parts.columns = [{ header: 'SKU', width: 10 }, { header: 'Part Name', width: 24 }, { header: 'Stock', width: 8 }, { header: 'Unit Price', width: 12 }];
  const partNames = ['Power board PB-4', 'Control board CB-2', 'Capacitor 470uF', 'MOSFET IRF540', 'Display ribbon', 'Relay module'];
  partNames.forEach((n, i) => parts.addRow([`SC-${101 + i}`, n, int(10, 60), [2400, 3100, 12, 38, 150, 420][i]]));
  parts.getColumn(4).numFmt = MONEY; bold(parts);
  const ws = wb.addWorksheet('Repairs');
  ws.columns = [
    { header: 'Ticket No', width: 10 }, { header: 'Requested By', width: 14 }, { header: 'Part Name', width: 22 }, { header: 'Qty', width: 6 },
    { header: 'Serial No', width: 12 }, { header: 'Fault', width: 18 }, { header: 'Status', width: 12 }, { header: 'Sanctioned By', width: 14 },
    { header: 'Unit Price', width: 12 }, { header: 'Total', width: 12 }, { header: 'Returned On', width: 12 },
    { header: 'Board Model', width: 18 }, { header: 'Customer', width: 18 }, { header: 'Fault Category', width: 18 },
  ];
  const flow = ['Pending', 'Sanctioned', 'Repairing', 'Testing', 'Closed', 'Returned', 'Rejected'];
  for (let i = 0; i < 50; i++) {
    const p = int(0, partNames.length - 1);
    const price = [2400, 3100, 12, 38, 150, 420][p];
    const qty = int(1, 4);
    const status = pick(flow);
    const row = ws.addRow([`T-${5000 + i}`, pick(people), partNames[p], qty, `PCB-${30000 + i}`, pick(['No power', 'Display dead', 'Relay chatter', 'Overheating']),
      status, status === 'Pending' ? null : pick(['Priya', 'Rahul']), price, null, status === 'Returned' ? day(i % 25) : null,
      pick(['MCB-200 controller', 'PSU-48V', 'VFD drive card', 'HMI panel board']), pick(['Acme Pumps', 'Bharat Textiles', 'Metro Elevators', 'Sunrise Plastics']),
      pick(['No power', 'Short circuit', 'Component failure', 'Trace/pad damage', 'Solder joint', 'Firmware'])]);
    row.getCell(10).value = { formula: `D${row.number}*I${row.number}`, result: qty * price } as any;
  }
  ws.getColumn(9).numFmt = MONEY; ws.getColumn(10).numFmt = MONEY; bold(ws);
  const f = path.join(out, 'ServiceCentre_Repairs.xlsx'); await wb.xlsx.writeFile(f); console.log(f);
}

async function distribution() {
  const wb = new ExcelJS.Workbook();
  const mats = wb.addWorksheet('Materials');
  mats.columns = [{ header: 'Code', width: 10 }, { header: 'Material', width: 22 }, { header: 'Balance', width: 10 }, { header: 'Rate', width: 10 }];
  const names = ['Smart meter', 'Service cable 10m', 'Meter box', 'Seal kit', 'Junction box'];
  names.forEach((n, i) => mats.addRow([`DS-${201 + i}`, n, int(20, 90), [1850, 640, 410, 25, 120][i]]));
  mats.getColumn(4).numFmt = MONEY; bold(mats);
  const ws = wb.addWorksheet('Issues');
  ws.columns = [
    { header: 'Issue No', width: 10 }, { header: 'Material', width: 22 }, { header: 'Qty', width: 6 }, { header: 'Issued To', width: 12 },
    { header: 'Location', width: 14 }, { header: 'Status', width: 12 }, { header: 'Consumed Qty', width: 12 },
  ];
  for (let i = 0; i < 40; i++) {
    const status = pick(['Requested', 'Approved', 'Issued', 'Completed', 'Rejected']);
    const qty = int(1, 6);
    ws.addRow([`I-${700 + i}`, pick(names), qty, ['Issued', 'Completed'].includes(status) ? pick(people) : null,
      pick(['Ward 4', 'Sector 12', 'Plant gate', 'Substation B']), status, status === 'Completed' ? int(1, qty) : null]);
  }
  bold(ws);
  const f = path.join(out, 'Distribution_Issues.xlsx'); await wb.xlsx.writeFile(f); console.log(f);
}

async function workshop() {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Tool Requests');
  ws.columns = [
    { header: 'Ref', width: 8 }, { header: 'Tool', width: 22 }, { header: 'Qty', width: 6 }, { header: 'Requested By', width: 14 },
    { header: 'Status', width: 10 }, { header: 'Returned On', width: 12 }, { header: 'Remarks', width: 24 },
  ];
  const tools = ['Torque wrench', 'Multimeter', 'Crimping tool', 'Cordless drill', 'Insulation tester', 'Ladder 8ft'];
  for (let i = 0; i < 30; i++) {
    const status = pick(['Pending', 'Approved', 'Issued', 'Returned']);
    ws.addRow([`W-${100 + i}`, pick(tools), int(1, 2), pick(people), status, status === 'Returned' ? day(i % 20) : null, pick(['', 'urgent', 'night shift', ''])]);
  }
  bold(ws);
  const f = path.join(out, 'Workshop_Tools.xlsx'); await wb.xlsx.writeFile(f); console.log(f);
}

await stores();
await service();
await distribution();
await workshop();
