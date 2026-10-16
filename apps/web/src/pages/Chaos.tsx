import { useState } from 'react';
import { useMutation } from '@tanstack/react-query';
import { Zap } from 'lucide-react';
import { http, errOf } from '../api';

export function ChaosCard() {
  const [res, setRes] = useState<any>(null);
  const [err, setErr] = useState('');
  const m = useMutation({
    mutationFn: () => http.post('/hub/chaos', { concurrency: 50, stock: 10 }).then(r => r.data),
    onSuccess: d => { setErr(''); setRes(d); },
    onError: e => setErr(errOf(e).message),
  });
  const box = 'rounded-xl bg-slate-50 p-4 text-sm ring-1 ring-inset ring-slate-200';
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div className="flex items-start gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-amber-50 text-amber-600 ring-1 ring-inset ring-amber-200"><Zap className="h-5 w-5" /></span>
          <div>
            <div className="font-semibold text-slate-900">Chaos test</div>
            <div className="text-sm text-slate-500">Fire 50 concurrent approvals at an item with 10 in stock. Exactly 10 may succeed.</div>
          </div>
        </div>
        <button onClick={() => m.mutate()} disabled={m.isPending} className="inline-flex items-center gap-1.5 rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white shadow-sm transition hover:bg-slate-800 disabled:opacity-50">
          <Zap className="h-4 w-4" />{m.isPending ? 'Running...' : 'Run chaos'}
        </button>
      </div>
      {err && <div className="mt-4 rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700">{err}</div>}
      {res && (
        <div className="mt-5 grid gap-3 sm:grid-cols-4">
          <div className={`rounded-xl p-4 text-center ring-1 ring-inset ${res.passed ? 'bg-emerald-50 text-emerald-800 ring-emerald-200' : 'bg-rose-50 text-rose-800 ring-rose-200'}`}>
            <div className="text-2xl font-bold tracking-tight">{res.passed ? 'PASS' : 'FAIL'}</div>
            <div className="mt-0.5 text-xs">{res.site} - {res.durationMs} ms</div>
          </div>
          <div className={box}>
            <div className="mb-1 text-xs font-medium uppercase tracking-wide text-slate-400">Outcomes</div>
            {Object.entries(res.outcomes).map(([k, v]) => <div key={k} className="flex justify-between"><span className="text-slate-600">{k}</span><b className="tabular">{String(v)}</b></div>)}
          </div>
          <div className={box}>
            <div className="mb-1 text-xs font-medium uppercase tracking-wide text-slate-400">Item after</div>
            <div className="flex justify-between"><span className="text-slate-600">On hand</span><b className="tabular">{res.item.on_hand}</b></div>
            <div className="flex justify-between"><span className="text-slate-600">Reserved</span><b className="tabular">{res.item.reserved}</b></div>
          </div>
          <div className={box}>
            <div className="mb-1 text-xs font-medium uppercase tracking-wide text-slate-400">Ledger recomputed</div>
            <div className="flex justify-between"><span className="text-slate-600">On hand</span><b className="tabular">{res.ledger.on_hand}</b></div>
            <div className="flex justify-between"><span className="text-slate-600">Reserved</span><b className="tabular">{res.ledger.reserved}</b></div>
            <div className="flex justify-between"><span className="text-slate-600">Reserve rows</span><b className="tabular">{res.reserveMovements}</b></div>
          </div>
        </div>
      )}
    </div>
  );
}
