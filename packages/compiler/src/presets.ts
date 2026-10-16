import type { Blueprint, Entity, Field, Role } from './types';
import { autoWire } from './ports';

const R4: Role[] = ['Public', 'Member', 'Manager', 'Admin'];
const M: Role[] = ['Member', 'Manager', 'Admin'];
const MG: Role[] = ['Manager', 'Admin'];
const MGR = { read: MG, write: MG };

const item = (): Entity => ({ owner_module: 'inventory', label: 'Item', fields: [
  { key: 'sku', type: 'text', label: 'SKU', required: true, unique: true },
  { key: 'name', type: 'text', label: 'Name', required: true },
  { key: 'category', type: 'select', label: 'Category', options: ['Electrical', 'Mechanical', 'Consumable', 'PCB'], default: 'Consumable' },
  { key: 'unit_price', type: 'money', label: 'Unit price', roles: MGR, reason: 'cost confidential' },
  { key: 'on_hand', type: 'number', label: 'On hand', system: true },
  { key: 'reserved', type: 'number', label: 'Reserved', system: true },
  { key: 'available', type: 'number', label: 'Available', system: true },
] });
const request = (extra: Field[]): Entity => ({ owner_module: 'request', label: 'Request', fields: [
  { key: 'item_id', type: 'relation', to: 'item', label: 'Item', required: true },
  { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
  { key: 'unit_price', type: 'money', label: 'Unit price', roles: MGR },
  { key: 'total', type: 'formula', label: 'Total', expr: 'qty * unit_price', roles: { read: MG } },
  ...extra,
] });
const laws = [
  { id: 'l0', template: 'site_isolation', locked: true },
  { id: 'l1', template: 'non_negative', entity: 'item', field: 'on_hand' },
  { id: 'l5', template: 'reserved_le_on_hand', entity: 'item' },
];
const finish = (bp: Blueprint): Blueprint => ({ ...bp, edges: autoWire(bp) });
const id = { configVersion: 3 as const, siteId: '', slug: '', name: '' };

export const PRESETS: Record<string, { name: string; description: string; build: () => Blueprint }> = {
  'inventory-starter': {
    name: 'Inventory Starter',
    description: 'Stock register with analytics and Excel.',
    build: () => finish({
      ...id,
      theme: { tokens: { primary: '#4F46E5', surface: '#F8FAFC', radius: '6px', font: 'Inter' }, layout: 'sidebar', density: 'compact', home: '/analytics' },
      modules: ['auth', 'users', 'dashboard', 'inventory', 'analytics', 'excel'],
      entities: { item: item() },
      workflows: {},
      laws,
      pages: [
        { path: '/analytics', title: 'Overview', view: 'dashboard', widgets: [{ id: 'w1', type: 'bar', title: 'Items by category', entity: 'item', measure: 'count', by: 'category' }] },
        { path: '/items', title: 'Stock', view: 'table', entity: 'item', columns: ['sku', 'name', 'category', 'on_hand', 'available', 'unit_price'] },
      ],
      roles: R4,
      nav: [{ label: 'Overview', path: '/analytics' }, { label: 'Stock', path: '/items' }],
    }),
  },
  'approval-chain': {
    name: 'Approval Chain',
    description: 'Request, approve, assign, close.',
    build: () => finish({
      ...id,
      theme: { tokens: { primary: '#7C3AED', surface: '#FAF5FF', radius: '10px', font: 'Inter' }, layout: 'kanban-first', density: 'comfortable', home: '/requests' },
      modules: ['auth', 'users', 'dashboard', 'inventory', 'request', 'approval', 'material-assignment', 'assignment-frontend', 'analytics', 'excel'],
      entities: {
        item: item(),
        request: request([{ key: 'location', type: 'text', label: 'Location' }]),
        assignment: { owner_module: 'material-assignment', label: 'Assignment', fields: [
          { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
          { key: 'item_id', type: 'relation', to: 'item', label: 'Material', required: true },
          { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
          { key: 'assigned_to', type: 'text', label: 'Assigned to' },
        ] },
      },
      workflows: { request: {
        initial: 'draft', states: ['draft', 'submitted', 'approved', 'assigned', 'closed', 'rejected'], terminal: ['closed', 'rejected'],
        transitions: [
          { id: 't1', from: 'draft', to: 'submitted', label: 'Submit', roles: M, guard: 'stock.available(item_id) >= qty' },
          { id: 't2', from: 'submitted', to: 'approved', label: 'Approve', roles: MG, actions: ["stock.reserve(item_id, qty, ttl='72h')"] },
          { id: 't3', from: 'submitted', to: 'rejected', label: 'Reject', roles: MG },
          { id: 't4', from: 'approved', to: 'assigned', label: 'Assign', roles: MG, actions: ['stock.commit(item_id, qty)'] },
          { id: 't5', from: 'assigned', to: 'closed', label: 'Close', roles: M },
        ],
      } },
      laws,
      pages: [
        { path: '/requests', title: 'Requests', view: 'kanban', entity: 'request', groupBy: 'state', columns: ['item_id', 'qty', 'location', 'total'] },
        { path: '/assignments', title: 'Assignment queue', view: 'queue', entity: 'assignment', columns: ['item_id', 'qty', 'assigned_to'] },
        { path: '/items', title: 'Stock', view: 'table', entity: 'item', columns: ['sku', 'name', 'available', 'unit_price'] },
        { path: '/analytics', title: 'Analytics', view: 'dashboard', roles: MG, widgets: [{ id: 'w1', type: 'bar', title: 'Requests by state', entity: 'request', measure: 'count', by: 'state' }] },
      ],
      roles: R4,
      nav: [{ label: 'Requests', path: '/requests' }, { label: 'Queue', path: '/assignments' }, { label: 'Stock', path: '/items' }, { label: 'Analytics', path: '/analytics' }],
    }),
  },
  'repair-shop': {
    name: 'Repair & Refurbishment',
    description: 'Receive, approve, repair, test, close, return.',
    build: () => finish({
      ...id,
      theme: { tokens: { primary: '#0E7490', surface: '#F0FDFA', radius: '12px', font: 'Inter' }, layout: 'kanban-first', density: 'comfortable', home: '/requests' },
      publicTracking: { entity: 'request', field: 'serial_no' },
      modules: ['auth', 'users', 'dashboard', 'inventory', 'request', 'approval', 'pcb-repair', 'returns', 'analytics', 'excel'],
      entities: {
        item: item(),
        request: request([
          { key: 'serial_no', type: 'text', label: 'Board serial', unique: true, owner_module: 'pcb-repair' },
          { key: 'fault', type: 'text', label: 'Fault reported', required: true, owner_module: 'pcb-repair' },
        ]),
        repair: { owner_module: 'pcb-repair', label: 'Repair log', fields: [
          { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
          { key: 'serial_no', type: 'text', label: 'Serial' },
          { key: 'fault', type: 'text', label: 'Fault' },
          { key: 'diagnosis', type: 'text', label: 'Diagnosis' },
        ] },
      },
      workflows: { request: {
        initial: 'draft', states: ['draft', 'submitted', 'approved', 'in_repair', 'testing', 'closed', 'returned', 'rejected', 'scrapped'], terminal: ['returned', 'rejected', 'scrapped'],
        transitions: [
          { id: 't1', from: 'draft', to: 'submitted', label: 'Submit', roles: M, guard: 'stock.available(item_id) >= qty' },
          { id: 't2', from: 'submitted', to: 'approved', label: 'Approve', roles: MG, actions: ["stock.reserve(item_id, qty, ttl='72h')"] },
          { id: 't3', from: 'submitted', to: 'rejected', label: 'Reject', roles: MG },
          { id: 't4', from: 'approved', to: 'in_repair', label: 'Start repair', roles: MG, actions: ['stock.commit(item_id, qty)', 'repair.open()'] },
          { id: 't5', from: 'in_repair', to: 'testing', label: 'Send to testing', roles: MG },
          { id: 't7', from: 'testing', to: 'closed', label: 'Pass test', roles: MG, actions: ["repair.test('pass')", 'repair.close()'] },
          { id: 't8', from: 'testing', to: 'in_repair', label: 'Fail test - rework', roles: MG, actions: ["repair.test('fail')"] },
          { id: 't9', from: 'in_repair', to: 'scrapped', label: 'Beyond economical repair', roles: MG, actions: ["repair.close('Beyond economical repair')"] },
          { id: 't6', from: 'closed', to: 'returned', label: 'Return', roles: M, actions: ['stock.return(item_id, qty)'], owner_module: 'returns' },
        ],
      } },
      laws,
      pages: [
        { path: '/requests', title: 'Repair board', view: 'kanban', entity: 'request', groupBy: 'state', columns: ['serial_no', 'fault', 'qty', 'total'] },
        { path: '/repairs', title: 'Repair logs', view: 'table', entity: 'repair', columns: ['serial_no', 'fault', 'diagnosis', 'state'], roles: MG },
        { path: '/items', title: 'Parts', view: 'table', entity: 'item', columns: ['sku', 'name', 'available', 'unit_price'] },
      ],
      roles: R4,
      nav: [{ label: 'Repair board', path: '/requests' }, { label: 'Repair logs', path: '/repairs' }, { label: 'Parts', path: '/items' }],
    }),
  },
};
