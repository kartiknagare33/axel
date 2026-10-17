import { useCallback, useEffect, useMemo, useState, type DragEvent } from 'react';
import { Link, useParams } from 'react-router-dom';
import {
  ReactFlow, ReactFlowProvider, Background, Controls, Handle, Position, useReactFlow, useNodesInitialized,
  applyNodeChanges, applyEdgeChanges, type Connection, type NodeChange, type EdgeChange,
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import {
  compile, REGISTRY, MODULE_IDS, addModule, removeModule, autoWire, canConnect, PRESETS, parse, evaluate,
  type Blueprint, type Diagnostic, type Edge, type Field, type FieldType,
} from '@axel/compiler';
import { http, errOf } from '../api';
import { GatePanel } from './GatePanel';
import { LawsPanel, RoleToggle } from './LawsPanel';
import { WorkflowPanel } from './WorkflowPanel';
import { ImpactPanel } from './ImpactPanel';
import { ReleasesPanel } from './ReleasesPanel';
import { PeoplePanel } from './PeoplePanel';
import { HelpButton } from '../help/HelpPanel';
import { BuilderHelp } from '../help/content';
import { TAB_HELP } from '../help/glossary';
import { markDone } from '../help/progress';

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
  const [tab, setTab] = useState<'problems' | 'module' | 'workflow' | 'laws' | 'gate' | 'impact' | 'theme' | 'json' | 'versions' | 'people'>('problems');
  const [gate, setGate] = useState<any>(null);
  const [gating, setGating] = useState(false);
  const [impact, setImpact] = useState<any>(null);
  const [impacting, setImpacting] = useState(false);
  const [plans, setPlans] = useState<Record<string, string>>({});
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
  useEffect(() => { markDone('openedBuilder'); }, []);

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

  const nodesReady = useNodesInitialized();
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
  }, [bp, nodesReady]);

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

  async function runGate(steps = 300, versionId?: string) {
    const id = versionId ?? (dirty || !draft ? await save() : draft.id);
    if (!id) return null;
    setTab('gate'); setGating(true); setGate(null);
    try {
      const r = await http.post(`/sites/${siteId}/versions/${id}/gate`, { steps }, H);
      setGate(r.data);
      markDone('ranGate');
      return r.data;
    } catch (e) { setMsg({ kind: 'err', text: errOf(e).message }); return null; }
    finally { setGating(false); }
  }

  async function exportSite() {
    try {
      const r = await http.get(`/sites/${siteId}/export`, { ...H, responseType: 'blob' });
      const url = URL.createObjectURL(r.data);
      const a = document.createElement('a');
      a.href = url; a.download = `${site?.slug ?? 'site'}-export.zip`;
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (e) { setMsg({ kind: 'err', text: errOf(e).message }); }
  }

  async function explainSite() {
    try {
      const r = await http.get(`/sites/${siteId}/explain`, { ...H, responseType: 'text' });
      const w = window.open('', '_blank');
      if (!w) return;
      w.document.title = `${site?.name ?? 'Site'} - explained`;
      const pre = w.document.createElement('pre');
      pre.textContent = String(r.data);
      pre.style.cssText = 'white-space:pre-wrap;font:14px/1.6 ui-monospace,Consolas,monospace;padding:24px;max-width:960px;margin:auto';
      w.document.body.appendChild(pre);
    } catch (e) { setMsg({ kind: 'err', text: errOf(e).message }); }
  }

  async function runImpact(versionId?: string) {
    const id = versionId ?? (dirty || !draft ? await save() : draft.id);
    if (!id) return null;
    setTab('impact'); setImpacting(true); setImpact(null);
    try {
      const r = await http.post(`/sites/${siteId}/versions/${id}/replay`, { sample: 50 }, H);
      setImpact(r.data);
      return r.data;
    } catch (e) { setMsg({ kind: 'err', text: errOf(e).message }); return null; }
    finally { setImpacting(false); }
  }

  async function publish(confirm = false, reviewed = false) {
    const id = dirty || !draft ? await save() : draft.id;
    if (!id) return;
    let rep = impact;
    if (!confirm && !reviewed) {
      const g = await runGate(300, id);
      if (!g?.passed) { setMsg({ kind: 'err', text: 'The Release Gate blocked this draft, so nothing was published. See the Gate tab.' }); return; }
      rep = await runImpact(id);
      if (!rep) return;
      const strandedStates = (rep.impact ?? []).filter((i: any) => i.kind === 'state_removed' && i.count > 0);
      if (rep.divergent?.length || strandedStates.length) {
        setMsg({
          kind: 'warn',
          text: `Review before publishing: ${rep.divergent?.length ?? 0} of ${rep.sampled} past requests would go differently${strandedStates.length ? `, and ${strandedStates.length} removed state(s) still hold records (choose a plan in the Impact tab)` : ''}.`,
          action: { label: 'Reviewed - publish', run: () => publish(false, true) },
        });
        return;
      }
    }
    setBusy(true);
    try {
      const r = await http.post(`/sites/${siteId}/publish`, {
        versionId: id, confirm, plans,
        replay: rep ? { sampled: rep.sampled, identical: rep.identical, divergent: rep.divergent?.length ?? 0, reviewed } : undefined,
      }, H);
      setPlans({});
      markDone('published');
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
        <HelpButton title="Using the Builder"><BuilderHelp /></HelpButton>
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
          <button onClick={explainSite} className={ghost}>Explain</button>
          <button onClick={exportSite} className={ghost}>Export</button>
          <a href={`/${site.slug}`} target="_blank" rel="noreferrer" className={ghost}>Open live</a>
          <button onClick={() => runGate()} disabled={busy || gating || !!errors.length} className={ghost}>Run gate</button>
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
          <nav className="flex flex-wrap border-b text-xs">
            {([['problems', `Problems${errors.length ? ` (${errors.length})` : ''}`], ['module', 'Module'], ['workflow', 'Workflow'], ['laws', 'Laws'], ['gate', 'Gate'], ['impact', 'Impact'], ['theme', 'Theme'], ['json', 'JSON'], ['versions', 'Versions'], ['people', 'People']] as const).map(([k, label]) => (
              <button key={k} onClick={() => setTab(k)} title={TAB_HELP[k]} className={`flex-1 border-b-2 px-2 py-2 ${tab === k ? 'border-slate-900 font-medium' : 'border-transparent text-slate-500'}`}>{label}</button>
            ))}
          </nav>
          <div className="min-h-0 flex-1 overflow-y-auto p-4">
            {tab === 'problems' && <ProblemsPanel diags={diags} changes={changes} onFix={d => update(applyFix(bp, d.fix?.patch))} onSelect={id => { setSelected(id); setTab('module'); }} />}
            {tab === 'module' && <ModulePanel bp={bp} id={selected} update={update} onRemove={id => { update(removeModule(bp, id)); setSelected(null); }} />}
            {tab === 'workflow' && <WorkflowPanel bp={bp} update={update} />}
            {tab === 'impact' && <ImpactPanel report={impact} running={impacting} onRun={() => runImpact()} plans={plans} setPlans={setPlans} />}
            {tab === 'laws' && <LawsPanel bp={bp} update={update} />}
            {tab === 'gate' && <GatePanel gate={gate} gating={gating} onRun={steps => runGate(steps)} />}
            {tab === 'people' && <PeoplePanel siteId={siteId} H={H} />}
            {tab === 'theme' && <ThemePanel bp={bp} update={update} />}
            {tab === 'json' && <JsonPanel bp={bp} update={update} />}
            {tab === 'versions' && <ReleasesPanel siteId={siteId} H={H} refreshKey={versionsKey} onChanged={async m => { setMsg(m); setVersionsKey(k => k + 1); await load(); }} />}
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
            <RoleToggle bp={bp} entity={entity} field={x} update={update} />
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
      if (er.code === 'DESTRUCTIVE_CHANGE_UNPLANNED' || er.code === 'GATE_NOT_PASSED') onChanged({ kind: 'warn', text: er.message, action: { label: 'Roll back anyway', run: () => rollback(versionId, true) } });
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
          {d.proof?.gate && <div className="text-xs text-emerald-700">Release Gate: {d.proof.gate.passed ? 'passed' : 'overridden'}, {d.proof.gate.steps} steps, seed {d.proof.gate.seed}</div>}
          {!!d.proof?.changes?.length && <ul className="mt-1 font-mono text-[11px]">{d.proof.changes.map((c: string) => <li key={c}>{c}</li>)}</ul>}
          {d.version_id !== liveVersion && <button onClick={() => rollback(d.version_id)} className="mt-2 rounded-md border px-2 py-1 text-xs">Roll back to this version</button>}
        </div>
      ))}
    </div>
  );
}
