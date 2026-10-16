import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ArrowLeft, ArrowRight, ShieldCheck } from 'lucide-react';
import { http, errOf } from '../api';
import { useSession } from '../store/session';

const DEMO: [string, string, string][] = [
  ['admin@axel.dev', 'Hub admin', 'All units'],
  ['manager@sc.dev', 'Service Centre', 'Manager'],
  ['member@sc.dev', 'Service Centre', 'Member'],
  ['manager@cs.dev', 'Central Stores', 'Manager'],
  ['member@cs.dev', 'Central Stores', 'Member'],
  ['field@dist.dev', 'Distribution', 'Field member'],
];
const field = 'w-full rounded-lg border border-slate-200 bg-white px-3 py-2.5 text-sm text-slate-900 shadow-sm outline-none transition placeholder:text-slate-400 focus:border-slate-400 focus:ring-4 focus:ring-slate-100';
const primary = 'inline-flex w-full items-center justify-center gap-2 rounded-lg bg-slate-900 py-2.5 text-sm font-medium text-white shadow-sm transition hover:bg-slate-800 disabled:opacity-50';

function PoweredBy() {
  return (
    <a href="https://minimoth.dev?utm_source=powered_by" target="_blank" rel="noopener" className="inline-block">
      <img src="https://minimoth.dev/powered-by/powered-by-light.svg" alt="Powered by MiniMoth" height="18" style={{ height: 18 }} className="opacity-60 transition hover:opacity-100" />
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
    <div className="relative flex min-h-screen items-center justify-center overflow-hidden bg-slate-50 px-4 py-12">
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_top,rgba(99,102,241,0.14),transparent_60%)]" />
      <div className="pointer-events-none absolute inset-0 bg-[linear-gradient(to_right,#e2e8f0_1px,transparent_1px),linear-gradient(to_bottom,#e2e8f0_1px,transparent_1px)] bg-[size:48px_48px] opacity-40 [mask-image:radial-gradient(ellipse_at_center,black_30%,transparent_75%)]" />

      <div className="relative w-full max-w-md space-y-6">
        <div className="flex flex-col items-center text-center">
          <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-slate-900 text-lg font-bold text-white shadow-lg shadow-slate-900/20">A</span>
          <h1 className="mt-5 text-2xl font-semibold tracking-tight text-slate-900">{otp ? 'Check your phone' : 'Sign in to Axel'}</h1>
          <p className="mt-1 text-sm text-slate-500">{otp ? `We sent a 6-digit code to ${otp.phoneHint}.` : 'Every site proven before it runs.'}</p>
        </div>

        {otp ? (
          <form onSubmit={e => { e.preventDefault(); verify(); }} className="space-y-5 rounded-2xl border border-slate-200 bg-white p-7 shadow-xl shadow-slate-900/5">
            <div className="flex items-center gap-3 rounded-xl bg-slate-50 px-3 py-2.5 text-sm text-slate-600 ring-1 ring-inset ring-slate-200">
              <ShieldCheck className="h-4 w-4 shrink-0 text-slate-500" />
              <span>Sent on WhatsApp. If WhatsApp does not go through, it arrives by SMS.</span>
            </div>
            <input value={code} onChange={e => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))} inputMode="numeric" autoFocus placeholder="000000"
              className="w-full rounded-xl border border-slate-200 bg-white px-3 py-3.5 text-center font-mono text-2xl tracking-[0.5em] text-slate-900 shadow-sm outline-none transition placeholder:text-slate-300 focus:border-slate-400 focus:ring-4 focus:ring-slate-100" />
            {otp.mode === 'test' && <div className="rounded-lg bg-sky-50 px-3 py-2 text-center text-xs text-sky-800 ring-1 ring-inset ring-sky-200">Test mode: no message is sent. The code is 000000.</div>}
            {err && <div className="rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700">{err}</div>}
            {info && <div className="rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-800">{info}</div>}
            <button disabled={busy || code.length !== 6} className={primary}>{busy ? 'Checking...' : 'Verify and sign in'}</button>
            <div className="flex items-center justify-between text-sm">
              <button type="button" onClick={() => { setOtp(null); setErr(''); setInfo(''); }} className="inline-flex items-center gap-1 text-slate-500 hover:text-slate-900"><ArrowLeft className="h-4 w-4" />Back</button>
              <button type="button" onClick={resend} disabled={busy} className="text-slate-500 hover:text-slate-900">Send a new code</button>
            </div>
            <div className="flex justify-center border-t border-slate-100 pt-4"><PoweredBy /></div>
          </form>
        ) : (
          <>
            <form onSubmit={e => { e.preventDefault(); submit(); }} className="space-y-5 rounded-2xl border border-slate-200 bg-white p-7 shadow-xl shadow-slate-900/5">
              <label className="block">
                <span className="mb-1.5 block text-sm font-medium text-slate-700">Email</span>
                <input value={email} onChange={e => setEmail(e.target.value)} className={field} />
              </label>
              <label className="block">
                <span className="mb-1.5 block text-sm font-medium text-slate-700">Password</span>
                <input type="password" value={password} onChange={e => setPassword(e.target.value)} className={field} />
              </label>
              {err && <div className="rounded-lg bg-rose-50 px-3 py-2 text-sm text-rose-700">{err}</div>}
              <button disabled={busy} className={primary}>{busy ? 'Signing in...' : <>Continue<ArrowRight className="h-4 w-4" /></>}</button>
              <p className="text-center text-xs text-slate-400">Password first, then a one-time code on your phone.</p>
              <div className="flex justify-center"><PoweredBy /></div>
            </form>

            <div className="rounded-2xl border border-slate-200 bg-white/80 p-3 shadow-sm backdrop-blur">
              <div className="px-2 pb-2 pt-1 text-center text-xs font-medium uppercase tracking-wide text-slate-400">Demo accounts - password demo1234</div>
              <div className="grid gap-0.5">
                {DEMO.map(([em, unit, role]) => (
                  <button key={em} onClick={() => { setEmail(em); submit(em); }} className="flex items-center gap-3 rounded-lg px-2 py-2 text-left transition hover:bg-slate-50">
                    <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-slate-100 text-[11px] font-semibold text-slate-600">{unit.split(' ').map(w => w[0]).join('').slice(0, 2)}</span>
                    <span className="min-w-0 flex-1">
                      <span className="block text-sm font-medium text-slate-800">{unit}</span>
                      <span className="block truncate text-xs text-slate-400">{em}</span>
                    </span>
                    <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs text-slate-600">{role}</span>
                  </button>
                ))}
              </div>
            </div>
          </>
        )}

        <div className="flex items-center justify-center gap-3 text-xs text-slate-400">
          <span>Derived</span><span className="h-1 w-1 rounded-full bg-slate-300" />
          <span>Proven</span><span className="h-1 w-1 rounded-full bg-slate-300" />
          <span>Reversible</span><span className="h-1 w-1 rounded-full bg-slate-300" />
          <span>PS 03 - Team Breaking Bytes</span>
        </div>
        <div className="text-center"><Link to="/track" className="text-sm font-medium text-slate-600 underline-offset-4 hover:text-slate-900 hover:underline">Track a repair without signing in</Link></div>
      </div>
    </div>
  );
}
