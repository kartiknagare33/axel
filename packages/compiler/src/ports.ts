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
