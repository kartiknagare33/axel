import { useState } from 'react';

export function GatePanel({ gate, gating, onRun }: { gate: any; gating: boolean; onRun: (steps: number) => void }) {
  const [steps, setSteps] = useState(300);
  return (
    <div className="space-y-4 text-sm">
      <div className="text-slate-600">
        The Release Gate proves a draft before it goes live. It compiles the draft, checks every Law, then acts out
        hundreds of random actions as Members, Managers and Admins on this site's real data, inside a transaction
        that is always rolled back, checking every Law after each step. Publish runs it automatically.
      </div>
      <div className="flex items-center gap-2">
        <select value={steps} onChange={e => setSteps(Number(e.target.value))} className="rounded border px-2 py-1.5">
          {[150, 300, 1000, 2000].map(n => <option key={n} value={n}>{n} steps</option>)}
        </select>
        <button onClick={() => onRun(steps)} disabled={gating} className="rounded-md bg-slate-900 px-3 py-1.5 text-white disabled:opacity-40">
          {gating ? 'Running...' : 'Run gate'}
        </button>
      </div>
      {gating && <div className="h-2 w-full animate-pulse rounded bg-slate-300" />}
      {!gate && !gating && <div className="text-slate-400">No run yet for this draft.</div>}
      {gate && (
        <>
          <div className={`rounded-lg p-3 ${gate.passed ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-800'}`}>
            <div className="text-lg font-bold">{gate.passed ? 'PASSED' : 'BLOCKED'}</div>
            <div className="text-xs">
              {gate.steps} steps in {gate.durationMs} ms, seed {gate.seed}
              {gate.stats ? ` - ${gate.stats.allowed} allowed, ${gate.stats.refused} refused, ${gate.stats.skipped} idle` : ''}
            </div>
          </div>

          {!!gate.compileErrors?.length && (
            <div className="rounded-lg border border-red-200 bg-red-50 p-3">
              <div className="font-medium">Compile</div>
              {gate.compileErrors.map((m: string) => <div key={m} className="text-xs">{m}</div>)}
            </div>
          )}

          <div>
            <div className="mb-1 text-xs font-medium uppercase text-slate-400">Laws</div>
            {gate.laws.map((l: any) => (
              <div key={l.id} className="flex gap-2 border-b py-1.5 last:border-0">
                <span className={`w-10 shrink-0 text-xs font-bold ${l.passed ? 'text-emerald-600' : 'text-red-600'}`}>{l.passed ? 'PASS' : 'FAIL'}</span>
                <div>
                  <div>{l.sentence}</div>
                  {l.detail && <div className="text-xs text-slate-500">{l.detail}</div>}
                  <div className="text-[10px] uppercase text-slate-400">{l.dynamic ? 'checked after every step' : 'checked on the Blueprint'}</div>
                </div>
              </div>
            ))}
          </div>

          {gate.counterExample && (
            <div className="rounded-lg border border-red-200 bg-red-50 p-3">
              <div className="font-medium text-red-800">Counter-example</div>
              <div className="text-red-800">{gate.counterExample.message}</div>
              <ol className="mt-2 space-y-0.5 font-mono text-xs">
                {gate.counterExample.trace.map((s: any) => <li key={s.i}>#{s.i} {s.text} - {s.outcome}</li>)}
              </ol>
              <div className="mt-2 text-xs text-slate-600">Run again with seed {gate.seed} to replay the same walk.</div>
            </div>
          )}

          {!!gate.sample?.length && (
            <details>
              <summary className="cursor-pointer text-xs text-slate-500">First {gate.sample.length} steps of the walk</summary>
              <ol className="mt-1 space-y-0.5 font-mono text-xs">
                {gate.sample.map((s: any) => <li key={s.i}>#{s.i} {s.text} - {s.outcome}</li>)}
              </ol>
            </details>
          )}
        </>
      )}
    </div>
  );
}
