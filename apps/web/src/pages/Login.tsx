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

function PoweredBy() {
  return (
    <a href="https://minimoth.dev?utm_source=powered_by" target="_blank" rel="noopener" className="inline-block">
      <img src="https://minimoth.dev/powered-by/powered-by-light-logo.svg" alt="Powered by MiniMoth" height="28" style={{ height: 28 }} />
    </a>
  );
}

export default function Login() {
  const [email, setEmail] = useState('admin@axel.dev');
  const [password, setPassword] = useState('demo1234');
  const [otp, setOtp] = useState<null | { challenge: string; phoneHint: string; mode: string }>(null);
  const [code, setCode] = useState('');
  const [err, setErr] = useState('');
  const [info, setInfo] = useState('');
  const [busy, setBusy] = useState(false);
  const login = useSession(s => s.login);
  const nav = useNavigate();
  const finish = (d: any) => { login(d.token, d.user); nav('/'); };

  async function submit(em = email) {
    setErr(''); setInfo(''); setBusy(true);
    try {
      const r = await http.post('/auth/login', { email: em, password });
      if (r.data.otpRequired) { setOtp({ challenge: r.data.challenge, phoneHint: r.data.phoneHint, mode: r.data.mode }); setCode(''); }
      else finish(r.data);
    } catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  async function verify() {
    if (!otp) return;
    setErr(''); setInfo(''); setBusy(true);
    try { finish((await http.post('/auth/verify-otp', { challenge: otp.challenge, code })).data); }
    catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }
  async function resend() {
    if (!otp) return;
    setErr(''); setInfo(''); setBusy(true);
    try { await http.post('/auth/resend-otp', { challenge: otp.challenge }); setInfo('A new code is on its way.'); }
    catch (e) { setErr(errOf(e).message); } finally { setBusy(false); }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-md space-y-6">
        <div className="text-center">
          <div className="text-3xl font-bold tracking-tight">Axel</div>
          <div className="text-sm text-slate-500">Every site proven before it runs.</div>
        </div>

        {otp ? (
          <form onSubmit={e => { e.preventDefault(); verify(); }} className="space-y-3 rounded-xl border bg-white p-6 shadow-sm">
            <div className="font-medium">Enter the 6-digit code</div>
            <div className="text-sm text-slate-500">Sent to {otp.phoneHint} on WhatsApp (SMS if WhatsApp does not go through).</div>
            <input value={code} onChange={e => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))} inputMode="numeric" autoFocus
              placeholder="000000" className="w-full rounded-lg border px-3 py-3 text-center font-mono text-2xl tracking-[0.5em]" />
            {otp.mode === 'test' && <div className="rounded-lg bg-sky-50 px-3 py-2 text-xs text-sky-800">Test mode: no message is sent. The code is 000000.</div>}
            {err && <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
            {info && <div className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800">{info}</div>}
            <button disabled={busy || code.length !== 6} className="w-full rounded-lg bg-slate-900 py-2 font-medium text-white disabled:opacity-50">{busy ? 'Checking...' : 'Verify and sign in'}</button>
            <div className="flex justify-between text-sm">
              <button type="button" onClick={() => { setOtp(null); setErr(''); setInfo(''); }} className="text-slate-500 hover:text-slate-900">Back</button>
              <button type="button" onClick={resend} disabled={busy} className="text-slate-500 hover:text-slate-900">Send a new code</button>
            </div>
            <div className="flex justify-center pt-1"><PoweredBy /></div>
          </form>
        ) : (
          <>
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
              <button disabled={busy} className="w-full rounded-lg bg-slate-900 py-2 font-medium text-white disabled:opacity-50">{busy ? 'Signing in...' : 'Continue'}</button>
              <div className="text-center text-xs text-slate-400">Password first, then a one-time code on your phone.</div>
              <div className="flex justify-center"><PoweredBy /></div>
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
          </>
        )}
      </div>
    </div>
  );
}
