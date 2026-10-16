import { useEffect, useState } from 'react';
import { http, errOf } from '../api';
import { useSession } from '../store/session';

const ROLES = ['Public', 'Member', 'Manager', 'Admin'];

export function PeoplePanel({ siteId, H }: { siteId: string; H: any }) {
  const me = useSession(s => s.user);
  const [rows, setRows] = useState<any[] | null>(null);
  const [email, setEmail] = useState('');
  const [role, setRole] = useState('Member');
  const [name, setName] = useState('');
  const [password, setPassword] = useState('');
  const [phone, setPhone] = useState('');
  const [needsAccount, setNeedsAccount] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  const load = () => http.get(`/sites/${siteId}/members`, H).then(r => setRows(r.data), e => setMsg({ ok: false, text: errOf(e).message }));
  useEffect(() => { load(); }, [siteId]);

  async function add() {
    setMsg(null);
    try {
      await http.post(`/sites/${siteId}/members`, { email, role, ...(needsAccount ? { name, password, ...(phone ? { phone } : {}) } : {}) }, H);
      setMsg({ ok: true, text: `${email} added as ${role}.` });
      setEmail(''); setName(''); setPassword(''); setNeedsAccount(false);
      load();
    } catch (e: any) {
      if (e?.response?.data?.needsAccount) setNeedsAccount(true);
      setMsg({ ok: false, text: errOf(e).message });
    }
  }
  async function change(userId: string, r: string) {
    try { await http.patch(`/sites/${siteId}/members/${userId}`, { role: r }, H); load(); }
    catch (e) { setMsg({ ok: false, text: errOf(e).message }); }
  }
  async function remove(userId: string) {
    if (!window.confirm('Remove this member from the unit?')) return;
    try { await http.delete(`/sites/${siteId}/members/${userId}`, H); load(); }
    catch (e) { setMsg({ ok: false, text: errOf(e).message }); }
  }

  return (
    <div className="space-y-4 text-sm">
      <div className="text-slate-600">Who can use this unit, and with which role. Nobody can change their own role.</div>
      {!rows && <div className="text-slate-400">Loading...</div>}
      <div className="space-y-1">
        {rows?.map(r => (
          <div key={r.user_id} className="flex items-center gap-2 rounded border p-2">
            <div className="min-w-0 flex-1">
              <div className="truncate font-medium">{r.name}{r.user_id === me?.id ? ' (you)' : ''}</div>
              <div className="truncate text-xs text-slate-500">{r.email}</div>
            </div>
            <select value={r.role} disabled={r.user_id === me?.id} onChange={e => change(r.user_id, e.target.value)} className="rounded border px-1 py-1 text-xs">
              {ROLES.map(x => <option key={x}>{x}</option>)}
            </select>
            {r.user_id !== me?.id && <button onClick={() => remove(r.user_id)} className="text-xs text-red-600">remove</button>}
          </div>
        ))}
      </div>
      <div className="space-y-2 rounded-lg border p-3">
        <div className="font-medium">Add a member</div>
        <div className="grid grid-cols-3 gap-2">
          <input value={email} onChange={e => setEmail(e.target.value)} placeholder="email" className="col-span-2 rounded border px-2 py-1" />
          <select value={role} onChange={e => setRole(e.target.value)} className="rounded border px-2 py-1">{ROLES.map(x => <option key={x}>{x}</option>)}</select>
        </div>
        {needsAccount && (
          <div className="grid grid-cols-2 gap-2">
            <input value={name} onChange={e => setName(e.target.value)} placeholder="Full name" className="rounded border px-2 py-1" />
            <input value={password} onChange={e => setPassword(e.target.value)} placeholder="Starting password (8+)" type="password" className="rounded border px-2 py-1" />
            <input value={phone} onChange={e => setPhone(e.target.value)} placeholder="Mobile for the login code, e.g. 9876543210" className="col-span-2 rounded border px-2 py-1" />
          </div>
        )}
        <button disabled={!email} onClick={add} className="rounded-md bg-slate-900 px-3 py-1 text-xs text-white disabled:opacity-40">{needsAccount ? 'Create account and add' : 'Add'}</button>
      </div>
      {msg && <div className={`rounded px-3 py-2 text-xs ${msg.ok ? 'bg-emerald-50 text-emerald-800' : 'bg-red-50 text-red-700'}`}>{msg.text}</div>}
    </div>
  );
}
