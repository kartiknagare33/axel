import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { http, errOf, type ApiErr } from '../api';
import { useSite, RANK } from '../hooks';
import { Denial, btn, btnGhost } from './fields';
import { markDone } from '../help/progress';

async function blobErr(e: any): Promise<ApiErr> {
  const d = e?.response?.data;
  if (d instanceof Blob) {
    try { const j = JSON.parse(await d.text()); return { message: j.message, code: j.code }; } catch { /* fall through */ }
  }
  return errOf(e);
}

export function ExcelBar({ entity }: { entity: string }) {
  const { siteId, schema } = useSite();
  const qc = useQueryClient();
  const [open, setOpen] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [report, setReport] = useState<any>(null);
  const [err, setErr] = useState<ApiErr | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState('');
  if (!schema.modules.includes('excel')) return null;
  const H = { 'X-Site-Id': siteId };
  const isManager = RANK[schema.role] >= 2;

  async function download(path: string, fallback: string) {
    setErr(null);
    try {
      const r = await http.get(`/${siteId}${path}`, { headers: H, responseType: 'blob' });
      const name = /filename="([^"]+)"/.exec(String(r.headers['content-disposition'] ?? ''))?.[1] ?? fallback;
      const url = URL.createObjectURL(r.data);
      const a = document.createElement('a');
      a.href = url; a.download = name;
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      markDone('usedExcel');
    } catch (e) { setErr(await blobErr(e)); }
  }

  async function run(dryRun: boolean) {
    if (!file) return;
    setBusy(true); setErr(null); setDone('');
    try {
      const r = await http.post(`/${siteId}/excel/import/${entity}?dryRun=${dryRun}`, await file.arrayBuffer(),
        { headers: { ...H, 'Content-Type': 'application/octet-stream' } });
      if (dryRun) setReport(r.data);
      else {
        setDone(`Imported ${r.data.imported} row(s).`);
        setReport(null); setFile(null);
        qc.invalidateQueries({ predicate: q => q.queryKey[1] === siteId });
      }
    } catch (e: any) {
      setErr(errOf(e));
      if (e?.response?.data?.errors) setReport((p: any) => ({ ...(p ?? {}), errors: e.response.data.errors }));
    } finally { setBusy(false); }
  }

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="text-xs font-medium uppercase text-slate-400">Excel</span>
        <button onClick={() => download(`/excel/export/${entity}`, `${entity}.xlsx`)} className={btnGhost}>Export</button>
        <button onClick={() => download(`/excel/template/${entity}`, `${entity}-template.xlsx`)} className={btnGhost}>Template</button>
        <button onClick={() => { setOpen(o => !o); setReport(null); setErr(null); setDone(''); }} className={btnGhost}>Import...</button>
        {!isManager && <span className="text-xs text-slate-400">Import is for Managers and Admins. Your export leaves out columns your role cannot see.</span>}
      </div>
      {open && (
        <div className="space-y-3 rounded-site border bg-white p-4 text-sm">
          <div className="text-slate-600">Upload an .xlsx (use Template for the right columns). The file is checked first; nothing is saved unless every row is valid.</div>
          <input type="file" accept=".xlsx" onChange={e => { setFile(e.target.files?.[0] ?? null); setReport(null); setErr(null); setDone(''); }} />
          <div className="flex gap-2">
            <button disabled={!file || busy} onClick={() => run(true)} className={btnGhost}>{busy ? 'Checking...' : 'Check file (dry run)'}</button>
            <button disabled={!file || busy || !report || (report.errors?.length ?? 0) > 0 || !report.valid} onClick={() => run(false)} className={btn}>
              Import {report?.valid ?? ''} row(s)
            </button>
          </div>
          {report && report.rows != null && (
            <div className={`rounded px-3 py-2 ${report.errors?.length ? 'bg-amber-50 text-amber-900' : 'bg-emerald-50 text-emerald-800'}`}>
              {report.rows} row(s) read - {report.valid} valid - {report.errors?.length ?? 0} problem(s)
            </div>
          )}
          {!!report?.errors?.length && (
            <table className="w-full text-left text-xs">
              <thead className="text-slate-500"><tr><th className="py-1">Row</th><th>Column</th><th>Problem</th></tr></thead>
              <tbody>{report.errors.map((e: any, i: number) => (
                <tr key={i} className="border-t"><td className="py-1">{e.row}</td><td>{e.field}</td><td>{e.message}</td></tr>
              ))}</tbody>
            </table>
          )}
          {!!report?.warnings?.length && <ul className="list-disc pl-5 text-xs text-slate-500">{report.warnings.map((w: string) => <li key={w}>{w}</li>)}</ul>}
          {err && <Denial err={err} />}
          {done && <div className="rounded bg-emerald-50 px-3 py-2 text-emerald-800">{done}</div>}
        </div>
      )}
      {!open && err && <Denial err={err} />}
    </div>
  );
}
