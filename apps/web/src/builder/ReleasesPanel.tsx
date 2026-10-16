import { useEffect, useState } from 'react';
import { http, errOf } from '../api';
import { ImpactList } from './ImpactPanel';

type Msg = { kind: 'ok' | 'err' | 'warn'; text: string; action?: { label: string; run: () => void } } | null;

export function ReleasesPanel({ siteId, H, refreshKey, onChanged }: { siteId: string; H: any; refreshKey: number; onChanged: (m: Msg) => void }) {
  const [deps, setDeps] = useState<any[] | null>(null);
  const [err, setErr] = useState('');
  const [target, setTarget] = useState<{ versionId: string; impact: any[]; plans: Record<string, string> } | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    http.get(`/sites/${siteId}/deployments`, H).then(r => setDeps(r.data), e => setErr(errOf(e).message));
  }, [siteId, H, refreshKey]);

  async function prepare(versionId: string) {
    setBusy(true);
    try {
      const r = await http.get(`/sites/${siteId}/versions/${versionId}/impact`, H);
      setTarget({ versionId, impact: r.data.impact, plans: {} });
    } catch (e) { onChanged({ kind: 'err', text: errOf(e).message }); }
    finally { setBusy(false); }
  }

  async function rollback(confirm = false) {
    if (!target) return;
    setBusy(true);
    try {
      const r = await http.post(`/sites/${siteId}/rollback`, { versionId: target.versionId, plans: target.plans, confirm }, H);
      setTarget(null);
      onChanged({ kind: 'ok', text: `Rolled back. ${[...(r.data.destructive ?? []), ...(r.data.changes ?? [])].join(' ')} No data was deleted.` });
    } catch (e) {
      const er = errOf(e);
      if (er.code === 'GATE_NOT_PASSED' || er.code === 'DESTRUCTIVE_CHANGE_UNPLANNED')
        onChanged({ kind: 'warn', text: er.message, action: { label: 'Roll back anyway (keep records)', run: () => rollback(true) } });
      else onChanged({ kind: 'err', text: er.message });
    } finally { setBusy(false); }
  }

  if (err) return <div className="text-sm text-red-700">{err}</div>;
  if (!deps) return <div className="text-sm text-slate-500">Loading...</div>;
  const liveVersion = deps[0]?.version_id;
  const needsPlan = (target?.impact ?? []).filter(i => i.kind === 'state_removed' && i.count > 0);
  const planned = needsPlan.every(i => target?.plans[`${i.entity}.${i.state}`]);

  return (
    <div className="space-y-3">
      <div className="text-xs text-slate-500">Every publish and rollback, newest first. Rolling back shows its impact first and never deletes data.</div>
      {deps.map((d, i) => (
        <div key={d.id} className={`rounded-lg border p-3 text-sm ${i === 0 ? 'border-emerald-300 bg-emerald-50' : ''}`}>
          <div className="flex items-center justify-between">
            <span className="font-medium">
              {d.proof?.kind === 'rollback' || d.rollback_of ? 'Rollback' : d.proof?.seeded ? 'Seeded' : 'Publish'}
              {i === 0 && <span className="ml-2 rounded bg-emerald-600 px-1.5 text-xs text-white">LIVE</span>}
            </span>
            <span className="text-xs text-slate-500">{new Date(d.deployed_at).toLocaleString()}</span>
          </div>
          <div className="text-xs text-slate-500">by {d.deployed_by_name ?? 'system'} - version {String(d.version_id).slice(0, 8)}</div>
          {d.proof?.gate && <div className="text-xs text-emerald-700">Release Gate {d.proof.gate.passed ? 'passed' : 'overridden'}: {d.proof.gate.steps} steps, seed {d.proof.gate.seed}</div>}
          {d.proof?.replay && <div className="text-xs text-sky-700">Replay: {d.proof.replay.identical} of {d.proof.replay.sampled} past requests unchanged{d.proof.replay.reviewed ? ', reviewed' : ''}</div>}
          {d.proof?.plans && Object.keys(d.proof.plans).length > 0 && <div className="text-xs text-amber-700">Plans: {Object.entries(d.proof.plans).map(([k, v]) => `${k} ${v}`).join(', ')}</div>}
          {!!d.proof?.changes?.length && <ul className="mt-1 font-mono text-[11px]">{d.proof.changes.map((c: string) => <li key={c}>{c}</li>)}</ul>}
          {!!d.proof?.destructive?.length && <ul className="mt-1 text-[11px] text-amber-800">{d.proof.destructive.map((c: string) => <li key={c}>{c}</li>)}</ul>}

          {d.version_id !== liveVersion && target?.versionId !== d.version_id && (
            <button disabled={busy} onClick={() => prepare(d.version_id)} className="mt-2 rounded-md border px-2 py-1 text-xs">Roll back to this version</button>
          )}
          {target?.versionId === d.version_id && (
            <div className="mt-2 space-y-2 rounded border bg-white p-2">
              <div className="text-xs font-medium uppercase text-slate-400">What this rollback changes</div>
              <ImpactList items={target.impact} plans={target.plans} setPlans={p => setTarget({ ...target, plans: p })} />
              <div className="flex gap-2">
                <button disabled={busy || !planned} onClick={() => rollback()} className="rounded-md bg-slate-900 px-3 py-1 text-xs text-white disabled:opacity-40">
                  {busy ? 'Rolling back...' : 'Roll back now'}
                </button>
                <button onClick={() => setTarget(null)} className="rounded-md border px-3 py-1 text-xs">Cancel</button>
              </div>
              {!planned && <div className="text-xs text-amber-700">Choose a plan for each removed state first.</div>}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
