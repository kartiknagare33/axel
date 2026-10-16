const CLASS_STYLE: Record<string, string> = {
  additive: 'bg-emerald-100 text-emerald-800',
  behavioural: 'bg-amber-100 text-amber-800',
  destructive: 'bg-red-100 text-red-800',
};
const OUTCOME: Record<string, string> = {
  allowed: 'allowed', blocked_by_guard: 'blocked by rule', blocked_by_role: 'role not allowed',
  step_missing: 'step removed', insufficient_stock: 'not enough stock', no_reservation: 'nothing reserved', refused: 'refused', 'n/a': '-',
};

export function ImpactList({ items, plans, setPlans }: { items: any[]; plans: Record<string, string>; setPlans: (p: Record<string, string>) => void }) {
  if (!items?.length) return <div className="text-sm text-slate-400">No changes compared to live.</div>;
  return (
    <div className="space-y-1.5">
      {items.map((i, n) => {
        const key = `${i.entity}.${i.state}`;
        return (
          <div key={n} className="rounded border p-2 text-sm">
            <div className="flex items-start gap-2">
              <span className={`shrink-0 rounded px-1.5 text-[10px] uppercase ${CLASS_STYLE[i.class]}`}>{i.class}</span>
              <span>{i.detail}</span>
            </div>
            {i.kind === 'state_removed' && i.count > 0 && (
              <select value={plans[key] ?? ''} onChange={e => setPlans({ ...plans, [key]: e.target.value })} className="mt-1 w-full rounded border px-2 py-1 text-xs">
                <option value="">Choose a plan...</option>
                {i.options.map((o: string) => (
                  <option key={o} value={o}>{o === 'keep' ? 'Keep these records read-only' : `Move these records to '${o.slice(4)}'`}</option>
                ))}
              </select>
            )}
          </div>
        );
      })}
    </div>
  );
}

export function ImpactPanel({ report, running, onRun, plans, setPlans }: {
  report: any; running: boolean; onRun: () => void; plans: Record<string, string>; setPlans: (p: Record<string, string>) => void;
}) {
  return (
    <div className="space-y-4 text-sm">
      <div className="text-slate-600">
        Axel replays the last 50 real requests (same steps, same roles) through both the live version and this draft,
        and lists every difference. Publish runs this automatically after the gate.
      </div>
      <button onClick={onRun} disabled={running} className="rounded-md bg-slate-900 px-3 py-1.5 text-white disabled:opacity-40">
        {running ? 'Replaying...' : 'Run replay and impact'}
      </button>
      {running && <div className="h-2 w-full animate-pulse rounded bg-slate-300" />}
      {report && (
        <>
          <div className={`rounded-lg p-3 ${report.divergent.length ? 'bg-amber-50 text-amber-900' : 'bg-emerald-50 text-emerald-800'}`}>
            <div className="font-semibold">Replay: {report.identical} of {report.sampled} past requests go exactly the same way</div>
            {report.summary.map((s: string) => <div key={s} className="text-xs">{s}</div>)}
          </div>
          {!!report.divergent.length && (
            <table className="w-full text-xs">
              <thead className="text-left text-slate-500"><tr><th className="py-1">Request</th><th>Step</th><th>Today</th><th>With draft</th></tr></thead>
              <tbody>
                {report.divergent.slice(0, 25).map((d: any) => (
                  <tr key={d.recordId} className="border-t" title={d.detail}>
                    <td className="py-1">{d.label}</td><td className="font-mono">{d.transition}</td>
                    <td>{OUTCOME[d.live] ?? d.live}</td><td className="text-red-700">{OUTCOME[d.draft] ?? d.draft}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          <div>
            <div className="mb-1 text-xs font-medium uppercase text-slate-400">Impact on data and behaviour</div>
            <ImpactList items={report.impact} plans={plans} setPlans={setPlans} />
          </div>
        </>
      )}
    </div>
  );
}
