# Axel - batch 4 (Builder: canvas, typed ports, presets, publish, rollback, live updates). Run from the axel folder.
$ErrorActionPreference = 'Stop'
function W([string]$Path, [string]$Content) {
  $full = Join-Path $PSScriptRoot $Path
  New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
  $text = $Content.Replace("`r`n", "`n").TrimStart("`n") + "`n"
  [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding $false))
  Write-Host "created $Path"
}
function Patch([string]$Path, [string]$Old, [string]$New) {
  $full = Join-Path $PSScriptRoot $Path
  $text = [System.IO.File]::ReadAllText($full).Replace("`r`n", "`n")
  $Old = $Old.Replace("`r`n", "`n"); $New = $New.Replace("`r`n", "`n")
  if ($text.Contains($New)) { Write-Host "already patched $Path"; return }
  if (-not $text.Contains($Old)) { throw "patch target not found in $Path" }
  [System.IO.File]::WriteAllText($full, $text.Replace($Old, $New), (New-Object System.Text.UTF8Encoding $false))
  Write-Host "patched $Path"
}

# ============================== PATCHES ==============================
Patch 'packages/compiler/src/types.ts' @'
  label?: string; guard?: string; actions?: string[];
'@ @'
  label?: string; guard?: string; actions?: string[]; owner_module?: string;
'@

Patch 'packages/compiler/src/types.ts' @'
  filter?: Record<string, string>; widgets?: Widget[]; roles?: Role[];
'@ @'
  filter?: Record<string, string>; widgets?: Widget[]; roles?: Role[]; owner_module?: string;
'@

Patch 'packages/compiler/src/types.ts' @'
  edges?: Edge[];
'@ @'
  edges?: Edge[];
  canvas?: { positions: Record<string, { x: number; y: number }> };
'@

Patch 'packages/compiler/src/compile.ts' @'
import { REGISTRY } from './registry';
'@ @'
import { REGISTRY } from './registry';
import { portDiagnostics } from './ports';
'@

Patch 'packages/compiler/src/compile.ts' @'
  if (!bp.laws.some(l => l.template === 'site_isolation'))
'@ @'
  out.push(...portDiagnostics(bp));
  if (!bp.laws.some(l => l.template === 'site_isolation'))
'@

Patch 'packages/compiler/src/index.ts' @'
export * from './compile';
'@ @'
export * from './compile';
export * from './ports';
export * from './modules';
export * from './presets';
'@

Patch 'apps/api/src/sites.ts' @'
import { compile, canonicalJson, type Blueprint } from '@axel/compiler';
'@ @'
import { compile, canonicalJson, PRESETS, type Blueprint } from '@axel/compiler';
'@

Patch 'apps/api/src/sites.ts' @'
    blueprint: z.any().optional(),
'@ @'
    blueprint: z.any().optional(),
    preset: z.enum(['inventory-starter', 'approval-chain', 'repair-shop']).optional(),
'@

Patch 'apps/api/src/sites.ts' @'
  const bp: Blueprint = { ...(b.blueprint ?? starterBlueprint()), siteId, slug: b.slug, name: b.name };
'@ @'
  const bp: Blueprint = { ...(b.blueprint ?? (b.preset ? PRESETS[b.preset].build() : starterBlueprint())), siteId, slug: b.slug, name: b.name };
'@

Patch 'apps/api/src/workflowRoutes.ts' @'
import { runTransition, describeTransitions } from './workflow';
'@ @'
import { runTransition, describeTransitions } from './workflow';
import { bus } from './blueprints';
'@

Patch 'apps/api/src/workflowRoutes.ts' @'
  const r = await withSite(s.ctx, tx => runTransition(tx, { ...s.ctx, role: s.role }, s.compiled, s.name, entity, req.params.id, b));
'@ @'
  const r = await withSite(s.ctx, tx => runTransition(tx, { ...s.ctx, role: s.role }, s.compiled, s.name, entity, req.params.id, b));
  if (!r.replay) bus.emit('record_changed', { siteId: s.siteId, entity });
'@

Patch 'apps/api/src/resources.ts' @'
import { describeTransitions } from './workflow';
'@ @'
import { describeTransitions } from './workflow';
import { bus } from './blueprints';
'@

Patch 'apps/api/src/resources.ts' @'
  res.status(201).json(present(req, entity, row));
'@ @'
  bus.emit('record_changed', { siteId: req.site!.siteId, entity });
  res.status(201).json(present(req, entity, row));
'@

Patch 'apps/web/src/api.ts' @'
const h = (siteId: string) => ({ headers: { 'X-Site-Id': siteId } });
'@ @'
const h = (siteId: string) => {
  const p = useSession.getState().preview;
  return { headers: p ? { 'X-Site-Id': siteId, 'X-Preview-Version': p } : { 'X-Site-Id': siteId } };
};
'@

Patch 'apps/web/package.json' @'
    "axios": "^1.7.7",
'@ @'
    "@xyflow/react": "^12.3.2",
    "axios": "^1.7.7",
'@

Patch 'apps/web/src/App.tsx' @'
import SiteShell from './renderer/SiteShell';
'@ @'
import SiteShell from './renderer/SiteShell';
import Builder from './builder/Builder';
'@

Patch 'apps/web/src/App.tsx' @'
      <Route path="/:slug/*"
'@ @'
      <Route path="/builder/:siteId" element={token ? <Builder /> : <Navigate to="/login" replace />} />
      <Route path="/:slug/*"
'@

# ============================== COMPILER: ports, modules, presets ==============================
W 'packages/compiler/src/ports.ts' @'
import type { Blueprint, Diagnostic, Edge } from './types';
import { REGISTRY, type Port, type PortType } from './registry';

const compatible = (out: PortType[], inn: PortType[]) => inn.includes('Any') || out.some(t => inn.includes(t));

export const portOf = (module: string, side: 'in' | 'out', name: string): Port | undefined =>
  REGISTRY[module]?.[side].find(p => p.name === name);

/** null when the connection is legal, otherwise a plain-English reason. */
export function canConnect(e: Edge): string | null {
  const o = portOf(e.from.module, 'out', e.from.port);
  const i = portOf(e.to.module, 'in', e.to.port);
  if (!o || !i) return 'That port does not exist.';
  if (e.from.module === e.to.module) return 'A module cannot feed itself.';
  if (!compatible(o.types, i.types))
    return `${REGISTRY[e.to.module].name} expects ${i.types.join(' or ')} on '${i.name}', but ${REGISTRY[e.from.module].name} outputs ${o.types.join(', ')}.`;
  return null;
}

export const providersFor = (types: PortType[], modules: string[], except?: string) =>
  modules.filter(m => m !== except && REGISTRY[m]?.out.some(o => compatible(o.types, types)));

export function portDiagnostics(bp: Blueprint): Diagnostic[] {
  if (!bp.edges) return []; // legacy blueprints without a canvas graph
  const out: Diagnostic[] = [];
  const mods = new Set(bp.modules);
  for (const e of bp.edges) {
    if (!mods.has(e.from.module) || !mods.has(e.to.module)) {
      out.push({ code: 'EDGE_DANGLING', severity: 'error', nodeId: mods.has(e.to.module) ? e.to.module : e.from.module, message: 'A connection points to a module that is not enabled.', fix: { label: 'Remove connection', patch: { op: 'removeEdge', edge: e } } });
      continue;
    }
    const why = canConnect(e);
    if (why) out.push({ code: 'PORT_TYPE', severity: 'error', nodeId: e.to.module, message: why, fix: { label: 'Remove connection', patch: { op: 'removeEdge', edge: e } } });
  }
  for (const m of bp.modules) {
    const def = REGISTRY[m];
    if (!def) continue;
    for (const p of def.in) {
      if (!p.required || bp.edges.some(e => e.to.module === m && e.to.port === p.name)) continue;
      const names = providersFor(p.types, bp.modules, m).map(x => REGISTRY[x].name);
      out.push({
        code: 'PORT_MISSING', severity: 'error', nodeId: m,
        message: `${def.name} needs ${p.types.join(' or ')} on '${p.name}'. ${names.length ? `Connect ${names.join(' or ')}.` : 'Add a module that provides it.'}`,
        fix: names.length ? { label: 'Auto-connect', patch: { op: 'autoWire' } } : undefined,
      });
    }
  }
  return out;
}

const ORDER = ['auth', 'users', 'dashboard', 'inventory', 'request', 'approval', 'material-assignment', 'pcb-repair', 'assignment-frontend', 'consumption', 'returns', 'analytics', 'excel'];

/** Keep valid edges, then connect every unconnected input to its nearest upstream provider. */
export function autoWire(bp: Blueprint): Edge[] {
  const mods = bp.modules.filter(m => REGISTRY[m]).sort((a, b) => ORDER.indexOf(a) - ORDER.indexOf(b));
  const edges: Edge[] = (bp.edges ?? []).filter(e => mods.includes(e.from.module) && mods.includes(e.to.module) && !canConnect(e));
  for (const m of mods) {
    for (const p of REGISTRY[m].in) {
      if (edges.some(e => e.to.module === m && e.to.port === p.name)) continue;
      let from: string | undefined;
      let port: Port | undefined;
      if (p.types.includes('Any')) {
        from = mods.includes('inventory') ? 'inventory' : mods.find(x => x !== m && REGISTRY[x].out.length);
        port = from ? REGISTRY[from].out[0] : undefined;
      } else {
        const provs = providersFor(p.types, mods, m);
        const upstream = provs.filter(x => ORDER.indexOf(x) < ORDER.indexOf(m));
        from = upstream[upstream.length - 1] ?? provs[0];
        port = from ? REGISTRY[from].out.find(o => compatible(o.types, p.types)) : undefined;
      }
      if (from && port && (p.required || p.types.includes('Any'))) edges.push({ from: { module: from, port: port.name }, to: { module: m, port: p.name } });
    }
  }
  return edges;
}
'@

W 'packages/compiler/src/modules.ts' @'
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
'@

W 'packages/compiler/src/presets.ts' @'
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
    name: 'Repair Shop',
    description: 'Request, approve, repair, close, return.',
    build: () => finish({
      ...id,
      theme: { tokens: { primary: '#0E7490', surface: '#F0FDFA', radius: '12px', font: 'Inter' }, layout: 'kanban-first', density: 'comfortable', home: '/requests' },
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
        initial: 'draft', states: ['draft', 'submitted', 'approved', 'in_repair', 'closed', 'returned', 'rejected'], terminal: ['returned', 'rejected'],
        transitions: [
          { id: 't1', from: 'draft', to: 'submitted', label: 'Submit', roles: M, guard: 'stock.available(item_id) >= qty' },
          { id: 't2', from: 'submitted', to: 'approved', label: 'Approve', roles: MG, actions: ["stock.reserve(item_id, qty, ttl='72h')"] },
          { id: 't3', from: 'submitted', to: 'rejected', label: 'Reject', roles: MG },
          { id: 't4', from: 'approved', to: 'in_repair', label: 'Start repair', roles: MG, actions: ['stock.commit(item_id, qty)', 'repair.open()'] },
          { id: 't5', from: 'in_repair', to: 'closed', label: 'Close', roles: MG, actions: ['repair.close()'] },
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
'@

# ============================== API: versions, events, site scope, server ==============================
W 'apps/api/src/versions.ts' @'
import { Router } from 'express';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { compile, type Blueprint } from '@axel/compiler';
import { withSite, UUID, type Tx } from './db';
import { TABLES } from './entities';
import { AxelError, ah, notFound } from './errors';
import { hashBlueprint } from './sites';
import { invalidate } from './blueprints';

// Mounted at /api/sites/:siteId with requireAuth, siteScope, requireRole('Admin').
export const versionsRouter = Router({ mergeParams: true });

const pin = (req: any, config: any): Blueprint => ({ ...config, siteId: req.site.siteId, slug: req.site.slug });
const Config = z.object({
  configVersion: z.literal(3), modules: z.array(z.string()), entities: z.record(z.any()), workflows: z.record(z.any()),
  pages: z.array(z.any()), nav: z.array(z.any()), roles: z.array(z.string()), laws: z.array(z.any()), theme: z.any(),
}).passthrough();

function summarize(a: Blueprint, b: Blueprint) {
  const c: string[] = [];
  for (const m of b.modules) if (!a.modules.includes(m)) c.push(`+ module ${m}`);
  for (const m of a.modules) if (!b.modules.includes(m)) c.push(`- module ${m}`);
  for (const [ek, e] of Object.entries(b.entities)) {
    const old = a.entities[ek];
    if (!old) { c.push(`+ entity ${ek}`); continue; }
    for (const f of e.fields) if (!old.fields.some(x => x.key === f.key)) c.push(`+ field ${ek}.${f.key}`);
    for (const f of old.fields) if (!e.fields.some(x => x.key === f.key)) c.push(`- field ${ek}.${f.key} (data kept)`);
  }
  for (const ek of Object.keys(a.entities)) if (!b.entities[ek]) c.push(`- entity ${ek} (data kept)`);
  for (const [ek, wf] of Object.entries(b.workflows)) {
    const o = a.workflows[ek];
    for (const s of wf.states) if (!o?.states.includes(s)) c.push(`+ state ${ek}.${s}`);
    for (const s of o?.states ?? []) if (!wf.states.includes(s)) c.push(`- state ${ek}.${s}`);
  }
  for (const p of b.pages) if (!a.pages.some(x => x.path === p.path)) c.push(`+ page ${p.path}`);
  for (const p of a.pages) if (!b.pages.some(x => x.path === p.path)) c.push(`- page ${p.path}`);
  if (a.theme?.layout !== b.theme?.layout) c.push(`~ layout ${a.theme?.layout} to ${b.theme?.layout}`);
  if (a.theme?.tokens?.primary !== b.theme?.tokens?.primary) c.push('~ colours');
  return c;
}

async function stranded(c: Tx, a: Blueprint, b: Blueprint) {
  const out: string[] = [];
  for (const [ek, wf] of Object.entries(a.workflows ?? {})) {
    const removed = wf.states.filter(s => !b.workflows?.[ek]?.states.includes(s));
    const spec = TABLES[ek];
    if (!removed.length || !spec) continue;
    const rows = (await c.query(`SELECT state, count(*)::int AS n FROM ${spec.table} WHERE state = ANY($1) GROUP BY state`, [removed])).rows;
    for (const r of rows) out.push(`${r.n} ${ek} record(s) are in '${r.state}', which this version removes. They stay read-only and their data is kept.`);
  }
  return out;
}

async function deploy(req: any, c: Tx, targetId: string, o: { rollback: boolean; confirm: boolean; reason?: string }) {
  const s = req.site;
  const cur = (await c.query(
    `SELECT v.id, v.config FROM sites st JOIN site_versions v ON v.id = st.published_version_id WHERE st.id = $1 FOR UPDATE OF st`,
    [s.siteId])).rows[0];
  const v = (await c.query('SELECT id, config, status FROM site_versions WHERE id = $1 FOR UPDATE', [targetId])).rows[0];
  if (!v) throw notFound();
  if (cur && cur.id === v.id) throw new AxelError('ALREADY_LIVE', 409, 'That version is already live.');
  if (o.rollback && v.status === 'draft') throw new AxelError('VALIDATION_FAILED', 422, 'Only previously published versions can be rolled back to.');
  if (!o.rollback && v.status !== 'draft') throw new AxelError('VALIDATION_FAILED', 422, 'Publish a draft, or use rollback for an older version.');

  const bp = pin(req, v.config);
  const compiled = compile(bp);
  const errors = compiled.diagnostics.filter(d => d.severity === 'error');
  if (errors.length) throw new AxelError('GATE_NOT_PASSED', 422, `Fix ${errors.length} problem(s) first: ${errors[0].message}`, { diagnostics: errors });

  const changes = cur ? summarize(cur.config, bp) : [];
  const destructive = cur ? await stranded(c, cur.config, bp) : [];
  if (destructive.length && !o.confirm) throw new AxelError('DESTRUCTIVE_CHANGE_UNPLANNED', 409, destructive.join(' '), { destructive, changes });

  const hash = hashBlueprint(bp);
  let liveId = v.id as string;
  if (v.status === 'draft') {
    const same = (await c.query('SELECT id FROM site_versions WHERE content_hash = $1 AND id <> $2', [hash, v.id])).rows[0];
    if (same && cur && same.id === cur.id) throw new AxelError('ALREADY_LIVE', 409, 'No changes compared to the live version.');
    if (same) { liveId = same.id; await c.query('DELETE FROM site_versions WHERE id = $1', [v.id]); }
    else await c.query('UPDATE site_versions SET config = $2, content_hash = $3, reason = coalesce($4, reason) WHERE id = $1', [v.id, bp, hash, o.reason ?? null]);
  }
  if (cur) await c.query(`UPDATE site_versions SET status = 'archived' WHERE id = $1`, [cur.id]);
  await c.query(`UPDATE site_versions SET status = 'published' WHERE id = $1`, [liveId]);
  const prev = (await c.query('SELECT id FROM site_deployments ORDER BY deployed_at DESC, id LIMIT 1')).rows[0];
  const proof = {
    versionHash: hash, compiledAt: new Date().toISOString(), errors: 0,
    warnings: compiled.diagnostics.filter(d => d.severity === 'warning').length,
    changes, destructive, dataPreserved: true, kind: o.rollback ? 'rollback' : 'publish',
  };
  const dep = (await c.query(
    'INSERT INTO site_deployments (site_id, version_id, proof, deployed_by, rollback_of) VALUES ($1,$2,$3,$4,$5) RETURNING id',
    [s.siteId, liveId, proof, s.ctx.userId, o.rollback ? prev?.id ?? null : null])).rows[0];
  await c.query('UPDATE sites SET published_version_id = $2 WHERE id = $1', [s.siteId, liveId]);
  await c.query(`SELECT pg_notify('site_published', $1)`, [`${s.siteId}:${liveId}`]);
  return { deploymentId: dep.id, versionId: liveId, changes, destructive };
}

versionsRouter.get('/builder', ah(async (req, res) => {
  const s = req.site!;
  const out = await withSite(s.ctx, async c => ({
    published: (await c.query(`SELECT v.id, v.config FROM sites st JOIN site_versions v ON v.id = st.published_version_id WHERE st.id = $1`, [s.siteId])).rows[0],
    draft: (await c.query(`SELECT id, config, updated_rev FROM site_versions WHERE status = 'draft' ORDER BY created_at DESC LIMIT 1`)).rows[0] ?? null,
  }));
  res.json({
    site: { id: s.siteId, slug: s.slug, name: s.name },
    published: { versionId: out.published.id, config: pin(req, out.published.config) },
    draft: out.draft && { id: out.draft.id, rev: out.draft.updated_rev, config: pin(req, out.draft.config) },
  });
}));

versionsRouter.get('/versions', ah(async (req, res) => {
  const rows = await withSite(req.site!.ctx, async c => (await c.query(
    `SELECT v.id, v.status, v.content_hash, v.reason, v.created_at, u.name AS author
       FROM site_versions v LEFT JOIN users u ON u.id = v.author_id ORDER BY v.created_at DESC`)).rows);
  res.json(rows);
}));

versionsRouter.post('/versions', ah(async (req, res) => {
  const b = z.object({ config: Config, reason: z.string().max(200).optional() }).parse(req.body);
  const s = req.site!;
  const bp = pin(req, b.config);
  const row = await withSite(s.ctx, async c => (await c.query(
    `INSERT INTO site_versions (site_id, config, content_hash, parent_id, status, author_id, reason)
     VALUES ($1,$2,$3,$4,'draft',$5,$6) RETURNING id, updated_rev`,
    [s.siteId, bp, `draft:${randomUUID()}`, s.versionId, s.ctx.userId, b.reason ?? 'builder draft'])).rows[0]);
  res.status(201).json({ id: row.id, updated_rev: row.updated_rev, diagnostics: compile(bp).diagnostics });
}));

versionsRouter.put('/versions/:v', ah(async (req, res) => {
  if (!UUID.test(req.params.v)) throw notFound();
  const b = z.object({ config: Config, expectedRev: z.number().int() }).parse(req.body);
  const bp = pin(req, b.config);
  const row = await withSite(req.site!.ctx, async c => {
    const r = (await c.query(
      `UPDATE site_versions SET config = $2, updated_rev = updated_rev + 1
        WHERE id = $1 AND status = 'draft' AND updated_rev = $3 RETURNING updated_rev`, [req.params.v, bp, b.expectedRev])).rows[0];
    if (r) return r;
    const cur = (await c.query('SELECT status, updated_rev FROM site_versions WHERE id = $1', [req.params.v])).rows[0];
    if (!cur) throw notFound();
    if (cur.status !== 'draft') throw new AxelError('VERSION_IMMUTABLE', 409, 'Published versions cannot be edited. Reload to start a new draft.');
    throw new AxelError('DRAFT_CONFLICT', 409, `Someone else saved this draft meanwhile (now revision ${cur.updated_rev}). Load the latest and redo your change.`, { current: cur.updated_rev });
  });
  res.json({ updated_rev: row.updated_rev, diagnostics: compile(bp).diagnostics });
}));

versionsRouter.delete('/versions/:v', ah(async (req, res) => {
  if (!UUID.test(req.params.v)) throw notFound();
  await withSite(req.site!.ctx, c => c.query(`DELETE FROM site_versions WHERE id = $1 AND status = 'draft'`, [req.params.v]));
  res.json({ ok: true });
}));

versionsRouter.post('/publish', ah(async (req, res) => {
  const b = z.object({ versionId: z.string().uuid(), reason: z.string().max(200).optional(), confirm: z.boolean().default(false) }).parse(req.body);
  const r = await withSite(req.site!.ctx, c => deploy(req, c, b.versionId, { rollback: false, confirm: b.confirm, reason: b.reason }));
  invalidate(req.site!.siteId);
  res.json(r);
}));

versionsRouter.post('/rollback', ah(async (req, res) => {
  const b = z.object({ versionId: z.string().uuid(), confirm: z.boolean().default(false) }).parse(req.body);
  const r = await withSite(req.site!.ctx, c => deploy(req, c, b.versionId, { rollback: true, confirm: b.confirm }));
  invalidate(req.site!.siteId);
  res.json(r);
}));

versionsRouter.get('/deployments', ah(async (req, res) => {
  const rows = await withSite(req.site!.ctx, async c => (await c.query(
    `SELECT d.id, d.version_id, d.proof, d.deployed_at, d.rollback_of, u.name AS deployed_by_name
       FROM site_deployments d LEFT JOIN users u ON u.id = d.deployed_by ORDER BY d.deployed_at DESC, d.id DESC`)).rows);
  res.json(rows);
}));
'@

W 'apps/api/src/events.ts' @'
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { bus } from './blueprints';
import { memberships } from './auth';
import { ah } from './errors';

bus.setMaxListeners(500);
export const eventsRouter = Router();

// GET /api/events?token=... - server-sent events for every site the user belongs to.
eventsRouter.get('/events', ah(async (req, res) => {
  let userId = '';
  try { userId = String((jwt.verify(String(req.query.token ?? ''), process.env.JWT_SECRET!) as jwt.JwtPayload).sub); }
  catch { res.status(401).end(); return; }
  const mine = new Set((await memberships(userId)).map((m: any) => m.site_id));
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache, no-transform', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
  res.write(': connected\n\n');
  const relay = (type: string) => (ev: { siteId: string }) => {
    if (mine.has(ev.siteId)) res.write(`event: ${type}\ndata: ${JSON.stringify(ev)}\n\n`);
  };
  const onPub = relay('site_published');
  const onRec = relay('record_changed');
  bus.on('site_published', onPub);
  bus.on('record_changed', onRec);
  const ping = setInterval(() => res.write(': ping\n\n'), 25_000);
  req.on('close', () => { bus.off('site_published', onPub); bus.off('record_changed', onRec); clearInterval(ping); });
}));
'@

W 'apps/api/src/site.ts' @'
import type { RequestHandler } from 'express';
import { compile, type Blueprint, type Role } from '@axel/compiler';
import { withSite, UUID, type SiteCtx } from './db';
import { getPublished, type Loaded } from './blueprints';
import { AxelError, ah, notFound } from './errors';

export interface SiteReq extends Loaded { role: Role; ctx: SiteCtx; preview?: boolean }

export const siteScope: RequestHandler = ah(async (req, _res, next) => {
  const siteId = req.params.siteId;
  const isRead = req.method === 'GET';
  if (!UUID.test(siteId)) throw notFound();
  if (req.header('x-site-id') !== siteId)
    throw new AxelError('SITE_HEADER_MISMATCH', 400, 'X-Site-Id must match the site in the URL.');

  const userId = req.user!.id;
  const role = await withSite({ siteId, userId, role: '' }, async c =>
    (await c.query('SELECT role FROM memberships WHERE site_id = $1 AND user_id = $2', [siteId, userId])).rows[0]?.role as Role | undefined);
  if (!role) throw isRead ? notFound() : new AxelError('NO_MEMBERSHIP', 403, 'You are not a member of this site.');

  let loaded = await getPublished(siteId);
  if (!loaded) throw notFound();

  // Preview: an Admin may read the site through a draft Blueprint. Writes are refused.
  const previewId = req.header('x-preview-version');
  if (previewId) {
    if (role !== 'Admin') throw new AxelError('PREVIEW_ADMIN_ONLY', 403, 'Only Admins can preview a draft.');
    if (!isRead) throw new AxelError('PREVIEW_READ_ONLY', 403, 'Preview is read-only. Nothing here is saved.');
    if (!UUID.test(previewId)) throw notFound();
    const cfg = await withSite({ siteId, userId, role }, async c =>
      (await c.query('SELECT config FROM site_versions WHERE id = $1', [previewId])).rows[0]?.config);
    if (!cfg) throw notFound();
    loaded = { ...loaded, versionId: previewId, compiled: compile({ ...cfg, siteId, slug: loaded.slug } as Blueprint) };
  }

  req.site = { ...loaded, role, preview: !!previewId, ctx: { siteId, userId, role, versionId: loaded.versionId } };
  next();
});

export const requireRole = (min: Role): RequestHandler => (req, _res, next) => {
  const rank = { Public: 0, Member: 1, Manager: 2, Admin: 3 };
  next(rank[req.site!.role] >= rank[min] ? undefined
    : new AxelError('FORBIDDEN', 403, `Only ${min}s can do this in ${req.site!.name}.`));
};
'@

W 'apps/api/src/server.ts' @'
import express from 'express';
import { authRouter, requireAuth, memberships } from './auth';
import { sitesRouter } from './sites';
import { siteScope, requireRole } from './site';
import { resources } from './resources';
import { analytics } from './analytics';
import { workflow } from './workflowRoutes';
import { hubRouter } from './hub';
import { versionsRouter } from './versions';
import { eventsRouter } from './events';
import { errorHandler, ah } from './errors';
import { pool } from './db';
import { startPublishListener } from './blueprints';
import { startJobs } from './jobs';

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '2mb' }));

app.get('/api/health', ah(async (_req, res) => { await pool.query('SELECT 1'); res.json({ ok: true }); }));
app.use('/api/auth', authRouter);
app.get('/api/me', requireAuth, ah(async (req, res) => {
  const u = (await pool.query('SELECT id, email, name, is_hub_admin FROM users WHERE id = $1', [req.user!.id])).rows[0];
  res.json({ user: { id: u.id, email: u.email, name: u.name, hubAdmin: u.is_hub_admin }, memberships: await memberships(u.id) });
}));
app.use('/api/sites', sitesRouter);
app.use('/api/sites/:siteId', requireAuth, siteScope, requireRole('Admin'), versionsRouter);
app.use('/api/hub', hubRouter);
app.use('/api', eventsRouter);
app.use('/api/:siteId', requireAuth, siteScope, analytics, workflow, resources);
app.use(errorHandler);

await startPublishListener();
startJobs();
const port = Number(process.env.PORT ?? 4000);
app.listen(port, () => console.log(`Axel API on :${port}`));
'@

# ============================== WEB ==============================
W 'apps/web/src/store/session.ts' @'
import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import { queryClient } from '../queryClient';

export interface User { id: string; email: string; name: string; hubAdmin: boolean }

// Query keys that are not site-scoped survive a switch; everything else is removed.
const GLOBAL_KEYS = new Set(['sites', 'me']);

interface Session {
  token: string | null;
  user: User | null;
  activeSiteId: string | null;
  preview: string | null;
  generation: number;
  login(token: string, user: User): void;
  logout(): void;
  switchSite(id: string | null, preview?: string | null): void;
}

export const useSession = create<Session>()(persist((set, get) => ({
  token: null,
  user: null,
  activeSiteId: null,
  preview: null,
  generation: 0,
  login: (token, user) => {
    queryClient.clear();
    set({ token, user, activeSiteId: null, preview: null, generation: get().generation + 1 });
  },
  logout: () => {
    queryClient.clear();
    set({ token: null, user: null, activeSiteId: null, preview: null, generation: get().generation + 1 });
  },
  switchSite: (id, preview = null) => {
    if (get().activeSiteId === id && get().preview === preview) return;
    // remove (not invalidate) so no row from the previous site or version can ever paint
    queryClient.removeQueries({ predicate: q => !GLOBAL_KEYS.has(String(q.queryKey[0])) });
    set({ activeSiteId: id, preview, generation: get().generation + 1 });
  },
}), { name: 'axel-session', partialize: s => ({ token: s.token, user: s.user }) as any }));
'@

W 'apps/web/src/pages/Hub.tsx' @'
import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { PRESETS } from '@axel/compiler';
import { useSites } from '../hooks';
import { useSession } from '../store/session';
import { http, errOf } from '../api';
import { ChaosCard } from './Chaos';

const CORE = new Set(['auth', 'users', 'dashboard']);
const slugify = (s: string) => s.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);

function NewUnit() {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  const [preset, setPreset] = useState('inventory-starter');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const qc = useQueryClient();
  const nav = useNavigate();
  async function create() {
    setErr(''); setBusy(true);
    try {
      const r = await http.post('/sites', { name, slug: slugify(name), preset });
      await qc.invalidateQueries({ queryKey: ['sites'] });
      nav(`/builder/${r.data.id}`);
    } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  if (!open) return <button onClick={() => setOpen(true)} className="rounded-lg border border-dashed border-slate-300 px-4 py-2 text-sm text-slate-600 hover:bg-white">+ New unit</button>;
  return (
    <div className="space-y-3 rounded-xl border bg-white p-5">
      <div className="font-medium">New unit</div>
      <input value={name} onChange={e => setName(e.target.value)} placeholder="Unit name, e.g. Field Maintenance" className="w-full rounded-lg border px-3 py-2 text-sm" />
      <div className="text-xs text-slate-500">Address: /{slugify(name) || 'your-unit'}</div>
      <div className="grid gap-2 sm:grid-cols-3">
        {Object.entries(PRESETS).map(([k, p]) => (
          <button key={k} onClick={() => setPreset(k)} className={`rounded-lg border p-3 text-left text-sm ${preset === k ? 'border-slate-900 ring-1 ring-slate-900' : ''}`}>
            <div className="font-medium">{p.name}</div><div className="text-xs text-slate-500">{p.description}</div>
          </button>
        ))}
      </div>
      {err && <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
      <div className="flex gap-2">
        <button disabled={busy || slugify(name).length < 2} onClick={create} className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">{busy ? 'Creating...' : 'Create and open builder'}</button>
        <button onClick={() => setOpen(false)} className="rounded-lg border px-4 py-2 text-sm">Cancel</button>
      </div>
    </div>
  );
}

export default function Hub() {
  const sites = useSites();
  const user = useSession(s => s.user);
  const logout = useSession(s => s.logout);
  const switchSite = useSession(s => s.switchSite);
  useEffect(() => { switchSite(null); }, [switchSite]);
  const instances = sites.data?.reduce((n, s) => n + s.modules.length, 0) ?? 0;

  return (
    <div className="min-h-screen bg-slate-50">
      <header className="flex items-center justify-between border-b bg-white px-6 py-3">
        <div className="text-lg font-bold">Axel <span className="font-normal text-slate-400">hub</span></div>
        <div className="flex items-center gap-4 text-sm">
          <span>{user?.name}</span>
          <button onClick={logout} className="text-slate-500 hover:text-slate-900">Log out</button>
        </div>
      </header>
      <main className="mx-auto max-w-5xl space-y-6 p-6">
        <div className="flex items-end justify-between">
          <div>
            <h1 className="text-2xl font-semibold">Your units</h1>
            <p className="text-sm text-slate-500">One login, one codebase. Each unit runs its own published Blueprint.</p>
          </div>
          {user?.hubAdmin && <NewUnit />}
        </div>
        {sites.isLoading && <div className="h-32 animate-pulse rounded-xl bg-slate-200" />}
        <div className="grid gap-4 sm:grid-cols-3">
          {sites.data?.map(s => (
            <div key={s.id} className="flex flex-col rounded-xl border bg-white p-5 shadow-sm">
              <div className="h-2 w-12 rounded-full" style={{ background: s.theme?.primary }} />
              <h2 className="mt-3 text-lg font-semibold">{s.name}</h2>
              <p className="text-xs text-slate-500">{s.theme?.layout} layout - {s.modules.length} modules - you are {s.role}</p>
              <div className="mt-3 flex flex-wrap gap-1">
                {s.modules.filter(m => !CORE.has(m)).map(m => <span key={m} className="rounded bg-slate-100 px-1.5 py-0.5 text-[10px] text-slate-600">{m}</span>)}
              </div>
              <div className="mt-4 flex gap-2 pt-1">
                <Link to={`/${s.slug}`} className="rounded-lg bg-slate-900 px-3 py-1.5 text-sm text-white">Open</Link>
                {s.role === 'Admin' && <Link to={`/builder/${s.id}`} className="rounded-lg border px-3 py-1.5 text-sm">Builder</Link>}
              </div>
            </div>
          ))}
        </div>
        {!!sites.data?.length && (
          <div className="rounded-xl border bg-white p-5">
            <div className="text-xs font-medium uppercase text-slate-400">Reuse meter</div>
            <div className="mt-1 text-2xl font-bold">{instances} module instances, 13 implementations</div>
            <p className="text-sm text-slate-500">Without a shared hub, every unit rebuilds every module it uses.</p>
          </div>
        )}
        {user?.hubAdmin && <ChaosCard />}
      </main>
    </div>
  );
}
'@

W 'apps/web/src/renderer/SiteShell.tsx' @'
import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { Link, Navigate, NavLink, Route, Routes, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useSchema, useSites, useSite, SiteCtx, type SiteSummary } from '../hooks';
import { useSession } from '../store/session';
import { errOf } from '../api';
import { Denial } from './fields';
import { PageView } from './views';
import { RecordDetail } from './RecordDetail';

function Skeleton({ label, color }: { label: string; color?: string }) {
  return (
    <div className="min-h-screen bg-slate-50">
      <div className="border-b bg-white px-6 py-3 font-semibold" style={{ borderTop: `3px solid ${color ?? '#cbd5e1'}` }}>{label}</div>
      <div className="space-y-2 p-6">{[0, 1, 2, 3, 4, 5].map(i => <div key={i} className="h-8 animate-pulse rounded bg-slate-200" />)}</div>
    </div>
  );
}

function SiteSwitcher({ dark }: { dark?: boolean }) {
  const sites = useSites();
  const { slug } = useSite();
  const nav = useNavigate();
  const ref = useRef<HTMLSelectElement>(null);
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        ref.current?.focus();
        (ref.current as any)?.showPicker?.();
      }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, []);
  return (
    <select ref={ref} value={slug} onChange={e => nav(`/${e.target.value}`)} title="Switch site (Ctrl+K)"
      className={`rounded-md px-2 py-1 text-sm ${dark ? 'border border-white/20 bg-white/10 text-white' : 'border border-slate-300 bg-white'}`}>
      {sites.data?.map(s => <option key={s.id} value={s.slug} className="text-slate-900">{s.name}</option>)}
    </select>
  );
}

function UserMenu({ dark }: { dark?: boolean }) {
  const user = useSession(s => s.user);
  const logout = useSession(s => s.logout);
  const { schema, siteId } = useSite();
  const muted = dark ? 'text-white/70 hover:text-white' : 'text-slate-500 hover:text-slate-900';
  return (
    <div className="flex items-center gap-3 text-sm">
      <Link to="/" className={muted}>Hub</Link>
      {schema.role === 'Admin' && <Link to={`/builder/${siteId}`} className={muted}>Builder</Link>}
      <span>{user?.name}</span>
      <span className={`rounded-full px-2 py-0.5 text-xs ${dark ? 'bg-white/20' : 'bg-primary/10 text-primary'}`}>{schema.role}</span>
      <button onClick={logout} className={muted}>Log out</button>
    </div>
  );
}

function NavItems({ variant }: { variant: 'sidebar' | 'top' | 'pill' | 'rail' }) {
  const { schema, base } = useSite();
  const cls = ({ isActive }: { isActive: boolean }) => ({
    sidebar: `block rounded px-3 py-1.5 text-sm ${isActive ? 'bg-primary text-white' : 'hover:bg-slate-800'}`,
    top: `border-b-2 px-1 py-3 text-sm ${isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-slate-500 hover:text-slate-900'}`,
    pill: `rounded-full px-3 py-1 text-sm ${isActive ? 'bg-white font-medium text-primary' : 'text-white/80 hover:bg-white/10'}`,
    rail: `block border-l-4 px-4 py-2 text-sm ${isActive ? 'border-primary bg-primary/5 font-medium text-primary' : 'border-transparent text-slate-600 hover:bg-slate-50'}`,
  })[variant];
  return <>{schema.nav.map(n => <NavLink key={n.path} to={base + n.path} className={cls}>{n.label}</NavLink>)}</>;
}

function SidebarLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="flex min-h-screen">
      <aside className="flex w-56 shrink-0 flex-col bg-slate-900 text-slate-300">
        <div className="flex items-center gap-2 px-4 py-4 font-semibold text-white"><span className="h-3 w-3 rounded-sm bg-primary" />{name}</div>
        <nav className="flex flex-col gap-0.5 px-2"><NavItems variant="sidebar" /></nav>
        <div className="mt-auto p-3"><SiteSwitcher dark /></div>
      </aside>
      <div className="min-w-0 flex-1">
        <header className="flex justify-end border-b bg-white px-4 py-2"><UserMenu /></header>
        <main className="p-4">{children}</main>
      </div>
    </div>
  );
}

function TopbarLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="min-h-screen">
      <header className="flex items-center gap-6 border-b bg-white px-6">
        <div className="py-3 font-semibold">{name}</div>
        <nav className="flex gap-4"><NavItems variant="top" /></nav>
        <div className="ml-auto flex items-center gap-4"><SiteSwitcher /><UserMenu /></div>
      </header>
      <main className="mx-auto max-w-6xl p-6">{children}</main>
    </div>
  );
}

function KanbanFirstLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="min-h-screen">
      <header className="flex items-center gap-6 bg-primary px-6 py-3 text-white">
        <div className="text-lg font-semibold">{name}</div>
        <nav className="flex gap-1"><NavItems variant="pill" /></nav>
        <div className="ml-auto flex items-center gap-4"><SiteSwitcher dark /><UserMenu dark /></div>
      </header>
      <main className="p-6">{children}</main>
    </div>
  );
}

function QueueFirstLayout({ children }: { children: ReactNode }) {
  const { name } = useSite();
  return (
    <div className="flex min-h-screen">
      <aside className="w-64 shrink-0 border-r bg-white">
        <div className="bg-primary/10 px-4 py-4">
          <div className="font-semibold text-primary">{name}</div>
          <div className="mt-2"><SiteSwitcher /></div>
        </div>
        <nav className="py-2"><NavItems variant="rail" /></nav>
      </aside>
      <div className="min-w-0 flex-1">
        <header className="flex justify-end border-b bg-white px-6 py-2"><UserMenu /></header>
        <main className="p-6">{children}</main>
      </div>
    </div>
  );
}

const LAYOUTS: Record<string, (p: { children: ReactNode }) => JSX.Element> = {
  sidebar: SidebarLayout,
  topbar: TopbarLayout,
  'kanban-first': KanbanFirstLayout,
  'queue-first': QueueFirstLayout,
};

// Live updates: a publish or a record change on this site refreshes what is on screen.
function useLive(siteId: string, enabled: boolean, onPublished: () => void) {
  const qc = useQueryClient();
  useEffect(() => {
    const token = useSession.getState().token;
    if (!enabled || !token) return;
    const es = new EventSource(`/api/events?token=${encodeURIComponent(token)}`);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const refresh = () => { clearTimeout(timer); timer = setTimeout(() => qc.invalidateQueries({ predicate: q => q.queryKey[1] === siteId }), 300); };
    es.addEventListener('site_published', (e: MessageEvent) => {
      if (JSON.parse(e.data).siteId !== siteId) return;
      qc.invalidateQueries({ predicate: q => q.queryKey[1] === siteId });
      qc.invalidateQueries({ queryKey: ['sites'] });
      onPublished();
    });
    es.addEventListener('record_changed', (e: MessageEvent) => { if (JSON.parse(e.data).siteId === siteId) refresh(); });
    return () => { clearTimeout(timer); es.close(); };
  }, [siteId, enabled]);
}

function SiteBody({ site, preview }: { site: SiteSummary; preview: string | null }) {
  const schema = useSchema(site.id);
  const nav = useNavigate();
  const switchSite = useSession(s => s.switchSite);
  const [toast, setToast] = useState('');
  useLive(site.id, !preview, () => { setToast('This site was just updated to a new version.'); setTimeout(() => setToast(''), 6000); });

  if (schema.isLoading) return <Skeleton label={site.name} color={site.theme?.primary} />;
  if (schema.error || !schema.data) return <div className="p-6"><Denial err={errOf(schema.error)} /></div>;
  const s = schema.data;
  const base = `/${site.slug}`;
  const home = s.pages.some(p => p.path === s.theme.home) ? s.theme.home : s.pages[0]?.path ?? '/';
  const style = {
    '--primary': s.theme.tokens.primary,
    '--surface': s.theme.tokens.surface,
    '--radius': s.theme.tokens.radius,
    fontFamily: s.theme.tokens.font,
  } as CSSProperties;
  const Layout = LAYOUTS[s.theme.layout] ?? TopbarLayout;

  return (
    <SiteCtx.Provider value={{ siteId: site.id, slug: site.slug, name: s.name, base, schema: s }}>
      <div style={style} className="min-h-screen bg-surface text-slate-800">
        {preview && (
          <div className="sticky top-0 z-50 flex items-center justify-between bg-amber-400 px-4 py-1.5 text-sm text-amber-950">
            <span><b>Previewing draft</b> - read-only, using live data. Nothing here is saved.</span>
            <button onClick={() => { switchSite(site.id, null); nav(base); }} className="rounded bg-amber-950 px-2 py-0.5 text-xs text-white">Exit preview</button>
          </div>
        )}
        {toast && <div className="fixed bottom-4 right-4 z-50 rounded-lg bg-slate-900 px-4 py-2 text-sm text-white shadow-lg">{toast}</div>}
        <Layout>
          <Routes>
            <Route index element={<Navigate to={base + home} replace />} />
            {s.pages.map(p => <Route key={p.path} path={p.path.replace(/^\//, '')} element={<PageView page={p} />} />)}
            <Route path="r/:entity/:id" element={<RecordDetail />} />
            <Route path="*" element={<Denial err={{ message: 'That page is not part of this site.' }} />} />
          </Routes>
        </Layout>
      </div>
    </SiteCtx.Provider>
  );
}

export default function SiteShell() {
  const { slug } = useParams();
  const [params] = useSearchParams();
  const sites = useSites();
  const active = useSession(s => s.activeSiteId);
  const storePreview = useSession(s => s.preview);
  const switchSite = useSession(s => s.switchSite);
  const site = sites.data?.find(s => s.slug === slug);
  const wantPreview = params.get('preview') ?? (site && active === site.id ? storePreview : null);

  useEffect(() => { if (site) switchSite(site.id, wantPreview); }, [site?.id, wantPreview, switchSite]);

  if (sites.isLoading) return <Skeleton label="Loading" />;
  if (!site) return <div className="p-6"><Denial err={{ message: 'Not found.' }} /><Link to="/" className="text-sm underline">Back to hub</Link></div>;
  // Render nothing site-specific until the cache wipe for this site (and version) has happened.
  if (active !== site.id || storePreview !== wantPreview) return <Skeleton label={site.name} color={site.theme?.primary} />;
  return <SiteBody key={`${site.id}:${wantPreview ?? 'live'}`} site={site} preview={wantPreview} />;
}
'@

W 'apps/web/src/builder/Builder.tsx' @'
import { useCallback, useEffect, useMemo, useState, type DragEvent } from 'react';
import { Link, useParams } from 'react-router-dom';
import {
  ReactFlow, ReactFlowProvider, Background, Controls, Handle, Position, useReactFlow,
  applyNodeChanges, applyEdgeChanges, type Connection, type NodeChange, type EdgeChange,
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import {
  compile, REGISTRY, MODULE_IDS, addModule, removeModule, autoWire, canConnect, PRESETS, parse, evaluate,
  type Blueprint, type Diagnostic, type Edge, type Field, type FieldType,
} from '@axel/compiler';
import { http, errOf } from '../api';

const CORE = new Set(['auth', 'users', 'dashboard']);
const PORT_COLOR: Record<string, string> = {
  Identity: '#64748b', Membership: '#64748b', 'Page[]': '#a855f7', ItemStream: '#0ea5e9', StockLedger: '#f59e0b',
  RequestStream: '#10b981', ApprovedStream: '#16a34a', AssignmentStream: '#ef4444', RepairLog: '#8b5cf6', File: '#6b7280', Any: '#94a3b8',
};
const DESC: Record<string, string> = {
  auth: 'Login, JWT and roles.', users: 'Members and their roles.', dashboard: 'Shell, navigation, forms, tables.',
  inventory: 'Items and the stock ledger.', request: 'Members ask for material.', approval: 'Managers approve; stock is reserved.',
  'material-assignment': 'Issue approved stock; reservation committed.', 'assignment-frontend': 'Queue of assignments.',
  consumption: 'Field teams log what they used.', returns: 'Send material back; stock returns.',
  'pcb-repair': 'Board repairs with serial numbers.', analytics: 'Charts for this site.', excel: 'Import and export spreadsheets.',
};
const FIELD_TYPES: FieldType[] = ['text', 'number', 'money', 'date', 'boolean', 'select', 'formula'];
const btn = 'rounded-md bg-slate-900 px-3 py-1.5 text-sm font-medium text-white disabled:opacity-40';
const ghost = 'rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm disabled:opacity-40';
const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v));
const edgeId = (e: Edge) => `${e.from.module}.${e.from.port}>${e.to.module}.${e.to.port}`;
type Msg = { kind: 'ok' | 'err' | 'warn'; text: string; action?: { label: string; run: () => void } } | null;

function ModuleNode({ data }: any) {
  const def = REGISTRY[data.id];
  return (
    <div className={`w-60 rounded-lg border-2 bg-white shadow-sm ${data.selected ? 'border-indigo-500' : data.errors ? 'border-red-400' : 'border-slate-200'}`}>
      <div className="flex items-start justify-between border-b px-3 py-2">
        <div>
          <div className="text-sm font-semibold">{def.name}</div>
          <div className="text-[10px] uppercase tracking-wide text-slate-400">{def.kind}</div>
        </div>
        {data.errors ? <span className="rounded-full bg-red-100 px-2 text-xs font-medium text-red-700">{data.errors}</span> : <span className="text-xs text-emerald-600">ok</span>}
      </div>
      <div className="flex justify-between gap-2 py-2 text-[10px]">
        <div className="space-y-2">
          {def.in.map(p => (
            <div key={p.name} className="relative pl-3">
              <Handle type="target" position={Position.Left} id={p.name} style={{ background: PORT_COLOR[p.types[0]], width: 10, height: 10, left: -6 }} />
              {p.name}{p.required ? '*' : ''} <span className="text-slate-400">{p.types.join('|')}</span>
            </div>
          ))}
        </div>
        <div className="space-y-2 text-right">
          {def.out.map(p => (
            <div key={p.name} className="relative pr-3">
              <span className="text-slate-400">{p.types.join('|')}</span>
              <Handle type="source" position={Position.Right} id={p.name} style={{ background: PORT_COLOR[p.types[0]], width: 10, height: 10, right: -6 }} />
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
const nodeTypes = { module: ModuleNode };

function autoPos(bp: Blueprint) {
  const depth: Record<string, number> = {};
  const d = (m: string, seen: Set<string>): number => {
    if (depth[m] != null) return depth[m];
    if (seen.has(m)) return 0;
    seen.add(m);
    const reqs = (REGISTRY[m]?.requires ?? []).flat().filter(r => bp.modules.includes(r));
    depth[m] = reqs.length ? 1 + Math.max(...reqs.map(r => d(r, seen))) : 0;
    return depth[m];
  };
  bp.modules.forEach(m => d(m, new Set()));
  const cols: Record<number, string[]> = {};
  bp.modules.forEach(m => { (cols[depth[m]] ??= []).push(m); });
  const pos: Record<string, { x: number; y: number }> = {};
  Object.entries(cols).forEach(([c, ms]) => ms.forEach((m, i) => { pos[m] = { x: Number(c) * 300, y: i * 160 }; }));
  return pos;
}

function applyFix(bp: Blueprint, patch: any): Blueprint {
  const b = clone(bp);
  switch (patch?.op) {
    case 'addModule': return addModule(b, patch.id);
    case 'autoWire': b.edges = autoWire(b); return b;
    case 'removeEdge': b.edges = (b.edges ?? []).filter(e => edgeId(e) !== edgeId(patch.edge)); return b;
    case 'markTerminal': b.workflows[patch.entity]?.terminal.push(patch.state); return b;
    case 'addRole': if (!b.roles.includes(patch.role)) b.roles.push(patch.role); return b;
    case 'setField': { const f = b.entities[patch.entity]?.fields.find(x => x.key === patch.key); if (f) f.unique = patch.unique; return b; }
    case 'renameRef': {
      const f = b.entities[patch.entity]?.fields.find(x => x.key === patch.key);
      if (f?.expr) f.expr = f.expr.replace(new RegExp(`\\b${patch.from}\\b`, 'g'), patch.to);
      return b;
    }
  }
  return bp;
}

function summarize(a: Blueprint, b: Blueprint) {
  const c: string[] = [];
  for (const m of b.modules) if (!a.modules.includes(m)) c.push(`+ module ${REGISTRY[m]?.name ?? m}`);
  for (const m of a.modules) if (!b.modules.includes(m)) c.push(`- module ${REGISTRY[m]?.name ?? m}`);
  for (const [ek, e] of Object.entries(b.entities)) {
    const o = a.entities[ek];
    if (!o) { c.push(`+ entity ${ek}`); continue; }
    for (const f of e.fields) if (!o.fields.some(x => x.key === f.key)) c.push(`+ field ${ek}.${f.key}`);
    for (const f of o.fields) if (!e.fields.some(x => x.key === f.key)) c.push(`- field ${ek}.${f.key} (data kept)`);
  }
  for (const [ek, wf] of Object.entries(b.workflows)) {
    for (const s of wf.states) if (!a.workflows[ek]?.states.includes(s)) c.push(`+ state ${s}`);
    for (const s of a.workflows[ek]?.states ?? []) if (!wf.states.includes(s)) c.push(`- state ${s}`);
  }
  for (const p of b.pages) if (!a.pages.some(x => x.path === p.path)) c.push(`+ page ${p.title}`);
  for (const p of a.pages) if (!b.pages.some(x => x.path === p.path)) c.push(`- page ${p.title}`);
  if (a.theme.layout !== b.theme.layout || a.theme.tokens.primary !== b.theme.tokens.primary || a.theme.density !== b.theme.density) c.push('~ theme');
  return c;
}

export default function Builder() {
  return <ReactFlowProvider><BuilderInner /></ReactFlowProvider>;
}

function BuilderInner() {
  const { siteId = '' } = useParams();
  const H = useMemo(() => ({ headers: { 'X-Site-Id': siteId } }), [siteId]);
  const rf = useReactFlow();
  const [loadErr, setLoadErr] = useState('');
  const [site, setSite] = useState<{ id: string; slug: string; name: string } | null>(null);
  const [published, setPublished] = useState<{ versionId: string; config: Blueprint } | null>(null);
  const [bp, setBp] = useState<Blueprint | null>(null);
  const [draft, setDraft] = useState<{ id: string; rev: number } | null>(null);
  const [dirty, setDirty] = useState(false);
  const [history, setHistory] = useState<Blueprint[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [tab, setTab] = useState<'problems' | 'module' | 'theme' | 'json' | 'versions'>('problems');
  const [msg, setMsg] = useState<Msg>(null);
  const [busy, setBusy] = useState(false);
  const [rfNodes, setRfNodes] = useState<any[]>([]);
  const [rfEdges, setRfEdges] = useState<any[]>([]);
  const [versionsKey, setVersionsKey] = useState(0);

  const load = useCallback(async () => {
    try {
      const r = await http.get(`/sites/${siteId}/builder`, H);
      setSite(r.data.site);
      setPublished(r.data.published);
      const base: Blueprint = r.data.draft?.config ?? r.data.published.config;
      setBp(base.edges ? base : { ...base, edges: autoWire(base) });
      setDraft(r.data.draft ? { id: r.data.draft.id, rev: r.data.draft.rev } : null);
      setDirty(false); setHistory([]); setLoadErr('');
    } catch (e) { setLoadErr(errOf(e).message); }
  }, [siteId, H]);
  useEffect(() => { load(); }, [load]);

  const diags: Diagnostic[] = useMemo(() => (bp ? compile(bp).diagnostics : []), [bp]);
  const errors = diags.filter(d => d.severity === 'error');
  const changes = useMemo(() => (bp && published ? summarize(published.config, bp) : []), [bp, published]);

  const update = useCallback((next: Blueprint) => {
    setHistory(h => (bp ? [...h.slice(-99), bp] : h));
    setBp(next); setDirty(true);
  }, [bp]);
  const undo = () => {
    if (!history.length) return;
    setBp(history[history.length - 1]); setHistory(history.slice(0, -1)); setDirty(true);
  };

  // React Flow nodes and edges are a projection of the Blueprint.
  const derivedNodes = useMemo(() => {
    if (!bp) return [];
    const auto = autoPos(bp);
    const saved = bp.canvas?.positions ?? {};
    return bp.modules.filter(m => REGISTRY[m]).map(m => ({
      id: m, type: 'module', position: saved[m] ?? auto[m] ?? { x: 0, y: 0 }, deletable: !CORE.has(m),
      data: { id: m, selected: selected === m, errors: diags.filter(d => d.severity === 'error' && d.nodeId === m).length },
    }));
  }, [bp, diags, selected]);
  useEffect(() => {
    setRfNodes(prev => {
      const byId = new Map(prev.map(n => [n.id, n]));
      return derivedNodes.map(n => ({ ...byId.get(n.id), ...n }));
    });
  }, [derivedNodes]);
  useEffect(() => {
    setRfEdges((bp?.edges ?? []).map(e => {
      const t = REGISTRY[e.from.module]?.out.find(p => p.name === e.from.port)?.types[0] ?? 'Any';
      return { id: edgeId(e), source: e.from.module, sourceHandle: e.from.port, target: e.to.module, targetHandle: e.to.port, label: t, style: { stroke: PORT_COLOR[t], strokeWidth: 2 }, labelStyle: { fontSize: 10 } };
    }));
  }, [bp]);

  const add = (id: string, pos?: { x: number; y: number }) => {
    if (!bp) return;
    if (bp.modules.includes(id)) { setSelected(id); setTab('module'); return; }
    let next = addModule(bp, id);
    if (pos) next = { ...next, canvas: { positions: { ...(next.canvas?.positions ?? {}), [id]: pos } } };
    update(next);
    setSelected(id); setTab('module');
    setMsg({ kind: 'ok', text: `${REGISTRY[id].name} added. Check Problems, then Save and Publish.` });
  };

  async function save(): Promise<string | null> {
    if (!bp) return null;
    setBusy(true);
    try {
      if (!draft) {
        const r = await http.post(`/sites/${siteId}/versions`, { config: bp, reason: 'builder draft' }, H);
        setDraft({ id: r.data.id, rev: r.data.updated_rev }); setDirty(false);
        return r.data.id;
      }
      const r = await http.put(`/sites/${siteId}/versions/${draft.id}`, { config: bp, expectedRev: draft.rev }, H);
      setDraft({ id: draft.id, rev: r.data.updated_rev }); setDirty(false);
      return draft.id;
    } catch (e) {
      const er = errOf(e);
      setMsg({ kind: 'err', text: er.message, action: er.code === 'DRAFT_CONFLICT' || er.code === 'VERSION_IMMUTABLE' ? { label: 'Load latest', run: load } : undefined });
      return null;
    } finally { setBusy(false); }
  }

  async function publish(confirm = false) {
    const id = dirty || !draft ? await save() : draft.id;
    if (!id) return;
    setBusy(true);
    try {
      const r = await http.post(`/sites/${siteId}/publish`, { versionId: id, confirm }, H);
      setMsg({ kind: 'ok', text: `Published. ${r.data.changes.length ? r.data.changes.join(', ') + '.' : ''} Open windows of this site update by themselves.` });
      setVersionsKey(k => k + 1);
      await load();
    } catch (e) {
      const er = errOf(e);
      if (er.code === 'DESTRUCTIVE_CHANGE_UNPLANNED') setMsg({ kind: 'warn', text: er.message, action: { label: 'Publish anyway', run: () => publish(true) } });
      else setMsg({ kind: er.code === 'ALREADY_LIVE' ? 'warn' : 'err', text: er.message });
    } finally { setBusy(false); }
  }

  async function preview() {
    const id = dirty || !draft ? await save() : draft.id;
    if (id && site) window.open(`/${site.slug}?preview=${id}`, '_blank');
  }

  async function discard() {
    if (!draft) { await load(); return; }
    if (!window.confirm('Discard this draft and go back to the live version?')) return;
    await http.delete(`/sites/${siteId}/versions/${draft.id}`, H).catch(() => {});
    await load();
    setMsg({ kind: 'ok', text: 'Draft discarded.' });
  }

  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save(); }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'z' && !(e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement)) { e.preventDefault(); undo(); }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  });

  const onConnect = (c: Connection) => {
    if (!bp || !c.source || !c.target || !c.sourceHandle || !c.targetHandle) return;
    const e: Edge = { from: { module: c.source, port: c.sourceHandle }, to: { module: c.target, port: c.targetHandle } };
    const why = canConnect(e);
    if (why) return setMsg({ kind: 'err', text: why });
    if ((bp.edges ?? []).some(x => edgeId(x) === edgeId(e))) return;
    update({ ...bp, edges: [...(bp.edges ?? []), e] });
  };
  const onDrop = (e: DragEvent) => {
    e.preventDefault();
    const id = e.dataTransfer.getData('application/axel-module');
    if (id) add(id, rf.screenToFlowPosition({ x: e.clientX, y: e.clientY }));
  };

  if (loadErr) return <div className="p-6"><div className="rounded-lg bg-red-50 p-4 text-red-700">{loadErr}</div><Link to="/" className="text-sm underline">Back to hub</Link></div>;
  if (!bp || !site || !published) return <div className="p-6 text-slate-500">Loading builder...</div>;

  return (
    <div className="flex h-screen flex-col bg-slate-50 text-slate-800">
      <header className="flex items-center gap-3 border-b bg-white px-4 py-2">
        <Link to="/" className="text-sm text-slate-500 hover:text-slate-900">&lt; Hub</Link>
        <div className="font-semibold">Builder - {site.name}</div>
        <span className={`rounded-full px-2 py-0.5 text-xs ${dirty ? 'bg-amber-100 text-amber-800' : draft ? 'bg-sky-100 text-sky-800' : 'bg-emerald-100 text-emerald-800'}`}>
          {dirty ? 'Unsaved changes' : draft ? 'Draft saved' : 'Matches live'}
        </span>
        <span className="text-xs text-slate-400">live {published.versionId.slice(0, 8)}</span>
        <div className="ml-auto flex items-center gap-2">
          <select defaultValue="" onChange={e => {
            const k = e.target.value; e.target.value = '';
            if (!k || !window.confirm(`Replace this site's modules and workflow with the ${PRESETS[k].name} preset? Data is kept.`)) return;
            const p = PRESETS[k].build();
            update({ ...p, siteId: bp.siteId, slug: bp.slug, name: bp.name, theme: { ...p.theme, tokens: bp.theme.tokens } });
          }} className="rounded-md border px-2 py-1.5 text-sm">
            <option value="">Apply preset...</option>
            {Object.entries(PRESETS).map(([k, p]) => <option key={k} value={k}>{p.name}</option>)}
          </select>
          <button onClick={undo} disabled={!history.length} className={ghost}>Undo</button>
          <button onClick={discard} disabled={!draft && !dirty} className={ghost}>Discard</button>
          <button onClick={() => save()} disabled={busy || !dirty} className={ghost}>Save draft</button>
          <button onClick={preview} disabled={busy} className={ghost}>Preview</button>
          <a href={`/${site.slug}`} target="_blank" rel="noreferrer" className={ghost}>Open live</a>
          <button onClick={() => publish()} disabled={busy || !!errors.length || (!dirty && !draft)} className={btn}
            title={errors.length ? 'Fix the problems first' : ''}>Publish</button>
        </div>
      </header>

      {msg && (
        <div className={`flex items-center gap-3 px-4 py-2 text-sm ${msg.kind === 'ok' ? 'bg-emerald-50 text-emerald-800' : msg.kind === 'warn' ? 'bg-amber-50 text-amber-900' : 'bg-red-50 text-red-800'}`}>
          <span className="flex-1">{msg.text}</span>
          {msg.action && <button onClick={() => { const a = msg.action!; setMsg(null); a.run(); }} className="rounded bg-slate-900 px-2 py-1 text-xs text-white">{msg.action.label}</button>}
          <button onClick={() => setMsg(null)} className="text-xs underline">dismiss</button>
        </div>
      )}

      <div className="grid min-h-0 flex-1 grid-cols-[230px_1fr_400px]">
        <aside className="overflow-y-auto border-r bg-white p-3">
          <div className="mb-2 text-xs font-medium uppercase text-slate-400">Modules - drag onto the canvas</div>
          <div className="space-y-1.5">
            {MODULE_IDS.map(id => {
              const on = bp.modules.includes(id);
              return (
                <div key={id} draggable={!on} onDragStart={e => e.dataTransfer.setData('application/axel-module', id)}
                  onClick={() => (on ? (setSelected(id), setTab('module')) : add(id))}
                  className={`cursor-pointer rounded-md border p-2 text-sm ${on ? 'border-emerald-200 bg-emerald-50' : 'hover:border-slate-400'}`}>
                  <div className="flex items-center justify-between font-medium">{REGISTRY[id].name}{on && <span className="text-xs text-emerald-700">on</span>}</div>
                  <div className="text-xs text-slate-500">{DESC[id]}</div>
                </div>
              );
            })}
          </div>
        </aside>

        <div className="min-h-0" onDragOver={e => e.preventDefault()} onDrop={onDrop}>
          <ReactFlow
            nodes={rfNodes} edges={rfEdges} nodeTypes={nodeTypes} fitView
            onNodesChange={(ch: NodeChange[]) => setRfNodes(ns => applyNodeChanges(ch.filter(c => c.type !== 'remove'), ns))}
            onEdgesChange={(ch: EdgeChange[]) => setRfEdges(es => applyEdgeChanges(ch.filter(c => c.type !== 'remove'), es))}
            onNodeDragStop={(_, n) => update({ ...bp, canvas: { positions: { ...(bp.canvas?.positions ?? {}), [n.id]: n.position } } })}
            onNodeClick={(_, n) => { setSelected(n.id); setTab('module'); }}
            onNodesDelete={ns => {
              let next = bp;
              for (const n of ns) if (!CORE.has(n.id)) next = removeModule(next, n.id);
              if (next !== bp) { update(next); setSelected(null); }
            }}
            onEdgesDelete={es => update({ ...bp, edges: (bp.edges ?? []).filter(e => !es.some(d => d.id === edgeId(e))) })}
            onConnect={onConnect}
          >
            <Background gap={20} />
            <Controls />
          </ReactFlow>
        </div>

        <aside className="flex min-h-0 flex-col border-l bg-white">
          <nav className="flex border-b text-sm">
            {([['problems', `Problems${errors.length ? ` (${errors.length})` : ''}`], ['module', 'Module'], ['theme', 'Theme'], ['json', 'JSON'], ['versions', 'Versions']] as const).map(([k, label]) => (
              <button key={k} onClick={() => setTab(k)} className={`flex-1 border-b-2 px-2 py-2 ${tab === k ? 'border-slate-900 font-medium' : 'border-transparent text-slate-500'}`}>{label}</button>
            ))}
          </nav>
          <div className="min-h-0 flex-1 overflow-y-auto p-4">
            {tab === 'problems' && <ProblemsPanel diags={diags} changes={changes} onFix={d => update(applyFix(bp, d.fix?.patch))} onSelect={id => { setSelected(id); setTab('module'); }} />}
            {tab === 'module' && <ModulePanel bp={bp} id={selected} update={update} onRemove={id => { update(removeModule(bp, id)); setSelected(null); }} />}
            {tab === 'theme' && <ThemePanel bp={bp} update={update} />}
            {tab === 'json' && <JsonPanel bp={bp} update={update} />}
            {tab === 'versions' && <VersionsPanel siteId={siteId} H={H} refreshKey={versionsKey} onChanged={async m => { setMsg(m); setVersionsKey(k => k + 1); await load(); }} />}
          </div>
        </aside>
      </div>
    </div>
  );
}

function ProblemsPanel({ diags, changes, onFix, onSelect }: { diags: Diagnostic[]; changes: string[]; onFix: (d: Diagnostic) => void; onSelect: (id: string) => void }) {
  return (
    <div className="space-y-4">
      {!diags.length && <div className="rounded-lg bg-emerald-50 p-3 text-sm text-emerald-800">No problems. This draft is ready to publish.</div>}
      {diags.map((d, i) => (
        <div key={i} className={`rounded-lg border p-3 text-sm ${d.severity === 'error' ? 'border-red-200 bg-red-50' : 'border-amber-200 bg-amber-50'}`}>
          <div>{d.message}</div>
          <div className="mt-2 flex items-center gap-2 text-xs">
            <span className="font-mono text-slate-500">{d.code}</span>
            {d.nodeId && REGISTRY[d.nodeId] && <button onClick={() => onSelect(d.nodeId!)} className="underline">{REGISTRY[d.nodeId].name}</button>}
            {d.fix && <button onClick={() => onFix(d)} className="ml-auto rounded bg-slate-900 px-2 py-0.5 text-white">{d.fix.label}</button>}
          </div>
        </div>
      ))}
      <div>
        <div className="mb-1 text-xs font-medium uppercase text-slate-400">Changes compared to live</div>
        {changes.length ? <ul className="space-y-0.5 font-mono text-xs">{changes.map(c => <li key={c}>{c}</li>)}</ul> : <div className="text-sm text-slate-400">None yet.</div>}
      </div>
    </div>
  );
}

function ModulePanel({ bp, id, update, onRemove }: { bp: Blueprint; id: string | null; update: (b: Blueprint) => void; onRemove: (id: string) => void }) {
  if (!id || !REGISTRY[id]) return <div className="text-sm text-slate-500">Click a module on the canvas, or add one from the left.</div>;
  const def = REGISTRY[id];
  const on = bp.modules.includes(id);
  const owned = Object.entries(bp.entities).filter(([, e]) => e.owner_module === id).map(([k]) => k);
  const wf = bp.workflows.request;
  const steps = wf?.transitions.filter(t => (t.owner_module ?? (['request', 'approval'].includes(id) ? undefined : '')) === id || (id === 'request' && !t.owner_module)) ?? [];
  return (
    <div className="space-y-4 text-sm">
      <div>
        <div className="text-lg font-semibold">{def.name}</div>
        <div className="text-slate-500">{DESC[id]}</div>
      </div>
      <div className="grid grid-cols-2 gap-2 text-xs">
        <div className="rounded border p-2"><div className="mb-1 font-medium text-slate-500">Inputs</div>{def.in.length ? def.in.map(p => <div key={p.name}>{p.name}{p.required ? '*' : ''}: {p.types.join(' | ')}</div>) : 'none'}</div>
        <div className="rounded border p-2"><div className="mb-1 font-medium text-slate-500">Outputs</div>{def.out.length ? def.out.map(p => <div key={p.name}>{p.name}: {p.types.join(' | ')}</div>) : 'none'}</div>
      </div>
      {!!def.requires.length && <div className="text-xs text-slate-500">Requires: {def.requires.map(g => g.map(r => REGISTRY[r].name).join(' or ')).join(', ')}</div>}
      {!!steps.length && (
        <div>
          <div className="mb-1 text-xs font-medium uppercase text-slate-400">Workflow steps</div>
          {steps.map(t => <div key={t.id} className="font-mono text-xs">{t.id}: {t.from} &rarr; {t.to} ({t.roles.filter(r => r !== 'Public').join(', ')}){t.actions?.length ? ` [${t.actions.join('; ')}]` : ''}</div>)}
        </div>
      )}
      {owned.map(ek => <FieldEditor key={ek} bp={bp} entity={ek} update={update} />)}
      {on && !CORE.has(id) && <button onClick={() => onRemove(id)} className="rounded-md border border-red-300 px-3 py-1.5 text-red-700">Remove module</button>}
    </div>
  );
}

function FieldEditor({ bp, entity, update }: { bp: Blueprint; entity: string; update: (b: Blueprint) => void }) {
  const ent = bp.entities[entity];
  const [f, setF] = useState({ key: '', label: '', type: 'text' as FieldType, options: '', expr: '' });
  const keyOk = /^[a-z][a-z0-9_]{1,30}$/.test(f.key) && !ent.fields.some(x => x.key === f.key);
  let preview: string = '';
  if (f.type === 'formula' && f.expr) {
    const sample: Record<string, number> = { qty: 2, unit_price: 150, on_hand: 10, reserved: 2, available: 8 };
    try { preview = String(evaluate(parse(f.expr), { get: k => sample[k] ?? 1 })); } catch (e) { preview = (e as Error).message; }
  }
  const addField = () => {
    const field: Field = { key: f.key, label: f.label || f.key, type: f.type, origin: { kind: 'manual' } };
    if (f.type === 'select') field.options = f.options.split(',').map(s => s.trim()).filter(Boolean);
    if (f.type === 'formula') field.expr = f.expr;
    const next = clone(bp);
    next.entities[entity].fields.push(field);
    next.pages.forEach(p => { if (p.entity === entity && p.columns && !p.columns.includes(f.key)) p.columns.push(f.key); });
    update(next);
    setF({ key: '', label: '', type: 'text', options: '', expr: '' });
  };
  const removeField = (key: string) => {
    const next = clone(bp);
    next.entities[entity].fields = next.entities[entity].fields.filter(x => x.key !== key);
    next.pages.forEach(p => { if (p.columns) p.columns = p.columns.filter(c => c !== key); });
    update(next);
  };
  return (
    <div className="space-y-2 rounded-lg border p-3">
      <div className="font-medium">{ent.label ?? entity} fields</div>
      <div className="space-y-1">
        {ent.fields.map(x => (
          <div key={x.key} className="flex items-center justify-between text-xs">
            <span><span className="font-mono">{x.key}</span> <span className="text-slate-400">{x.type}{x.expr ? ` = ${x.expr}` : ''}{x.roles?.read ? ` - visible to ${x.roles.read.join(', ')}` : ''}</span></span>
            {x.origin?.kind === 'manual' && <button onClick={() => removeField(x.key)} className="text-red-600">remove</button>}
          </div>
        ))}
      </div>
      <div className="grid grid-cols-2 gap-2 border-t pt-2">
        <input value={f.key} onChange={e => setF({ ...f, key: e.target.value })} placeholder="key, e.g. priority" className="rounded border px-2 py-1 text-xs" />
        <input value={f.label} onChange={e => setF({ ...f, label: e.target.value })} placeholder="Label" className="rounded border px-2 py-1 text-xs" />
        <select value={f.type} onChange={e => setF({ ...f, type: e.target.value as FieldType })} className="rounded border px-2 py-1 text-xs">
          {FIELD_TYPES.map(t => <option key={t}>{t}</option>)}
        </select>
        {f.type === 'select' && <input value={f.options} onChange={e => setF({ ...f, options: e.target.value })} placeholder="low, normal, urgent" className="rounded border px-2 py-1 text-xs" />}
        {f.type === 'formula' && <input value={f.expr} onChange={e => setF({ ...f, expr: e.target.value })} placeholder="qty * unit_price" className="rounded border px-2 py-1 font-mono text-xs" />}
      </div>
      {f.type === 'formula' && f.expr && <div className="text-xs text-slate-500">On a sample row (qty 2, unit_price 150): <b>{preview}</b></div>}
      <button disabled={!keyOk || (f.type === 'formula' && !f.expr)} onClick={addField} className="rounded-md bg-slate-900 px-3 py-1 text-xs text-white disabled:opacity-40">Add field</button>
    </div>
  );
}

function ThemePanel({ bp, update }: { bp: Blueprint; update: (b: Blueprint) => void }) {
  const set = (patch: Partial<Blueprint['theme']>, tokens?: Partial<Blueprint['theme']['tokens']>) =>
    update({ ...bp, theme: { ...bp.theme, ...patch, tokens: { ...bp.theme.tokens, ...(tokens ?? {}) } } });
  return (
    <div className="space-y-4 text-sm">
      <label className="block"><span className="mb-1 block text-xs text-slate-500">Layout</span>
        <select value={bp.theme.layout} onChange={e => set({ layout: e.target.value as any })} className="w-full rounded border px-2 py-1.5">
          <option value="sidebar">Sidebar (dense, analytics)</option>
          <option value="topbar">Top bar (cards)</option>
          <option value="kanban-first">Kanban first (boards)</option>
          <option value="queue-first">Queue first (work lists)</option>
        </select>
      </label>
      <label className="block"><span className="mb-1 block text-xs text-slate-500">Density</span>
        <select value={bp.theme.density} onChange={e => set({ density: e.target.value as any })} className="w-full rounded border px-2 py-1.5">
          <option value="compact">Compact</option><option value="comfortable">Comfortable</option>
        </select>
      </label>
      <div className="grid grid-cols-2 gap-3">
        <label className="block"><span className="mb-1 block text-xs text-slate-500">Primary colour</span>
          <input type="color" value={bp.theme.tokens.primary} onChange={e => set({}, { primary: e.target.value })} className="h-9 w-full" /></label>
        <label className="block"><span className="mb-1 block text-xs text-slate-500">Background</span>
          <input type="color" value={bp.theme.tokens.surface} onChange={e => set({}, { surface: e.target.value })} className="h-9 w-full" /></label>
      </div>
      <label className="block"><span className="mb-1 block text-xs text-slate-500">Home page</span>
        <select value={bp.theme.home} onChange={e => set({ home: e.target.value })} className="w-full rounded border px-2 py-1.5">
          {bp.pages.map(p => <option key={p.path} value={p.path}>{p.title}</option>)}
        </select>
      </label>
      <label className="block"><span className="mb-1 block text-xs text-slate-500">Site name</span>
        <input value={bp.name} onChange={e => update({ ...bp, name: e.target.value })} className="w-full rounded border px-2 py-1.5" /></label>
    </div>
  );
}

function JsonPanel({ bp, update }: { bp: Blueprint; update: (b: Blueprint) => void }) {
  const [text, setText] = useState(() => JSON.stringify(bp, null, 2));
  const [err, setErr] = useState('');
  useEffect(() => { setText(JSON.stringify(bp, null, 2)); }, [bp]);
  const apply = () => {
    try {
      const next = JSON.parse(text);
      if (next.configVersion !== 3) throw new Error('configVersion must be 3');
      update({ ...next, siteId: bp.siteId, slug: bp.slug });
      setErr('');
    } catch (e) { setErr((e as Error).message); }
  };
  return (
    <div className="flex h-full flex-col gap-2">
      <div className="text-xs text-slate-500">The canvas and this JSON are the same Blueprint. Edit either one.</div>
      <textarea value={text} onChange={e => setText(e.target.value)} spellCheck={false} className="min-h-[60vh] flex-1 rounded border p-2 font-mono text-[11px]" />
      {err && <div className="rounded bg-red-50 px-2 py-1 text-xs text-red-700">{err}</div>}
      <button onClick={apply} className="self-start rounded-md bg-slate-900 px-3 py-1.5 text-sm text-white">Apply JSON</button>
    </div>
  );
}

function VersionsPanel({ siteId, H, refreshKey, onChanged }: { siteId: string; H: any; refreshKey: number; onChanged: (m: Msg) => void }) {
  const [deps, setDeps] = useState<any[] | null>(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    http.get(`/sites/${siteId}/deployments`, H).then(r => setDeps(r.data), e => setErr(errOf(e).message));
  }, [siteId, H, refreshKey]);
  async function rollback(versionId: string, confirm = false) {
    try {
      const r = await http.post(`/sites/${siteId}/rollback`, { versionId, confirm }, H);
      onChanged({ kind: 'ok', text: `Rolled back. ${r.data.changes.join(', ')}. All data is kept.` });
    } catch (e) {
      const er = errOf(e);
      if (er.code === 'DESTRUCTIVE_CHANGE_UNPLANNED') onChanged({ kind: 'warn', text: er.message, action: { label: 'Roll back anyway', run: () => rollback(versionId, true) } });
      else onChanged({ kind: 'err', text: er.message });
    }
  }
  if (err) return <div className="text-sm text-red-700">{err}</div>;
  if (!deps) return <div className="text-sm text-slate-500">Loading...</div>;
  const liveVersion = deps[0]?.version_id;
  return (
    <div className="space-y-3">
      <div className="text-xs text-slate-500">Every publish and rollback, newest first. Rolling back never deletes data.</div>
      {deps.map((d, i) => (
        <div key={d.id} className={`rounded-lg border p-3 text-sm ${i === 0 ? 'border-emerald-300 bg-emerald-50' : ''}`}>
          <div className="flex items-center justify-between">
            <span className="font-medium">{d.proof?.kind === 'rollback' || d.rollback_of ? 'Rollback' : d.proof?.seeded ? 'Seeded' : 'Publish'}{i === 0 && <span className="ml-2 rounded bg-emerald-600 px-1.5 text-xs text-white">LIVE</span>}</span>
            <span className="text-xs text-slate-500">{new Date(d.deployed_at).toLocaleString()}</span>
          </div>
          <div className="text-xs text-slate-500">by {d.deployed_by_name ?? 'system'} - version {String(d.version_id).slice(0, 8)} - {String(d.proof?.versionHash ?? '').slice(0, 15)}</div>
          {!!d.proof?.changes?.length && <ul className="mt-1 font-mono text-[11px]">{d.proof.changes.map((c: string) => <li key={c}>{c}</li>)}</ul>}
          {d.version_id !== liveVersion && <button onClick={() => rollback(d.version_id)} className="mt-2 rounded-md border px-2 py-1 text-xs">Roll back to this version</button>}
        </div>
      ))}
    </div>
  );
}
'@

Write-Host ''
Write-Host 'Batch 4 done. Next: pnpm install, then start pnpm dev:api and pnpm dev:web'