import type { Blueprint, Entity, Field } from '@axel/compiler';

export const SITE_IDS = {
  'central-stores': '11111111-1111-4111-8111-111111111111',
  'service-centre': '22222222-2222-4222-8222-222222222222',
  distribution:     '33333333-3333-4333-8333-333333333333',
} as const;

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
  theme: { tokens: { primary: '#0F766E', surface: '#F8FAFC', radius: '12px', font: 'Inter' }, layout: 'kanban-first', density: 'comfortable', home: '/requests' },
  modules: ['auth', 'users', 'dashboard', 'inventory', 'request', 'approval', 'pcb-repair', 'returns', 'analytics', 'excel'],
  entities: {
    item: item(),
    request: { owner_module: 'request', label: 'Repair request', fields: [
      { key: 'item_id', type: 'relation', to: 'item', label: 'Part', required: true },
      { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
      { key: 'unit_price', type: 'money', label: 'Unit price', roles: MGR },
      { key: 'total', type: 'formula', label: 'Total', expr: 'qty * unit_price', roles: { read: ['Manager', 'Admin'] } },
      { key: 'serial_no', type: 'text', label: 'Board serial', unique: true, owner_module: 'pcb-repair', reason: 'board identity' },
      { key: 'fault', type: 'text', label: 'Fault reported', required: true },
      { key: 'priority', type: 'select', label: 'Priority', options: ['low', 'normal', 'urgent'], default: 'normal' },
    ] },
    repair: { owner_module: 'pcb-repair', label: 'Repair log', fields: [
      { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
      { key: 'serial_no', type: 'text', label: 'Serial' },
      { key: 'fault', type: 'text', label: 'Fault' },
      { key: 'diagnosis', type: 'text', label: 'Diagnosis' },
    ] },
  },
  workflows: {
    request: {
      initial: 'draft',
      states: ['draft', 'submitted', 'approved', 'in_repair', 'closed', 'returned', 'rejected'],
      transitions: [
        { id: 't1', from: 'draft', to: 'submitted', label: 'Submit', roles: ['Member', 'Manager', 'Admin'], guard: 'stock.available(item_id) >= qty' },
        { id: 't2', from: 'submitted', to: 'approved', label: 'Approve', roles: ['Manager', 'Admin'], actions: ["stock.reserve(item_id, qty, ttl='72h')"] },
        { id: 't3', from: 'submitted', to: 'rejected', label: 'Reject', roles: ['Manager', 'Admin'] },
        { id: 't4', from: 'approved', to: 'in_repair', label: 'Start repair', roles: ['Manager', 'Admin'], actions: ['stock.commit(item_id, qty)', 'repair.open()'] },
        { id: 't5', from: 'in_repair', to: 'closed', label: 'Close', roles: ['Manager', 'Admin'], actions: ['repair.close()'] },
        { id: 't6', from: 'closed', to: 'returned', label: 'Return to customer', roles: ['Member', 'Manager', 'Admin'], actions: ["stock.release(item_id, qty, reason='return')"] },
      ],
      terminal: ['returned', 'rejected'],
    },
  },
  laws: [...baseLaws,
    { id: 'l3', template: 'hidden_from', entity: 'request', field: 'unit_price', role: 'Member' },
    { id: 'l4', template: 'reachable', workflow: 'request', state: 'closed' }],
  pages: [
    { path: '/requests', title: 'Repair board', view: 'kanban', entity: 'request', groupBy: 'state', columns: ['serial_no', 'fault', 'priority', 'qty', 'total'] },
    { path: '/repairs', title: 'Repair logs', view: 'table', entity: 'repair', columns: ['serial_no', 'fault', 'diagnosis', 'state'], roles: ['Manager', 'Admin'] },
    { path: '/items', title: 'Parts', view: 'table', entity: 'item', columns: ['sku', 'name', 'available', 'unit_price'] },
    { path: '/analytics', title: 'Insights', view: 'dashboard', roles: ['Manager', 'Admin'], widgets: [
      { id: 'w1', type: 'bar', title: 'Requests by state', entity: 'request', measure: 'count', by: 'state' },
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
