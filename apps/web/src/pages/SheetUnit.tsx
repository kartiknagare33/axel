import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { REGISTRY } from '@axel/compiler';
import { http, errOf } from '../api';

const slugify = (s: string) => s.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);

export function SheetUnit() {
  const [open, setOpen] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [name, setName] = useState('');
  const [preview, setPreview] = useState<any>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const qc = useQueryClient();
  const nav = useNavigate();

  async function read() {
    if (!file) return;
    setBusy(true); setErr(''); setPreview(null);
    try {
      const r = await http.post(`/sites/infer?name=${encodeURIComponent(name)}`, await file.arrayBuffer(), { headers: { 'Content-Type': 'application/octet-stream' } });
      setPreview(r.data);
    } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  async function create() {
    if (!file) return;
    setBusy(true); setErr('');
    try {
      const r = await http.post(`/sites/infer?name=${encodeURIComponent(name)}&slug=${slugify(name)}&create=true`, await file.arrayBuffer(), { headers: { 'Content-Type': 'application/octet-stream' } });
      await qc.invalidateQueries({ queryKey: ['sites'] });
      nav(`/builder/${r.data.id}`);
    } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }

  if (!open) return <button onClick={() => setOpen(true)} className="rounded-lg border border-dashed border-slate-300 px-4 py-2 text-sm text-slate-600 hover:bg-white">+ From a spreadsheet</button>;
  const errors = (preview?.diagnostics ?? []).filter((d: any) => d.severity === 'error');
  return (
    <div className="w-[640px] max-w-full space-y-3 rounded-xl border bg-white p-5 text-left">
      <div className="font-medium">New unit from a spreadsheet</div>
      <div className="text-sm text-slate-500">Upload the register this unit already keeps. Axel proposes the site and explains every guess. Try <code>demo/registers/Workshop_Tools.xlsx</code>.</div>
      <input type="file" accept=".xlsx" onChange={e => {
        const f = e.target.files?.[0] ?? null;
        setFile(f); setPreview(null);
        if (f && !name) setName(f.name.replace(/\.xlsx$/i, '').replace(/[_-]+/g, ' ').trim());
      }} />
      <input value={name} onChange={e => setName(e.target.value)} placeholder="Unit name" className="w-full rounded-lg border px-3 py-2 text-sm" />
      <div className="flex gap-2">
        <button disabled={!file || name.trim().length < 2 || busy} onClick={read} className="rounded-lg border px-4 py-2 text-sm disabled:opacity-50">{busy && !preview ? 'Reading...' : 'Read spreadsheet'}</button>
        <button onClick={() => { setOpen(false); setPreview(null); setFile(null); }} className="rounded-lg border px-4 py-2 text-sm">Cancel</button>
      </div>
      {err && <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
      {preview && (
        <div className="space-y-3">
          <div className="flex flex-wrap gap-2 text-xs">
            {preview.sheets.map((s: any) => <span key={s.name} className="rounded bg-slate-100 px-2 py-1">{s.name}: {s.rows} rows</span>)}
            <span className="rounded bg-slate-900 px-2 py-1 text-white">{preview.blueprint.theme.layout} layout</span>
          </div>
          <div className="flex flex-wrap gap-1">
            {preview.blueprint.modules.filter((m: string) => !['auth', 'users', 'dashboard'].includes(m)).map((m: string) => (
              <span key={m} className="rounded bg-emerald-50 px-1.5 py-0.5 text-[11px] text-emerald-800">{REGISTRY[m]?.name ?? m}</span>
            ))}
          </div>
          {preview.blueprint.workflows?.request && (
            <div className="text-xs text-slate-600">Workflow: {preview.blueprint.workflows.request.states.join(' > ')}</div>
          )}
          <div className="max-h-72 space-y-1 overflow-y-auto rounded-lg border p-2">
            {preview.inferences.map((i: any, n: number) => (
              <div key={n} className={`flex items-start gap-2 rounded px-1 py-1 text-xs ${i.confidence < 0.6 ? 'bg-amber-50' : ''}`}>
                <div className="mt-1 h-1.5 w-14 shrink-0 rounded bg-slate-200"><div className="h-1.5 rounded bg-slate-900" style={{ width: `${Math.round(i.confidence * 100)}%` }} /></div>
                <span className="w-8 shrink-0 text-slate-400">{Math.round(i.confidence * 100)}%</span>
                <span className="w-28 shrink-0 font-mono text-[10px] text-slate-500">{i.rule}</span>
                <span>{i.explanation}{i.confidence < 0.6 ? ' (check this)' : ''}</span>
              </div>
            ))}
          </div>
          {!!errors.length && <div className="rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700">{errors.map((d: any) => d.message).join(' ')}</div>}
          <button disabled={busy || !!errors.length} onClick={create} className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50">
            {busy ? 'Creating...' : `Create unit and import ${preview.counts.items + preview.counts.requests} rows`}
          </button>
        </div>
      )}
    </div>
  );
}
