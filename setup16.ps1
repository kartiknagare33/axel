# Axel - Batch A: help panels, getting-started checklist, glossary, smarter empty states. Run from the axel folder.
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

# ============================== new help files ==============================
W 'apps/web/src/help/progress.ts' @'
import { useEffect, useState } from 'react';

// First-steps progress, kept in this browser. Steps tick themselves as the user does them.
const KEY = 'axel-onboarding';
export type Step = 'openedUnit' | 'movedRequest' | 'usedExcel' | 'triedHelp' | 'openedBuilder' | 'ranGate' | 'published';

const read = (): Record<string, boolean> => {
  try { return JSON.parse(localStorage.getItem(KEY) ?? '{}'); } catch { return {}; }
};

export function markDone(step: Step) {
  const s = read();
  if (s[step]) return;
  s[step] = true;
  localStorage.setItem(KEY, JSON.stringify(s));
  window.dispatchEvent(new Event('axel-progress'));
}

export function resetProgress() {
  localStorage.removeItem(KEY);
  localStorage.removeItem(`${KEY}-hidden`);
  window.dispatchEvent(new Event('axel-progress'));
}

export function useProgress() {
  const [s, setS] = useState(read);
  useEffect(() => {
    const f = () => setS(read());
    window.addEventListener('axel-progress', f);
    window.addEventListener('storage', f);
    return () => { window.removeEventListener('axel-progress', f); window.removeEventListener('storage', f); };
  }, []);
  return s;
}
'@

W 'apps/web/src/help/glossary.ts' @'
export const GLOSSARY: [string, string][] = [
  ['Unit', 'One part of the business with its own system, for example Central Stores.'],
  ['Blueprint', 'The saved design of a unit: its fields, steps, pages, rules and look. Publishing makes a Blueprint live.'],
  ['Module', 'A building block, such as Request or Approval. Only the 13 approved modules exist.'],
  ['Port', 'A connection point on a module. Ports only fit matching ports, so an impossible system cannot be wired.'],
  ['Workflow step', 'A move from one stage to the next, for example Submitted to Approved, and who may do it.'],
  ['Rule', 'A condition a step must meet, for example "qty <= 50".'],
  ['Law', 'A rule the unit must never break, written as a sentence. Checked before every publish.'],
  ['Release Gate', 'The automatic safety check before publishing. It acts out hundreds of random actions on real data, then undoes them.'],
  ['Replay', 'Re-runs recent real requests through your change to show who would be affected.'],
  ['Impact', 'What your change does to existing data, and what to do with records that no longer fit.'],
  ['Draft and Publish', 'A draft is saved but not live. Publish makes it live for everyone, with no restart.'],
  ['Rollback', 'Go back to an earlier version. Data is never deleted.'],
];

export const TAB_HELP: Record<string, string> = {
  problems: 'Mistakes in your design, in plain English, often with a one-click Fix',
  module: 'Details and fields of the selected building block',
  workflow: 'The steps records go through, who may take each step, and rules',
  laws: 'Rules this unit must never break',
  gate: 'Run the automatic safety check before publishing',
  impact: 'See who is affected by your change, using real past requests',
  theme: 'Layout and colours',
  json: 'The raw saved design, for technical users',
  versions: 'Every past release, and roll back',
  people: 'Who can use this unit, and their roles',
};
'@

W 'apps/web/src/help/HelpPanel.tsx' @'
import { useEffect, useState, type ReactNode } from 'react';
import { HelpCircle, X } from 'lucide-react';
import { markDone } from './progress';

export function HelpButton({ title, children, dark }: { title: string; children: ReactNode; dark?: boolean }) {
  const [open, setOpen] = useState(false);
  useEffect(() => { if (open) markDone('triedHelp'); }, [open]);
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false); };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, []);
  return (
    <>
      <button onClick={() => setOpen(true)} title="What can I do here?"
        className={`inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-sm font-medium transition ${dark ? 'text-white/80 hover:bg-white/10 hover:text-white' : 'text-slate-500 hover:bg-slate-100 hover:text-slate-900'}`}>
        <HelpCircle className="h-4 w-4" />Help
      </button>
      {open && (
        <div className="fixed inset-0 z-[60] flex justify-end">
          <div className="absolute inset-0 bg-slate-900/30" onClick={() => setOpen(false)} />
          <aside className="relative flex h-full w-full max-w-md flex-col bg-white text-left shadow-2xl">
            <div className="flex items-center justify-between border-b border-slate-200 px-6 py-4">
              <div>
                <div className="text-xs font-semibold uppercase tracking-wider text-slate-400">Help</div>
                <div className="text-lg font-semibold text-slate-900">{title}</div>
              </div>
              <button onClick={() => setOpen(false)} className="rounded-lg p-2 text-slate-400 transition hover:bg-slate-100 hover:text-slate-700"><X className="h-5 w-5" /></button>
            </div>
            <div className="flex-1 space-y-6 overflow-y-auto px-6 py-5 text-sm leading-relaxed text-slate-600">{children}</div>
            <div className="border-t border-slate-200 px-6 py-3 text-xs text-slate-400">Press Esc to close.</div>
          </aside>
        </div>
      )}
    </>
  );
}

export function HelpSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section>
      <h3 className="mb-2 text-sm font-semibold text-slate-900">{title}</h3>
      <div className="space-y-2">{children}</div>
    </section>
  );
}

export function HelpList({ items }: { items: ReactNode[] }) {
  return (
    <ul className="space-y-1.5">
      {items.map((x, i) => (
        <li key={i} className="flex gap-2"><span className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-slate-300" /><span>{x}</span></li>
      ))}
    </ul>
  );
}
'@

W 'apps/web/src/help/content.tsx' @'
import { useLocation } from 'react-router-dom';
import { useSite, RANK } from '../hooks';
import { HelpSection, HelpList } from './HelpPanel';
import { GLOSSARY } from './glossary';

const ROLE_TEXT: Record<string, string> = {
  Public: 'You can view public pages only.',
  Member: 'You can create requests and follow them through their steps. Some figures, such as prices, are hidden for your role.',
  Manager: 'You can approve, assign, manage stock and import spreadsheets.',
  Admin: 'You can do everything here, including changing how this unit works in the Builder.',
};

const VIEW_TEXT: Record<string, string> = {
  kanban: 'A board with one column per step. Each card is one record. Drag a card to another column to move it to that step; if the move is not allowed, Axel tells you why. Click a card to open it.',
  table: 'A list of records. Click a row to open it. Use Search to filter. The Excel bar exports the list (columns you cannot see are left out); Managers can also import.',
  queue: 'Work waiting to be done. Open an item to see it in full and take the next step.',
  dashboard: 'Live charts for this unit. If a figure is hidden for your role, you see a short explanation instead.',
};

export function SiteHelp() {
  const { schema, base, name } = useSite();
  const { pathname } = useLocation();
  const rel = pathname.startsWith(base) ? pathname.slice(base.length) || '/' : pathname;
  const role = schema.role;
  const page = schema.pages.find(p => p.path === rel);
  const isRecord = rel.startsWith('/r/');
  const isTimeline = rel.startsWith('/timeline');
  const entityKey = page?.entity ?? (isRecord ? rel.split('/')[2] : undefined);
  const ent = entityKey ? schema.entities[entityKey] : undefined;
  const wf = ent?.workflow;
  const canCreate = RANK[role] >= 1 && !!ent?.fields.some(f => !f.readonly);

  const pageTitle = page?.title ?? (isRecord ? `One ${ent?.label ?? 'record'}` : isTimeline ? 'Board history' : 'This page');
  const pageText = page ? VIEW_TEXT[page.view] ?? 'A page of this unit.'
    : isRecord ? 'One record in full: the progress bar shows its current step; below are the buttons for the next steps you are allowed to take, then its details. On the right is its full history, including stock movements.'
    : isTimeline ? 'Type a serial number to see the whole life of one board: every request, repair and stock movement.'
    : 'A page of this unit.';

  const mine = wf?.transitions.filter(t => t.allowed) ?? [];
  const can: string[] = [];
  if (canCreate && ent && (page?.view === 'table' || page?.view === 'kanban')) can.push(`Create a new ${ent.label} with the New button.`);
  for (const t of mine) can.push(`${t.label}: move from ${t.from.replace(/_/g, ' ')} to ${t.to.replace(/_/g, ' ')}.`);
  if (RANK[role] >= 2 && entityKey === 'item') can.push('Receive or adjust stock on an item page. Every change is a ledger entry.');
  if (RANK[role] >= 2) can.push('Import spreadsheets with Excel > Import (checked row by row first).');

  return (
    <>
      <HelpSection title={`You are in ${name}`}>
        <p>You are signed in as <b className="text-slate-900">{role}</b>. {ROLE_TEXT[role]}</p>
      </HelpSection>
      <HelpSection title={pageTitle}>
        <p>{pageText}</p>
      </HelpSection>
      {wf && (
        <HelpSection title="The stages a record goes through">
          <div className="flex flex-wrap items-center gap-1.5">
            {wf.states.map(s => <span key={s} className="rounded-md bg-slate-100 px-1.5 py-0.5 text-xs capitalize text-slate-700">{s.replace(/_/g, ' ')}</span>)}
          </div>
          <HelpList items={wf.transitions.map(t => (
            <span><b className="text-slate-800">{t.label}</b> ({t.from.replace(/_/g, ' ')} to {t.to.replace(/_/g, ' ')}) {t.allowed ? <span className="text-emerald-600">- you can</span> : <span className="text-slate-400">- not your role</span>}</span>
          ))} />
        </HelpSection>
      )}
      {!!can.length && <HelpSection title="What you can do here"><HelpList items={can} /></HelpSection>}
      <HelpSection title="Tips">
        <HelpList items={[
          'Press Ctrl+K to switch to another unit.',
          'If a button is greyed out, the reason is written just under it.',
          'Stock can never go wrong: every change is an entry you can see on the item timeline.',
          ...(role === 'Admin' ? ['Change fields, steps and rules for this unit in the Builder (top right).'] : []),
        ]} />
      </HelpSection>
    </>
  );
}

export function HubHelp() {
  return (
    <>
      <HelpSection title="What is this page?">
        <p>The hub lists every unit you belong to. Each unit is a separate system, such as a stock room, a repair desk or a field team, with its own pages, steps and look. They all run on the same software.</p>
      </HelpSection>
      <HelpSection title="How to start">
        <HelpList items={[
          'Press Open on a unit card to use that unit.',
          'Admins can press Builder to change how a unit works, with no programming.',
          'Use the Getting started list below your units to try the main features one by one.',
          'Inside any unit, the Help button explains that page for your role.',
        ]} />
      </HelpSection>
      <HelpSection title="For hub admins">
        <HelpList items={[
          'New unit starts a unit from a ready-made template.',
          'From a spreadsheet builds a unit from an Excel register you already keep, and explains every guess.',
          'Isolation Ledger proves, live, that units can never see each other\u2019s data.',
          'Chaos test fires 50 approvals at once against 10 items in stock: exactly 10 succeed.',
        ]} />
      </HelpSection>
    </>
  );
}

export function BuilderHelp() {
  return (
    <>
      <HelpSection title="What is the Builder?">
        <p>The Builder is where you change how a unit works, without programming. You assemble it from approved building blocks, check it, then publish. Nothing changes for users until you publish.</p>
      </HelpSection>
      <HelpSection title="Changing a unit in six steps">
        <HelpList items={[
          '1. Drag a building block from the left onto the canvas. It connects itself.',
          '2. Check the Problems tab. Most problems have a one-click Fix.',
          '3. Adjust fields (Module tab), steps and rules (Workflow tab), Laws, and the look (Theme tab).',
          '4. Press Preview to see the unit with your changes, using real data, without saving anything.',
          '5. Press Publish. Axel runs the Release Gate and the Replay first, then makes it live with no restart.',
          '6. Changed your mind? The Versions tab rolls back to any earlier release. Data is never deleted.',
        ]} />
      </HelpSection>
      <HelpSection title="What the words mean">
        <dl className="space-y-2.5">
          {GLOSSARY.map(([term, meaning]) => (
            <div key={term}><dt className="font-medium text-slate-900">{term}</dt><dd>{meaning}</dd></div>
          ))}
        </dl>
      </HelpSection>
    </>
  );
}
'@

W 'apps/web/src/help/GettingStarted.tsx' @'
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
'@

# ============================== patches: empty states ==============================
Patch 'apps/web/src/renderer/fields.tsx' @'
export function EmptyState({ title, hint }: { title: string; hint?: string }) {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-14 text-center">
      <div className="flex h-12 w-12 items-center justify-center rounded-full bg-slate-100 text-slate-400"><Inbox className="h-6 w-6" /></div>
      <div className="mt-3 text-sm font-medium text-slate-700">{title}</div>
      {hint && <div className="mt-1 max-w-sm text-sm text-slate-500">{hint}</div>}
    </div>
  );
}
'@ @'
export function EmptyState({ title, hint, action }: { title: string; hint?: string; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-center justify-center px-6 py-14 text-center">
      <div className="flex h-12 w-12 items-center justify-center rounded-full bg-slate-100 text-slate-400"><Inbox className="h-6 w-6" /></div>
      <div className="mt-3 text-sm font-medium text-slate-700">{title}</div>
      {hint && <div className="mt-1 max-w-sm text-sm text-slate-500">{hint}</div>}
      {action && <div className="mt-4">{action}</div>}
    </div>
  );
}
'@

Patch 'apps/web/src/renderer/views.tsx' @'
    newButton: allowed ? <button onClick={() => setOpen(v => !v)} className={btn}><Plus className="h-4 w-4" />New</button> : null,
'@ @'
    newButton: allowed ? <button onClick={() => setOpen(v => !v)} className={btn}><Plus className="h-4 w-4" />New</button> : null,
    openForm: allowed ? () => setOpen(true) : undefined,
'@

Patch 'apps/web/src/renderer/views.tsx' @'
          {!filtered.length && <EmptyState title={query ? 'No matches' : 'Nothing here yet'} hint={query ? 'Try a different search.' : 'Records you add will appear here.'} />}
'@ @'
          {!filtered.length && (query
            ? <EmptyState title="No matches" hint="Try a different search." />
            : <EmptyState
                title={`No ${ent.label} records yet`}
                hint={c.openForm ? 'Create the first one, or bring in a spreadsheet with Excel > Import.' : 'Records appear here once someone with the right role creates them.'}
                action={c.openForm ? <button onClick={c.openForm} className={btn}><Plus className="h-4 w-4" />Create the first one</button> : undefined} />)}
'@

Patch 'apps/web/src/renderer/kanban.tsx' @'
import { Cell, columnFields, Denial, labelOf, btn, PageHeader, stateDot, Skeleton } from './fields';
'@ @'
import { Cell, columnFields, Denial, labelOf, btn, PageHeader, stateDot, Skeleton, EmptyState, card } from './fields';
import { markDone } from '../help/progress';
'@

Patch 'apps/web/src/renderer/kanban.tsx' @'
      {q.error && <Denial err={errOf(q.error)} />}
'@ @'
      {q.error && <Denial err={errOf(q.error)} />}
      {!q.isLoading && !q.error && !rows.length && (
        <div className={card}>
          <EmptyState title={`No ${ent.label} records yet`}
            hint={canNew ? 'Create the first one. It starts in the first column and moves right as it goes through the steps.' : 'Records appear here once someone with the right role creates them.'}
            action={canNew ? <button onClick={() => setCreating(true)} className={btn}><Plus className="h-4 w-4" />Create the first one</button> : undefined} />
        </div>
      )}
'@

# ============================== patches: progress tracking ==============================
Patch 'apps/web/src/renderer/kanban.tsx' @'
    onSuccess: () => { setErr(null); qc.invalidateQueries({ predicate: x => x.queryKey[1] === siteId }); },
'@ @'
    onSuccess: () => { setErr(null); markDone('movedRequest'); qc.invalidateQueries({ predicate: x => x.queryKey[1] === siteId }); },
'@

Patch 'apps/web/src/renderer/RecordDetail.tsx' @'
import { RecordForm } from './RecordForm';
'@ @'
import { RecordForm } from './RecordForm';
import { markDone } from '../help/progress';
'@

Patch 'apps/web/src/renderer/RecordDetail.tsx' @'
    onSuccess: () => { setErr(null); qc.invalidateQueries({ predicate: x => x.queryKey[1] === siteId }); },
'@ @'
    onSuccess: () => { setErr(null); markDone('movedRequest'); qc.invalidateQueries({ predicate: x => x.queryKey[1] === siteId }); },
'@

Patch 'apps/web/src/renderer/excel.tsx' @'
import { Denial, btn, btnGhost } from './fields';
'@ @'
import { Denial, btn, btnGhost } from './fields';
import { markDone } from '../help/progress';
'@

Patch 'apps/web/src/renderer/excel.tsx' @'
      setTimeout(() => URL.revokeObjectURL(url), 1000);
'@ @'
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      markDone('usedExcel');
'@

Patch 'apps/web/src/renderer/excel.tsx' @'
        {!isManager && <span className="text-xs text-slate-400">Your export leaves out columns your role cannot see.</span>}
'@ @'
        {!isManager && <span className="text-xs text-slate-400">Import is for Managers and Admins. Your export leaves out columns your role cannot see.</span>}
'@

# ============================== patches: site shell help ==============================
Patch 'apps/web/src/renderer/SiteShell.tsx' @'
import { SerialTimeline } from './SerialTimeline';
'@ @'
import { SerialTimeline } from './SerialTimeline';
import { markDone } from '../help/progress';
import { HelpButton } from '../help/HelpPanel';
import { SiteHelp } from '../help/content';
'@

Patch 'apps/web/src/renderer/SiteShell.tsx' @'
      <Link to="/" className={link}><LayoutGrid className="h-4 w-4" />Hub</Link>
'@ @'
      <HelpButton title="What can I do here?" dark={dark}><SiteHelp /></HelpButton>
      <Link to="/" className={link}><LayoutGrid className="h-4 w-4" />Hub</Link>
'@

Patch 'apps/web/src/renderer/SiteShell.tsx' @'
  useLive(site.id, !preview, () => {
'@ @'
  useEffect(() => { markDone('openedUnit'); }, []);
  useLive(site.id, !preview, () => {
'@

# ============================== patches: hub ==============================
Patch 'apps/web/src/pages/Hub.tsx' @'
import { SheetUnit } from './SheetUnit';
'@ @'
import { SheetUnit } from './SheetUnit';
import { HelpButton } from '../help/HelpPanel';
import { HubHelp } from '../help/content';
import { GettingStarted } from '../help/GettingStarted';
'@

Patch 'apps/web/src/pages/Hub.tsx' @'
            {user?.hubAdmin && <Link to="/hub/ledger"
'@ @'
            <HelpButton title="The hub"><HubHelp /></HelpButton>
            {user?.hubAdmin && <Link to="/hub/ledger"
'@

Patch 'apps/web/src/pages/Hub.tsx' @'
        <div className="grid gap-5 sm:grid-cols-2 xl:grid-cols-3">{list.map(s => <UnitCard key={s.id} s={s} />)}</div>
'@ @'
        <div className="grid gap-5 sm:grid-cols-2 xl:grid-cols-3">{list.map(s => <UnitCard key={s.id} s={s} />)}</div>

        {!!list.length && <GettingStarted sites={list} isAdmin={list.some(s => s.role === 'Admin')} />}
'@

# ============================== patches: builder ==============================
Patch 'apps/web/src/builder/Builder.tsx' @'
import { PeoplePanel } from './PeoplePanel';
'@ @'
import { PeoplePanel } from './PeoplePanel';
import { HelpButton } from '../help/HelpPanel';
import { BuilderHelp } from '../help/content';
import { TAB_HELP } from '../help/glossary';
import { markDone } from '../help/progress';
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
  useEffect(() => { load(); }, [load]);
'@ @'
  useEffect(() => { load(); }, [load]);
  useEffect(() => { markDone('openedBuilder'); }, []);
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
      setGate(r.data);
      return r.data;
'@ @'
      setGate(r.data);
      markDone('ranGate');
      return r.data;
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
      setMsg({ kind: 'ok', text: `Published. ${r.data.changes.length
'@ @'
      markDone('published');
      setMsg({ kind: 'ok', text: `Published. ${r.data.changes.length
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
        <div className="font-semibold">Builder - {site.name}</div>
'@ @'
        <div className="font-semibold">Builder - {site.name}</div>
        <HelpButton title="Using the Builder"><BuilderHelp /></HelpButton>
'@

Patch 'apps/web/src/builder/Builder.tsx' @'
<button key={k} onClick={() => setTab(k)} className=
'@ @'
<button key={k} onClick={() => setTab(k)} title={TAB_HELP[k]} className=
'@

Write-Host ''
Write-Host 'Batch A done. Refresh the browser.'