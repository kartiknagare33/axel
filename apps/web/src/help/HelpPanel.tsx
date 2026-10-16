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
