import { useState } from 'react';
import { useMutation } from '@tanstack/react-query';
import { http, errOf } from '../api';

export function ChaosCard() {
  const [res, setRes] = useState<any>(null);
  const [err, setErr] = useState('');
  const m = useMutation({
    mutationFn: () => http.post('/hub/chaos', { concurrency: 50, stock: 10 }).then(r => r.data),
    onSuccess: d => { setErr(''); setRes(d); },
    onError: e => setErr(errOf(e).message),
  });
  return (
    <div className="rounded-xl border bg-white p-5">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-xs font-medium uppercase text-slate-400">Chaos test</div>
          <div className="text-sm text-slate-600">Fire 50 concurrent approvals at an item with 10 in stock. Exactly 10 may succeed.</div>
        </div>
        <button onClick={() => m.mutate()} disabled={m.isPending} className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">
          {m.isPending ? 'Running...' : 'Run chaos'}
        </button>
      </div>
      {err && <div className="mt-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
      {res && (
        <div className="mt-4 grid gap-3 sm:grid-cols-4">
          <div className={`rounded-lg p-3 text-center ${res.passed ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-800'}`}>
            <div className="text-2xl font-bold">{res.passed ? 'PASS' : 'FAIL'}</div>
            <div className="text-xs">{res.site} - {res.durationMs} ms</div>
          </div>
          <div className="rounded-lg bg-slate-50 p-3 text-sm">
            <div className="text-xs text-slate-400">Outcomes</div>
            {Object.entries(res.outcomes).map(([k, v]) => <div key={k}>{k}: <b>{String(v)}</b></div>)}
          </div>
          <div className="rounded-lg bg-slate-50 p-3 text-sm">
            <div className="text-xs text-slate-400">Item after</div>
            <div>on hand: <b>{res.item.on_hand}</b></div>
            <div>reserved: <b>{res.item.reserved}</b></div>
          </div>
          <div className="rounded-lg bg-slate-50 p-3 text-sm">
            <div className="text-xs text-slate-400">Ledger recomputed</div>
            <div>on hand: <b>{res.ledger.on_hand}</b></div>
            <div>reserved: <b>{res.ledger.reserved}</b></div>
            <div>reserve rows: <b>{res.reserveMovements}</b></div>
          </div>
        </div>
      )}
    </div>
  );
}
