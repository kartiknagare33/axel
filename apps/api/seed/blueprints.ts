import type { Blueprint, Entity, Field } from '@axel/compiler';

export const SITE_IDS = {
  'central-stores': '11111111-1111-4111-8111-111111111111',
  'service-centre': '22222222-2222-4222-8222-222222222222',
  distribution:     '33333333-3333-4333-8333-333333333333',
} as const;

const FAULTS = ['No power', 'Short circuit', 'Component failure', 'Trace/pad damage', 'Solder joint', 'Firmware', 'Liquid damage', 'Other'];
const R4 = ['Public', 'Member', 'Manager', 'Admin'] as Blueprint['roles'];
const MGR = { read: ['Manager', 'Admin'], write: ['Manager', 'Admin'] } as Field['roles'];

const item = (extra: Field[] = []): Entity => ({ owner_module: 'inventory', label: 'Item', fields: [
  { key: 'sku', type: 'text', label: 'SKU', required: true, unique: true },
  { key: 'name', type: 'text', label: 'Name', required: true },
  { key: 'category', type: 'select', label: 'Category', options: ['Electrical', 'Mechanical', 'Consumable', 'PCB'], default: 'Consumable' },
  { key: 'unit_price', type: 'money', label: 'Unit price', roles: MGR, reason: 'cost confidential' },
  { key: 'on_hand', type: 'number', label: 'On hand', system: true },
  { key: 'reserved', type: 'number', label: 'Reserved', system: true },
  { key: 'available', type: 'number', label: 'Available', system: true },
  ...extra,
] });

const baseLaws = [
  { id: 'l0', template: 'site_isolation', locked: true },
  { id: 'l1', template: 'non_negative', entity: 'item', field: 'on_hand' },
  { id: 'l5', template: 'reserved_le_on_hand', entity: 'item' },
];

export const centralStores: Blueprint = {
  configVersion: 3, siteId: SITE_IDS['central-stores'], slug: 'central-stores', name: 'Central Stores',
  theme: { tokens: { primary: '#1D4ED8', surface: '#F1F5F9', radius: '4px', font: 'Inter' }, layout: 'sidebar', density: 'compact', home: '/analytics' },
  modules: ['auth', 'users', 'dashboard', 'inventory', 'analytics', 'excel'],
  entities: {
    item: item([
      { key: 'reorder_level', type: 'number', label: 'Reorder level', min: 0, default: 10 },
      { key: 'bin', type: 'text', label: 'Bin location' },
      { key: 'stock_value', type: 'formula', label: 'Stock value', expr: 'on_hand * unit_price', roles: { read: ['Manager', 'Admin'] } },
    ]),
  },
  workflows: {},
  laws: [...baseLaws, { id: 'l3', template: 'hidden_from', entity: 'item', field: 'unit_price', role: 'Member' }],
  pages: [
    { path: '/analytics', title: 'Overview', view: 'dashboard', widgets: [
      { id: 'w1', type: 'bar', title: 'Items by category', entity: 'item', measure: 'count', by: 'category' },
      { id: 'w2', type: 'bar', title: 'On-hand by category', entity: 'item', measure: 'sum', field: 'on_hand', by: 'category' },
      { id: 'w3', type: 'stat', title: 'Stock value', entity: 'item', measure: 'sum', field: 'stock_value' },
    ] },
    { path: '/items', title: 'Stock register', view: 'table', entity: 'item', columns: ['sku', 'name', 'category', 'bin', 'on_hand', 'reserved', 'available', 'reorder_level', 'unit_price', 'stock_value'] },
  ],
  roles: R4,
  nav: [{ label: 'Overview', path: '/analytics' }, { label: 'Stock register', path: '/items' }],
};

export const serviceCentre: Blueprint = {
  configVersion: 3, siteId: SITE_IDS['service-centre'], slug: 'service-centre', name: 'Service Centre',
  publicTracking: { entity: 'request', field: 'serial_no' },
  theme: { tokens: { primary: '#0F766E', surface: '#F8FAFC', radius: '12px', font: 'Inter' }, layout: 'kanban-first', density: 'comfortable', home: '/requests' },
  modules: ['auth', 'users', 'dashboard', 'inventory', 'request', 'approval', 'pcb-repair', 'returns', 'analytics', 'excel'],
  entities: {
    item: item(),
    request: { owner_module: 'request', label: 'Repair request', fields: [
      { key: 'item_id', type: 'relation', to: 'item', label: 'Part', required: true },
      { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
      { key: 'unit_price', type: 'money', label: 'Unit price', roles: MGR },
      { key: 'total', type: 'formula', label: 'Total', expr: 'qty * unit_price', roles: { read: ['Manager', 'Admin'] } },
      { key: 'serial_no', type: 'text', label: 'Board serial', owner_module: 'pcb-repair', reason: 'board identity' },
      { key: 'board_model', type: 'text', label: 'Board model' },
      { key: 'customer', type: 'text', label: 'Customer' },
      { key: 'fault', type: 'text', label: 'Fault reported', required: true },
      { key: 'fault_category', type: 'select', label: 'Fault category', options: FAULTS },
      { key: 'priority', type: 'select', label: 'Priority', options: ['low', 'normal', 'urgent'], default: 'normal' },
    ] },
    repair: { owner_module: 'pcb-repair', label: 'Repair log', fields: [
      { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
      { key: 'serial_no', type: 'text', label: 'Serial' },
      { key: 'board_model', type: 'text', label: 'Board model' },
      { key: 'fault', type: 'text', label: 'Fault' },
      { key: 'fault_category', type: 'select', label: 'Fault category', options: FAULTS },
      { key: 'diagnosis', type: 'text', label: 'Diagnosis' },
      { key: 'root_cause', type: 'text', label: 'Root cause' },
      { key: 'parts_replaced', type: 'text', label: 'Parts replaced' },
      { key: 'firmware_version', type: 'text', label: 'Firmware version' },
      { key: 'technician', type: 'text', label: 'Technician' },
      { key: 'bench_hours', type: 'number', label: 'Bench hours', min: 0 },
      { key: 'test_result', type: 'select', label: 'Test result', options: ['Pass', 'Fail', 'Not tested'] },
      { key: 'reworks', type: 'number', label: 'Rework rounds', system: true },
      { key: 'outcome', type: 'select', label: 'Outcome', options: ['Repaired', 'Refurbished', 'Beyond economical repair', 'Scrapped'] },
      { key: 'warranty_days', type: 'number', label: 'Warranty (days)', min: 0, default: 90 },
    ] },
  },
  workflows: {
    request: {
      initial: 'draft',
      states: ['draft', 'submitted', 'approved', 'in_repair', 'testing', 'closed', 'returned', 'rejected', 'scrapped'],
      transitions: [
        { id: 't1', from: 'draft', to: 'submitted', label: 'Submit', roles: ['Member', 'Manager', 'Admin'], guard: 'stock.available(item_id) >= qty' },
        { id: 't2', from: 'submitted', to: 'approved', label: 'Approve', roles: ['Manager', 'Admin'], actions: ["stock.reserve(item_id, qty, ttl='72h')"] },
        { id: 't3', from: 'submitted', to: 'rejected', label: 'Reject', roles: ['Manager', 'Admin'] },
        { id: 't4', from: 'approved', to: 'in_repair', label: 'Start repair', roles: ['Manager', 'Admin'], actions: ['stock.commit(item_id, qty)', 'repair.open()'] },
        { id: 't5', from: 'in_repair', to: 'testing', label: 'Send to testing', roles: ['Manager', 'Admin'] },
        { id: 't7', from: 'testing', to: 'closed', label: 'Pass test', roles: ['Manager', 'Admin'], actions: ["repair.test('pass')", 'repair.close()'] },
        { id: 't8', from: 'testing', to: 'in_repair', label: 'Fail test - rework', roles: ['Manager', 'Admin'], actions: ["repair.test('fail')"] },
        { id: 't9', from: 'in_repair', to: 'scrapped', label: 'Beyond economical repair', roles: ['Manager', 'Admin'], actions: ["repair.close('Beyond economical repair')"] },
        { id: 't6', from: 'closed', to: 'returned', label: 'Return to customer', roles: ['Member', 'Manager', 'Admin'], owner_module: 'returns' },
      ],
      terminal: ['returned', 'rejected', 'scrapped'],
    },
  },
  laws: [...baseLaws,
    { id: 'l3', template: 'hidden_from', entity: 'request', field: 'unit_price', role: 'Member' },
    { id: 'l4', template: 'reachable', workflow: 'request', state: 'closed' },
    { id: 'l6', template: 'via_state', entity: 'request', state: 'closed', via: 'testing' }],
  pages: [
    { path: '/requests', title: 'Repair board', view: 'kanban', entity: 'request', groupBy: 'state', columns: ['serial_no', 'board_model', 'fault_category', 'priority', 'total'] },
    { path: '/repairs', title: 'Repair logs', view: 'table', entity: 'repair', columns: ['serial_no', 'board_model', 'fault_category', 'test_result', 'reworks', 'outcome', 'bench_hours', 'state'], roles: ['Manager', 'Admin'] },
    { path: '/items', title: 'Parts', view: 'table', entity: 'item', columns: ['sku', 'name', 'available', 'unit_price'] },
    { path: '/analytics', title: 'Insights', view: 'dashboard', roles: ['Manager', 'Admin'], widgets: [
      { id: 'w3', type: 'stat', title: 'Boards in repair', entity: 'request', measure: 'count', where: { state: 'in_repair' } },
      { id: 'w4', type: 'stat', title: 'Waiting for testing', entity: 'request', measure: 'count', where: { state: 'testing' } },
      { id: 'w5', type: 'stat', title: 'Passed test first time', entity: 'repair', measure: 'count', where: { test_result: 'Pass', reworks: '0' } },
      { id: 'w6', type: 'stat', title: 'Average bench hours', entity: 'repair', measure: 'avg', field: 'bench_hours' },
      { id: 'w1', type: 'bar', title: 'Requests by stage', entity: 'request', measure: 'count', by: 'state' },
      { id: 'w7', type: 'bar', title: 'Faults by category', entity: 'request', measure: 'count', by: 'fault_category' },
      { id: 'w8', type: 'pie', title: 'Repair outcomes', entity: 'repair', measure: 'count', by: 'outcome' },
      { id: 'w2', type: 'pie', title: 'By priority', entity: 'request', measure: 'count', by: 'priority' },
    ] },
  ],
  roles: R4,
  nav: [{ label: 'Repair board', path: '/requests' }, { label: 'Repair logs', path: '/repairs' }, { label: 'Parts', path: '/items' }, { label: 'Insights', path: '/analytics' }],
};

export const distribution: Blueprint = {
  configVersion: 3, siteId: SITE_IDS.distribution, slug: 'distribution', name: 'Distribution',
  theme: { tokens: { primary: '#B45309', surface: '#FFFBEB', radius: '6px', font: 'Inter' }, layout: 'queue-first', density: 'comfortable', home: '/assignments' },
  // Returns intentionally NOT enabled: the demo enables it live.
  modules: ['auth', 'users', 'dashboard', 'inventory', 'request', 'approval', 'material-assignment', 'assignment-frontend', 'consumption', 'analytics', 'excel'],
  entities: {
    item: item(),
    request: { owner_module: 'request', label: 'Material request', fields: [
      { key: 'item_id', type: 'relation', to: 'item', label: 'Material', required: true },
      { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
      { key: 'unit_price', type: 'money', label: 'Unit price', roles: MGR },
      { key: 'total', type: 'formula', label: 'Total', expr: 'qty * unit_price', roles: { read: ['Manager', 'Admin'] } },
      { key: 'site_location', type: 'text', label: 'Field location', required: true },
    ] },
    assignment: { owner_module: 'material-assignment', label: 'Assignment', fields: [
      { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
      { key: 'item_id', type: 'relation', to: 'item', label: 'Material', required: true },
      { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
      { key: 'assigned_to', type: 'text', label: 'Assigned to' },
    ] },
    consumption: { owner_module: 'consumption', label: 'Consumption', fields: [
      { key: 'assignment_id', type: 'relation', to: 'assignment', label: 'Assignment', required: true },
      { key: 'qty', type: 'number', label: 'Qty used', min: 1, required: true },
      { key: 'note', type: 'text', label: 'Note' },
    ] },
  },
  workflows: {
    request: {
      initial: 'draft',
      states: ['draft', 'submitted', 'approved', 'assigned', 'closed', 'rejected'],
      transitions: [
        { id: 't1', from: 'draft', to: 'submitted', label: 'Submit', roles: ['Member', 'Manager', 'Admin'], guard: 'stock.available(item_id) >= qty' },
        { id: 't2', from: 'submitted', to: 'approved', label: 'Approve', roles: ['Manager', 'Admin'], actions: ["stock.reserve(item_id, qty, ttl='72h')"] },
        { id: 't3', from: 'submitted', to: 'rejected', label: 'Reject', roles: ['Manager', 'Admin'] },
        { id: 't4', from: 'approved', to: 'assigned', label: 'Assign', roles: ['Manager', 'Admin'], actions: ['stock.commit(item_id, qty)'] },
        { id: 't5', from: 'assigned', to: 'closed', label: 'Close', roles: ['Member', 'Manager', 'Admin'] },
      ],
      terminal: ['closed', 'rejected'],
    },
  },
  laws: [...baseLaws, { id: 'l2', template: 'requires_state', entity: 'assignment', ref: 'request_id', state: 'approved' }],
  pages: [
    { path: '/assignments', title: 'Assignment queue', view: 'queue', entity: 'assignment', columns: ['item_id', 'qty', 'assigned_to'] },
    { path: '/requests', title: 'Requests', view: 'table', entity: 'request', columns: ['item_id', 'qty', 'site_location', 'state', 'total'] },
    { path: '/consumption', title: 'Field consumption', view: 'table', entity: 'consumption', columns: ['assignment_id', 'qty', 'note'] },
    { path: '/items', title: 'Materials', view: 'table', entity: 'item', columns: ['sku', 'name', 'available'] },
  ],
  roles: R4,
  nav: [{ label: 'Queue', path: '/assignments' }, { label: 'Requests', path: '/requests' }, { label: 'Consumption', path: '/consumption' }, { label: 'Materials', path: '/items' }],
};
