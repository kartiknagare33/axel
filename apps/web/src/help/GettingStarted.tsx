import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Check, Rocket } from 'lucide-react';
import type { SiteSummary } from '../hooks';
import { useProgress, resetProgress, type Step } from './progress';

const HIDDEN = 'axel-onboarding-hidden';

export function GettingStarted({ sites, isAdmin }: { sites: SiteSummary[]; isAdmin: boolean }) {
  const done = useProgress();
  const [hidden, setHidden] = useState(() => localStorage.getItem(HIDDEN) === '1');
  const first = sites[0];
  const withReq = sites.find(s => s.modules.includes('request')) ?? first;
  const adminSite = sites.find(s => s.role === 'Admin');
  const items: { key: Step; title: string; how: string; to?: string }[] = [
    { key: 'openedUnit', title: 'Open a unit', how: 'Each unit is its own system with its own pages and look.', to: first && `/${first.slug}` },
    { key: 'movedRequest', title: 'Move a request to its next step', how: `In ${withReq?.name ?? 'a unit'}, drag a card to the next column, or open a request and press a Next step button.`, to: withReq && `/${withReq.slug}` },
    { key: 'usedExcel', title: 'Export a list to Excel', how: 'On any list, press Excel > Export. Columns your role cannot see are left out.', to: first && `/${first.slug}` },
    { key: 'triedHelp', title: 'Open Help on any page', how: 'The Help button at the top right explains the page for your role.' },
    ...(isAdmin && adminSite ? [
      { key: 'openedBuilder' as Step, title: 'Open the Builder', how: 'Change how a unit works by dragging building blocks. Nothing goes live until you publish.', to: `/builder/${adminSite.id}` },
      { key: 'ranGate' as Step, title: 'Run the Release Gate', how: 'In the Builder, press Run gate. It safety-checks a change on real data before it goes live.', to: `/builder/${adminSite.id}` },
      { key: 'published' as Step, title: 'Publish a change', how: 'Add a field or a building block, then Publish. Open screens update by themselves.', to: `/builder/${adminSite.id}` },
    ] : []),
  ];
  const n = items.filter(i => done[i.key]).length;

  if (hidden) {
    return (
      <button onClick={() => { localStorage.removeItem(HIDDEN); setHidden(false); }} className="text-sm text-slate-500 underline-offset-4 hover:text-slate-900 hover:underline">
        Show the getting-started guide
      </button>
    );
  }

  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="flex items-start gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-indigo-50 text-indigo-600 ring-1 ring-inset ring-indigo-200"><Rocket className="h-5 w-5" /></span>
          <div>
            <div className="font-semibold text-slate-900">Getting started</div>
            <div className="text-sm text-slate-500">{n === items.length ? 'All done. You have tried every main feature.' : `${n} of ${items.length} done. Each step ticks itself when you do it.`}</div>
          </div>
        </div>
        <div className="flex gap-3 text-sm">
          <button onClick={resetProgress} className="text-slate-400 hover:text-slate-700">Start over</button>
          <button onClick={() => { localStorage.setItem(HIDDEN, '1'); setHidden(true); }} className="text-slate-500 hover:text-slate-900">Hide</button>
        </div>
      </div>
      <div className="mt-4 h-1.5 overflow-hidden rounded-full bg-slate-100">
        <div className="h-full rounded-full bg-indigo-500 transition-all" style={{ width: `${(n / items.length) * 100}%` }} />
      </div>
      <ol className="mt-5 grid gap-3 md:grid-cols-2">
        {items.map((it, i) => {
          const ok = !!done[it.key];
          return (
            <li key={it.key} className={`flex gap-3 rounded-xl p-3 ring-1 ring-inset ${ok ? 'bg-emerald-50/50 ring-emerald-100' : 'bg-slate-50 ring-slate-200'}`}>
              <span className={`mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold ${ok ? 'bg-emerald-500 text-white' : 'bg-white text-slate-500 ring-1 ring-inset ring-slate-300'}`}>
                {ok ? <Check className="h-3.5 w-3.5" /> : i + 1}
              </span>
              <div className="min-w-0 flex-1">
                <div className={`text-sm font-medium ${ok ? 'text-slate-500 line-through' : 'text-slate-900'}`}>{it.title}</div>
                <div className="mt-0.5 text-xs text-slate-500">{it.how}</div>
              </div>
              {!ok && it.to && <Link to={it.to} className="self-center rounded-lg bg-white px-2.5 py-1 text-xs font-medium text-slate-700 shadow-sm ring-1 ring-inset ring-slate-200 hover:bg-slate-50">Go</Link>}
            </li>
          );
        })}
      </ol>
    </div>
  );
}
