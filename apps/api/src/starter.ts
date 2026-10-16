import type { Blueprint } from '@axel/compiler';

export const starterBlueprint = (): Blueprint => ({
  configVersion: 3, siteId: '', slug: '', name: '',
  theme: { tokens: { primary: '#4F46E5', surface: '#F8FAFC', radius: '8px', font: 'Inter' }, layout: 'topbar', density: 'comfortable', home: '/items' },
  modules: ['auth', 'users', 'dashboard', 'inventory', 'analytics', 'excel'],
  entities: {
    item: { owner_module: 'inventory', label: 'Item', fields: [
      { key: 'sku', type: 'text', label: 'SKU', required: true, unique: true },
      { key: 'name', type: 'text', label: 'Name', required: true },
      { key: 'unit_price', type: 'money', label: 'Unit price', roles: { read: ['Manager', 'Admin'], write: ['Manager', 'Admin'] } },
      { key: 'on_hand', type: 'number', label: 'On hand', system: true },
      { key: 'reserved', type: 'number', label: 'Reserved', system: true },
      { key: 'available', type: 'number', label: 'Available', system: true },
    ] },
  },
  workflows: {},
  laws: [{ id: 'l0', template: 'site_isolation', locked: true }, { id: 'l1', template: 'non_negative', entity: 'item', field: 'on_hand' }],
  pages: [{ path: '/items', title: 'Stock', view: 'table', entity: 'item', columns: ['sku', 'name', 'on_hand', 'available', 'unit_price'] }],
  roles: ['Public', 'Member', 'Manager', 'Admin'],
  nav: [{ label: 'Stock', path: '/items' }],
});
