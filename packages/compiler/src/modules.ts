import type { Blueprint, Entity, Field, Page, Role, Transition, Workflow } from './types';
import { REGISTRY } from './registry';
import { autoWire } from './ports';

const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v));
const M: Role[] = ['Member', 'Manager', 'Admin'];
const MG: Role[] = ['Manager', 'Admin'];
const MGR_MASK = { read: MG, write: MG };

const nextId = (wf: Workflow) => `t${Math.max(0, ...wf.transitions.map(t => Number(t.id.replace(/\D/g, '')) || 0)) + 1}`;
function addState(wf: Workflow, s: string, terminal = false) {
  if (!wf.states.includes(s)) wf.states.push(s);
  if (terminal && !wf.terminal.includes(s)) wf.terminal.push(s);
}
const unterminal = (wf: Workflow, s: string) => { wf.terminal = wf.terminal.filter(x => x !== s); };
function addT(wf: Workflow, t: Omit<Transition, 'id'>) {
  if (!wf.transitions.some(x => x.from === t.from && x.to === t.to)) wf.transitions.push({ id: nextId(wf), ...t });
}
function addPage(bp: Blueprint, page: Page, label: string) {
  if (bp.pages.some(p => p.path === page.path)) return;
  bp.pages.push(page);
  bp.nav.push({ label, path: page.path });
}
function addField(ent: Entity, f: Field) { if (!ent.fields.some(x => x.key === f.key)) ent.fields.push(f); }

/** What each module adds to a site when it is enabled. */
const ADD: Record<string, (bp: Blueprint) => void> = {
  request: bp => {
    bp.entities.request ??= { owner_module: 'request', label: 'Request', fields: [
      { key: 'item_id', type: 'relation', to: 'item', label: 'Item', required: true },
      { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
      { key: 'unit_price', type: 'money', label: 'Unit price', roles: MGR_MASK },
      { key: 'total', type: 'formula', label: 'Total', expr: 'qty * unit_price', roles: { read: MG } },
      { key: 'note', type: 'text', label: 'Note' },
    ] };
    bp.workflows.request ??= { initial: 'draft', states: ['draft', 'submitted'], terminal: ['submitted'], transitions: [
      { id: 't1', from: 'draft', to: 'submitted', label: 'Submit', roles: M, guard: 'stock.available(item_id) >= qty', owner_module: 'request' },
    ] };
    addPage(bp, { path: '/requests', title: 'Requests', view: 'kanban', entity: 'request', groupBy: 'state', columns: ['item_id', 'qty', 'total'], owner_module: 'request' }, 'Requests');
  },
  approval: bp => {
    const wf = bp.workflows.request;
    if (!wf) return;
    addState(wf, 'approved', true); addState(wf, 'rejected', true); unterminal(wf, 'submitted');
    addT(wf, { from: 'submitted', to: 'approved', label: 'Approve', roles: MG, actions: ["stock.reserve(item_id, qty, ttl='72h')"], owner_module: 'approval' });
    addT(wf, { from: 'submitted', to: 'rejected', label: 'Reject', roles: MG, owner_module: 'approval' });
    addPage(bp, { path: '/approvals', title: 'Approvals', view: 'table', entity: 'request', filter: { state: 'submitted' }, columns: ['item_id', 'qty', 'total', 'state'], roles: MG, owner_module: 'approval' }, 'Approvals');
  },
  'material-assignment': bp => {
    const wf = bp.workflows.request;
    if (!wf || !wf.states.includes('approved')) return;
    addState(wf, 'assigned'); addState(wf, 'closed', true); unterminal(wf, 'approved');
    addT(wf, { from: 'approved', to: 'assigned', label: 'Assign', roles: MG, actions: ['stock.commit(item_id, qty)'], owner_module: 'material-assignment' });
    addT(wf, { from: 'assigned', to: 'closed', label: 'Close', roles: M, owner_module: 'material-assignment' });
    bp.entities.assignment ??= { owner_module: 'material-assignment', label: 'Assignment', fields: [
      { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
      { key: 'item_id', type: 'relation', to: 'item', label: 'Material', required: true },
      { key: 'qty', type: 'number', label: 'Qty', min: 1, required: true },
      { key: 'assigned_to', type: 'text', label: 'Assigned to' },
    ] };
    addPage(bp, { path: '/assignments', title: 'Assignment queue', view: 'queue', entity: 'assignment', columns: ['item_id', 'qty', 'assigned_to'], owner_module: 'material-assignment' }, 'Queue');
  },
  'pcb-repair': bp => {
    const wf = bp.workflows.request;
    const req = bp.entities.request;
    if (!wf || !req || !wf.states.includes('approved')) return;
    addField(req, { key: 'serial_no', type: 'text', label: 'Board serial', unique: true, owner_module: 'pcb-repair', reason: 'board identity' });
    addField(req, { key: 'fault', type: 'text', label: 'Fault reported', owner_module: 'pcb-repair' });
    addState(wf, 'in_repair'); addState(wf, 'closed', true); unterminal(wf, 'approved');
    addT(wf, { from: 'approved', to: 'in_repair', label: 'Start repair', roles: MG, actions: ['stock.commit(item_id, qty)', 'repair.open()'], owner_module: 'pcb-repair' });
    addT(wf, { from: 'in_repair', to: 'closed', label: 'Close', roles: MG, actions: ['repair.close()'], owner_module: 'pcb-repair' });
    bp.entities.repair ??= { owner_module: 'pcb-repair', label: 'Repair log', fields: [
      { key: 'request_id', type: 'relation', to: 'request', label: 'Request', required: true },
      { key: 'serial_no', type: 'text', label: 'Serial' },
      { key: 'fault', type: 'text', label: 'Fault' },
      { key: 'diagnosis', type: 'text', label: 'Diagnosis' },
    ] };
    addPage(bp, { path: '/repairs', title: 'Repair logs', view: 'table', entity: 'repair', columns: ['serial_no', 'fault', 'diagnosis', 'state'], owner_module: 'pcb-repair' }, 'Repairs');
  },
  returns: bp => {
    const wf = bp.workflows.request;
    if (!wf) return;
    const from = ['closed', 'assigned', 'in_repair'].find(s => wf.states.includes(s));
    if (!from) return;
    addState(wf, 'returned', true);
    addT(wf, { from, to: 'returned', label: 'Return', roles: M, actions: ['stock.return(item_id, qty)'], owner_module: 'returns' });
    const cols = bp.pages.find(p => p.entity === 'request' && p.columns)?.columns ?? ['item_id', 'qty', 'state'];
    addPage(bp, { path: '/returns', title: 'Returns', view: 'table', entity: 'request', filter: { state: 'returned' }, columns: cols, owner_module: 'returns' }, 'Returns');
  },
  consumption: bp => {
    if (!bp.entities.assignment) return;
    bp.entities.consumption ??= { owner_module: 'consumption', label: 'Consumption', fields: [
      { key: 'assignment_id', type: 'relation', to: 'assignment', label: 'Assignment', required: true },
      { key: 'qty', type: 'number', label: 'Qty used', min: 1, required: true },
      { key: 'note', type: 'text', label: 'Note' },
    ] };
    addPage(bp, { path: '/consumption', title: 'Field consumption', view: 'table', entity: 'consumption', columns: ['assignment_id', 'qty', 'note'], owner_module: 'consumption' }, 'Consumption');
  },
  analytics: bp => {
    if (bp.pages.some(p => p.view === 'dashboard')) return;
    const ent = bp.entities.request ? 'request' : 'item';
    const by = ent === 'request' ? 'state' : bp.entities.item?.fields.some(f => f.key === 'category') ? 'category' : undefined;
    addPage(bp, { path: '/analytics', title: 'Analytics', view: 'dashboard', owner_module: 'analytics', widgets: [
      { id: 'w-auto-1', type: by ? 'bar' : 'stat', title: by ? `${ent === 'request' ? 'Requests' : 'Items'} by ${by}` : 'Records', entity: ent, measure: 'count', by },
    ] }, 'Analytics');
  },
};

export function addModule(bp0: Blueprint, id: string): Blueprint {
  const bp = clone(bp0);
  if (!REGISTRY[id] || bp.modules.includes(id)) return bp;
  bp.modules.push(id);
  ADD[id]?.(bp);
  bp.edges = autoWire(bp);
  return bp;
}

export function removeModule(bp0: Blueprint, id: string): Blueprint {
  const bp = clone(bp0);
  bp.modules = bp.modules.filter(m => m !== id);
  for (const wf of Object.values(bp.workflows)) {
    wf.transitions = wf.transitions.filter(t => t.owner_module !== id);
    wf.states = wf.states.filter(s => s === wf.initial || wf.transitions.some(t => t.to === s || t.from === s));
    wf.terminal = wf.terminal.filter(s => wf.states.includes(s));
    for (const s of wf.states) if (!wf.terminal.includes(s) && !wf.transitions.some(t => t.from === s)) wf.terminal.push(s);
  }
  for (const [k, e] of Object.entries(bp.entities)) {
    if (e.owner_module === id && k !== 'item') delete bp.entities[k];
    else e.fields = e.fields.filter(f => f.owner_module !== id);
  }
  const gone = new Set(bp.pages.filter(p => p.owner_module === id || (p.entity && !bp.entities[p.entity])).map(p => p.path));
  bp.pages = bp.pages.filter(p => !gone.has(p.path));
  bp.nav = bp.nav.filter(n => !gone.has(n.path));
  bp.edges = (bp.edges ?? []).filter(e => e.from.module !== id && e.to.module !== id);
  if (bp.canvas?.positions) delete bp.canvas.positions[id];
  return bp;
}
