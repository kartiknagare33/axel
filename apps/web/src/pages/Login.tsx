import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { http, errOf } from '../api';
import { useSession } from '../store/session';

const DEMO: [string, string][] = [
  ['admin@axel.dev', 'Hub admin (all sites)'],
  ['manager@sc.dev', 'Service Centre manager'],
  ['member@sc.dev', 'Service Centre member'],
  ['manager@cs.dev', 'Central Stores manager'],
  ['member@cs.dev', 'Central Stores member'],
  ['field@dist.dev', 'Distribution field member'],
];

export default function Login() {
  const [email, setEmail] = useState('admin@axel.dev');
  const [password, setPassword] = useState('demo1234');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const login = useSession(s => s.login);
  const nav = useNavigate();

  async function submit(em = email) {
    setErr(''); setBusy(true);
    try {
      const r = await http.post('/auth/login', { email: em, password });
      login(r.data.token, r.data.user);
      nav('/');
    } catch (e) {
      setErr(errOf(e).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-md space-y-6">
        <div className="text-center">
          <div className="text-3xl font-bold tracking-tight">Axel</div>
          <div className="text-sm text-slate-500">Every site proven before it runs.</div>
        </div>
        <form onSubmit={e => { e.preventDefault(); submit(); }} className="space-y-3 rounded-xl border bg-white p-6 shadow-sm">
          <label className="block text-sm">
            <span className="mb-1 block text-slate-600">Email</span>
            <input value={email} onChange={e => setEmail(e.target.value)} className="w-full rounded-lg border px-3 py-2" />
          </label>
          <label className="block text-sm">
            <span className="mb-1 block text-slate-600">Password</span>
            <input type="password" value={password} onChange={e => setPassword(e.target.value)} className="w-full rounded-lg border px-3 py-2" />
          </label>
          {err && <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
          <button disabled={busy} className="w-full rounded-lg bg-slate-900 py-2 font-medium text-white disabled:opacity-50">
            {busy ? 'Signing in...' : 'Sign in'}
          </button>
        </form>
        <div className="rounded-xl border bg-white p-4">
          <div className="mb-2 text-xs font-medium uppercase text-slate-400">Demo accounts (password demo1234)</div>
          <div className="grid gap-1">
            {DEMO.map(([em, label]) => (
              <button key={em} onClick={() => { setEmail(em); submit(em); }} className="flex justify-between rounded-lg px-3 py-1.5 text-left text-sm hover:bg-slate-50">
                <span>{label}</span><span className="text-slate-400">{em}</span>
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
