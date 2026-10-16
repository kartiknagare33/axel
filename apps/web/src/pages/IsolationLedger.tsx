import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { http, errOf } from '../api';

const Tick = ({ ok }: { ok: boolean }) => <span className={ok ? 'font-bold text-emerald-600' : 'font-bold text-red-600'}>{ok ? 'yes' : 'NO'}</span>;

export default function IsolationLedger() {
  const [data, setData] = useState<any>(null);
  const [check, setCheck] = useState<any>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  useEffect(() => { http.get('/hub/isolation-ledger').then(r => setData(r.data), e => setErr(errOf(e).message)); }, []);
  async function run() {
    setBusy(true); setCheck(null);
    try { setCheck((await http.post('/hub/isolation-ledger/check')).data); } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  return (
    <div className="min-h-screen bg-slate-50">
      <header className="flex items-center justify-between border-b bg-white px-6 py-3">
        <div className="text-lg font-bold">Axel <span className="font-normal text-slate-400">Isolation Ledger</span></div>
        <Link to="/" className="text-sm text-slate-500 hover:text-slate-900">Back to hub</Link>
      </header>
      <main className="mx-auto max-w-5xl space-y-6 p-6">
        <p className="text-sm text-slate-600">Every claim on this page is read live from PostgreSQL's own catalog, not from Axel's configuration.</p>
        {err && <div className="rounded-lg bg-red-50 p-3 text-sm text-red-700">{err}</div>}
        {data && (
          <>
            <div className="grid gap-3 sm:grid-cols-4">
              <div className="rounded-xl border bg-white p-4"><div className="text-xs uppercase text-slate-400">API database role</div><div className="font-mono text-lg">{data.role.name}</div></div>
              <div className="rounded-xl border bg-white p-4"><div className="text-xs uppercase text-slate-400">Can bypass RLS</div><div className="text-lg"><Tick ok={!data.role.bypass} /> <span className="text-sm text-slate-500">({data.role.bypass ? 'yes' : 'no'})</span></div></div>
              <div className="rounded-xl border bg-white p-4"><div className="text-xs uppercase text-slate-400">Superuser</div><div className="text-lg"><Tick ok={!data.role.superuser} /> <span className="text-sm text-slate-500">({data.role.superuser ? 'yes' : 'no'})</span></div></div>
              <div className="rounded-xl border bg-white p-4"><div className="text-xs uppercase text-slate-400">Tables it owns</div><div className="text-lg font-bold">{data.role.ownsTables}</div></div>
            </div>
            <div className="overflow-x-auto rounded-xl border bg-white">
              <table className="w-full text-left text-sm">
                <thead className="bg-slate-50 text-slate-500"><tr><th className="px-3 py-2">Table</th><th>RLS enabled</th><th>RLS forced</th><th>Policies</th><th>Composite keys</th><th>Owner</th></tr></thead>
                <tbody>
                  {data.tables.map((t: any) => (
                    <tr key={t.table} className="border-t">
                      <td className="px-3 py-1.5 font-mono">{t.table}</td><td><Tick ok={t.rls} /></td><td><Tick ok={t.forced} /></td>
                      <td>{t.policies}</td><td>{t.composite_fks}</td><td className="font-mono text-xs">{t.owner}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="rounded-xl border bg-white p-4">
                <div className="mb-2 text-xs uppercase text-slate-400">Unique values are scoped per unit</div>
                {data.uniques.map((u: any) => <div key={u.indexname} className="font-mono text-xs">{u.tablename}: {u.indexname}</div>)}
              </div>
              <div className="rounded-xl border bg-white p-4">
                <div className="mb-2 text-xs uppercase text-slate-400">Last Release Gate per unit</div>
                {data.sites.map((s: any) => (
                  <div key={s.id} className="flex justify-between text-sm">
                    <span>{s.name}</span>
                    <span className={s.lastGate ? (s.lastGate.passed ? 'text-emerald-700' : 'text-red-700') : 'text-slate-400'}>
                      {s.lastGate ? `${s.lastGate.passed ? 'passed' : 'blocked'}, ${s.lastGate.steps} steps` : 'not run yet'}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </>
        )}
        <div className="space-y-3 rounded-xl border bg-white p-5">
          <div className="flex items-center justify-between">
            <div>
              <div className="font-medium">Live isolation check</div>
              <div className="text-sm text-slate-500">Reads every unit as every other unit, tries a cross-unit write and a cross-unit reference, and fires 30 parallel pooled requests.</div>
            </div>
            <button onClick={run} disabled={busy} className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">{busy ? 'Checking...' : 'Run live isolation check'}</button>
          </div>
          {check && (
            <>
              <div className={`rounded-lg p-3 text-center text-xl font-bold ${check.passed ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-800'}`}>{check.passed ? 'ALL ISOLATED' : 'LEAK FOUND'}</div>
              <div className="space-y-1">
                {check.checks.map((c: any) => (
                  <div key={c.name} className="flex gap-3 text-sm">
                    <span className={`w-10 shrink-0 font-bold ${c.passed ? 'text-emerald-600' : 'text-red-600'}`}>{c.passed ? 'PASS' : 'FAIL'}</span>
                    <span className="w-72 shrink-0">{c.name}</span>
                    <span className="text-slate-500">{c.detail}</span>
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      </main>
    </div>
  );
}
