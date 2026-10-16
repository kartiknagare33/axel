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
