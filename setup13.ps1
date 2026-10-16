# Axel - MiniMoth OTP login (password, then WhatsApp/SMS one-time code). Run from the axel folder.
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
function AppendIfMissing([string]$Path, [string]$Marker, [string]$Block) {
  $full = Join-Path $PSScriptRoot $Path
  $text = [System.IO.File]::ReadAllText($full).Replace("`r`n", "`n")
  if ($text.Contains($Marker)) { Write-Host "already has $Marker in $Path"; return }
  [System.IO.File]::WriteAllText($full, $text.TrimEnd("`n") + "`n" + $Block.Replace("`r`n", "`n").Trim("`n") + "`n", (New-Object System.Text.UTF8Encoding $false))
  Write-Host "updated $Path"
}

# ============================== env ==============================
$envBlock = @'
# MiniMoth OTP login (https://minimoth.dev)
# Test key (mm_test_...): no message is sent, the code is always 000000. Use it for development and tests.
# Live key (mm_live_...): real WhatsApp/SMS, 3 codes per number per 10 minutes. Use it only for the real demo.
MINIMOTH_API_KEY=
# Who must enter a one-time code at login: all | admins | off
OTP_REQUIRED=all
# Your real mobile number for the hub admin (used by pnpm seed and pnpm set-phone), e.g. +919876543210
DEMO_ADMIN_PHONE=
'@
AppendIfMissing '.env' 'MINIMOTH_API_KEY' $envBlock
AppendIfMissing '.env.example' 'MINIMOTH_API_KEY' $envBlock

# ============================== scripts ==============================
Patch 'package.json' @'
    "test:stage": "pnpm --filter @axel/api test:stage",
'@ @'
    "test:stage": "pnpm --filter @axel/api test:stage",
    "set-phone": "pnpm --filter @axel/api set-phone",
'@

Patch 'apps/api/package.json' @'
    "test:stage": "tsx --env-file=../../.env --test test/stage.test.ts",
'@ @'
    "test:stage": "tsx --env-file=../../.env --test test/stage.test.ts",
    "set-phone": "tsx --env-file=../../.env scripts/set-phone.ts",
'@

# ============================== DB + seed ==============================
W 'apps/api/migrations/004_phone.sql' @'
-- Mobile number used for the MiniMoth one-time code at login.
ALTER TABLE users ADD COLUMN phone text;
'@

Patch 'apps/api/seed/seed.ts' @'
const mk = async (email: string, name: string, hub = false) =>
  (await pool.query('INSERT INTO users (email, password_hash, name, is_hub_admin) VALUES ($1,$2,$3,$4) RETURNING id', [email, hash, name, hub])).rows[0].id as string;
'@ @'
let phoneN = 0;
const normPhone = (p: string) => (p.startsWith('+') ? p : `+91${p}`).replace(/[\s-]/g, '');
// Demo accounts get distinct placeholder numbers (fine with a test key). The hub admin can use your real number.
const mk = async (email: string, name: string, hub = false) => {
  phoneN++;
  const phone = hub && process.env.DEMO_ADMIN_PHONE ? normPhone(process.env.DEMO_ADMIN_PHONE) : `+919000000${String(phoneN).padStart(3, '0')}`;
  return (await pool.query('INSERT INTO users (email, password_hash, name, is_hub_admin, phone) VALUES ($1,$2,$3,$4,$5) RETURNING id', [email, hash, name, hub, phone])).rows[0].id as string;
};
'@

W 'apps/api/scripts/set-phone.ts' @'
import pg from 'pg';

// pnpm set-phone                           -> give every account without a number a placeholder (admin: DEMO_ADMIN_PHONE)
// pnpm set-phone admin@axel.dev 98xxxxxxxx -> set one account's real mobile number
const norm = (p: string) => (p.startsWith('+') ? p : `+91${p}`).replace(/[\s-]/g, '');
const [email, phoneArg] = process.argv.slice(2);
const c = new pg.Client({ connectionString: process.env.DATABASE_URL_APP });
await c.connect();
if (email && phoneArg) {
  const phone = norm(phoneArg);
  if (!/^\+91[6-9]\d{9}$/.test(phone)) { console.error('Use an Indian mobile number, e.g. 9876543210 or +919876543210'); process.exit(1); }
  const r = await c.query('UPDATE users SET phone = $2 WHERE email = $1 RETURNING email', [email, phone]);
  console.log(r.rowCount ? `${email} -> ${phone}` : `No account with email ${email}`);
}
const missing = (await c.query('SELECT id, email, is_hub_admin FROM users WHERE phone IS NULL ORDER BY created_at')).rows;
let n = 0;
for (const u of missing) {
  n++;
  const p = u.is_hub_admin && process.env.DEMO_ADMIN_PHONE ? norm(process.env.DEMO_ADMIN_PHONE) : `+919000000${String(100 + n)}`;
  await c.query('UPDATE users SET phone = $2 WHERE id = $1', [u.id, p]);
  console.log(`${u.email} -> ${p}`);
}
if (!missing.length && !(email && phoneArg)) console.log('Every account already has a phone number.');
await c.end();
'@

# ============================== API: MiniMoth client + auth ==============================
W 'apps/api/src/minimoth.ts' @'
import { AxelError } from './errors';

// MiniMoth OTP (https://minimoth.dev/docs): POST /v1/otp/send { phone }, POST /v1/otp/verify { phone, code }.
// We use the "OTP-only" recipe: MiniMoth proves the phone, Axel issues its own session JWT.
const BASE = process.env.MINIMOTH_BASE_URL ?? 'https://api.minimoth.dev';
const key = () => (process.env.MINIMOTH_API_KEY ?? '').trim();
const PLACEHOLDER = /^\+919000000\d{3}$/;

export const otpEnabled = () => key().length > 0;
export const otpMode = () => (key().startsWith('mm_test_') ? 'test' : key().startsWith('mm_live_') ? 'live' : key() ? 'unknown' : 'off');
export const maskPhone = (p: string) => (p.length > 6 ? `${p.slice(0, 3)} ******${p.slice(-4)}` : '******');

const MESSAGES: Record<string, [number, string]> = {
  OTP_RATE_LIMITED: [429, 'Too many codes were sent to this number. Wait 10 minutes and try again.'],
  INSUFFICIENT_BALANCE: [402, 'The OTP wallet is empty. Top up at app.minimoth.dev.'],
  INVALID_PHONE: [422, 'The mobile number on this account is not valid.'],
  SMS_FAILED: [502, 'The code could not be delivered on WhatsApp or SMS. Try again in a moment.'],
  INVALID_OTP: [400, 'That code is not right. Check it and try again.'],
  OTP_NOT_FOUND: [400, 'That code has expired or was already used. Send a new one.'],
  VERIFY_RATE_LIMITED: [429, 'Too many wrong attempts. Send a new code.'],
  INVALID_OTP_CODE: [422, 'Enter the 6-digit code.'],
  INVALID_API_KEY: [500, 'The OTP service key is not valid. Check MINIMOTH_API_KEY in .env.'],
  MISSING_API_KEY: [500, 'MINIMOTH_API_KEY is missing in .env.'],
  RATE_LIMITED: [429, 'The OTP service is busy. Try again in a minute.'],
};

async function call(path: string, body: unknown) {
  let r: Response;
  try {
    r = await fetch(BASE + path, { method: 'POST', headers: { 'X-Api-Key': key(), 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  } catch {
    throw new AxelError('OTP_UNAVAILABLE', 503, 'Could not reach the OTP service. Check the internet connection.');
  }
  const data: any = await r.json().catch(() => ({}));
  if (!r.ok) {
    const code = data?.code ?? 'OTP_ERROR';
    const [status, message] = MESSAGES[code] ?? [r.status >= 500 ? 502 : 400, data?.error ?? 'The OTP service returned an error.'];
    throw new AxelError(code, status, message, { provider: 'minimoth' });
  }
  return data;
}

export async function sendOtp(phone: string): Promise<{ otp_id: string; expires_at: string }> {
  if (otpMode() === 'live' && PLACEHOLDER.test(phone))
    throw new AxelError('OTP_PHONE_PLACEHOLDER', 400, 'This demo account only has a placeholder number. Set OTP_REQUIRED=admins for live mode, or give it a real number with pnpm set-phone.');
  return call('/v1/otp/send', { phone });
}

export async function verifyOtp(phone: string, code: string) {
  return call('/v1/otp/verify', { phone, code });
}
'@

W 'apps/api/src/auth.ts' @'
import { Router, type RequestHandler } from 'express';
import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { pool, withUser } from './db';
import { AxelError, ah } from './errors';
import { otpEnabled, otpMode, sendOtp, verifyOtp, maskPhone } from './minimoth';
import type { SiteReq } from './site';

export interface AuthUser { id: string; hubAdmin: boolean }
declare global {
  namespace Express { interface Request { user?: AuthUser; site?: SiteReq } }
}

const SECRET = process.env.JWT_SECRET!;
if (!SECRET || SECRET.length < 32) throw new Error('JWT_SECRET must be at least 32 chars');
// Signed with a different key, so an OTP challenge can never be used as a session token.
const CHALLENGE_SECRET = `${SECRET}:otp-challenge`;

export const memberships = (userId: string) =>
  withUser(userId, async c => (await c.query(
    `SELECT m.site_id, m.role, s.slug, s.name FROM memberships m JOIN sites s ON s.id = m.site_id
     WHERE m.user_id = $1 ORDER BY s.name`, [userId])).rows);

// The session JWT carries the user's roles and allowed sites (as required), but every request
// still re-reads the role from the database, so a demotion takes effect on the very next click.
async function issue(u: any, amr: string[]) {
  const ms = await memberships(u.id);
  const token = jwt.sign(
    { hub_admin: u.is_hub_admin, name: u.name, amr, sites: ms.map((m: any) => ({ id: m.site_id, slug: m.slug, role: m.role })) },
    SECRET, { subject: u.id, expiresIn: process.env.JWT_TTL ?? '12h' } as jwt.SignOptions);
  return { token, user: { id: u.id, email: u.email, name: u.name, hubAdmin: u.is_hub_admin }, memberships: ms };
}

const otpRequiredFor = (u: any) => {
  if (!otpEnabled()) return false;
  const mode = (process.env.OTP_REQUIRED ?? 'all').toLowerCase();
  if (mode === 'off') return false;
  if (mode === 'admins') return !!u.is_hub_admin;
  return true;
};

export const requireAuth: RequestHandler = (req, _res, next) => {
  const h = req.headers.authorization;
  if (!h?.startsWith('Bearer ')) return next(new AxelError('UNAUTHENTICATED', 401, 'Log in to continue.'));
  try {
    const p = jwt.verify(h.slice(7), SECRET) as jwt.JwtPayload;
    req.user = { id: p.sub!, hubAdmin: !!p.hub_admin };
    next();
  } catch {
    next(new AxelError('UNAUTHENTICATED', 401, 'Your session expired. Log in again.'));
  }
};

export const requireHubAdmin: RequestHandler = (req, _res, next) =>
  next(req.user?.hubAdmin ? undefined : new AxelError('FORBIDDEN', 403, 'Only hub admins can do this.'));

export const authRouter = Router();

// Step 1: email + password (bcrypt). If OTP is required, send a code through MiniMoth.
authRouter.post('/login', ah(async (req, res) => {
  const { email, password } = z.object({ email: z.string().email(), password: z.string().min(1) }).parse(req.body);
  const u = (await pool.query('SELECT * FROM users WHERE email = $1', [email])).rows[0];
  const ok = await bcrypt.compare(password, u?.password_hash ?? '$2a$12$invalidinvalidinvalidinvalidinvalidinvalidinvalidinv');
  if (!u || !ok) throw new AxelError('UNAUTHENTICATED', 401, 'Email or password is wrong.');
  if (!otpRequiredFor(u)) return res.json(await issue(u, ['pwd']));
  if (!u.phone) throw new AxelError('OTP_PHONE_MISSING', 400, 'This account has no mobile number for the one-time code. Ask an admin to add one.');
  await sendOtp(u.phone);
  const challenge = jwt.sign({ purpose: 'otp' }, CHALLENGE_SECRET, { subject: u.id, expiresIn: '10m' });
  res.json({ otpRequired: true, challenge, phoneHint: maskPhone(u.phone), mode: otpMode() });
}));

async function challengeUser(challenge: string) {
  let p: jwt.JwtPayload;
  try { p = jwt.verify(challenge, CHALLENGE_SECRET) as jwt.JwtPayload; }
  catch { throw new AxelError('UNAUTHENTICATED', 401, 'This sign-in attempt expired. Enter your password again.'); }
  const u = (await pool.query('SELECT * FROM users WHERE id = $1', [p.sub])).rows[0];
  if (!u?.phone) throw new AxelError('UNAUTHENTICATED', 401, 'This sign-in attempt is no longer valid.');
  return u;
}

// Step 2: the code the user received. MiniMoth verifies it; Axel issues the session JWT.
authRouter.post('/verify-otp', ah(async (req, res) => {
  const b = z.object({ challenge: z.string().min(10), code: z.string().trim().regex(/^\d{6}$/, 'Enter the 6-digit code') }).parse(req.body);
  const u = await challengeUser(b.challenge);
  await verifyOtp(u.phone, b.code);
  res.json(await issue(u, ['pwd', 'otp']));
}));

authRouter.post('/resend-otp', ah(async (req, res) => {
  const b = z.object({ challenge: z.string().min(10) }).parse(req.body);
  const u = await challengeUser(b.challenge);
  await sendOtp(u.phone);
  res.json({ ok: true, phoneHint: maskPhone(u.phone) });
}));

authRouter.post('/refresh', requireAuth, ah(async (req, res) => {
  const u = (await pool.query('SELECT * FROM users WHERE id = $1', [req.user!.id])).rows[0];
  if (!u) throw new AxelError('UNAUTHENTICATED', 401, 'Account no longer exists.');
  res.json({ token: (await issue(u, ['refresh'])).token });
}));
'@

Patch 'apps/api/src/server.ts' @'
import { startJobs } from './jobs';
'@ @'
import { startJobs } from './jobs';
import { otpMode } from './minimoth';
'@

Patch 'apps/api/src/server.ts' @'
await startPublishListener();
'@ @'
console.log(`OTP login (MiniMoth): ${otpMode()}; required for: ${otpMode() === 'off' ? 'nobody (set MINIMOTH_API_KEY in .env)' : process.env.OTP_REQUIRED ?? 'all'}`);
await startPublishListener();
'@

Patch 'apps/api/src/members.ts' @'
    name: z.string().min(2).max(80).optional(), password: z.string().min(8).max(100).optional(),
'@ @'
    name: z.string().min(2).max(80).optional(), password: z.string().min(8).max(100).optional(),
    phone: z.string().trim().regex(/^(\+91)?[6-9]\d{9}$/, 'Use an Indian mobile number, e.g. 9876543210').optional(),
'@

Patch 'apps/api/src/members.ts' @'
    user = (await pool.query('INSERT INTO users (email, password_hash, name) VALUES ($1,$2,$3) RETURNING id, name, email',
      [b.email, await bcrypt.hash(b.password, 12), b.name])).rows[0];
'@ @'
    user = (await pool.query('INSERT INTO users (email, password_hash, name, phone) VALUES ($1,$2,$3,$4) RETURNING id, name, email',
      [b.email, await bcrypt.hash(b.password, 12), b.name, b.phone ? (b.phone.startsWith('+91') ? b.phone : `+91${b.phone}`) : null])).rows[0];
'@

# ============================== tests: complete the OTP step with the test code ==============================
W 'apps/api/test/otp.ts' @'
const API = process.env.API_URL ?? 'http://localhost:4000/api';

// Finishes a login: returns the session token, completing the MiniMoth OTP step if the server asks for it.
// Tests must run with a mm_test_ key, where the code is always 000000 (override with TEST_OTP_CODE).
export async function finishLogin(r: Response): Promise<string> {
  const body: any = await r.json();
  if (body.token) return body.token;
  if (!body.otpRequired) throw new Error(`login failed: ${JSON.stringify(body)}`);
  const v = await fetch(`${API}/auth/verify-otp`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ challenge: body.challenge, code: process.env.TEST_OTP_CODE ?? '000000' }),
  });
  const vb: any = await v.json();
  if (!vb.token) throw new Error(`OTP step failed (run tests with a mm_test_ key): ${JSON.stringify(vb)}`);
  return vb.token;
}
'@

Get-ChildItem (Join-Path $PSScriptRoot 'apps/api/test') -Filter '*.test.ts' | ForEach-Object {
  $t = [System.IO.File]::ReadAllText($_.FullName).Replace("`r`n", "`n")
  if ($t.Contains('finishLogin')) { Write-Host "already patched $($_.Name)"; return }
  $t = $t.Replace("import assert from 'node:assert/strict';", "import assert from 'node:assert/strict';`nimport { finishLogin } from './otp';")
  $t = $t.Replace('(await r.json()).token', '(await finishLogin(r))')
  [System.IO.File]::WriteAllText($_.FullName, $t, (New-Object System.Text.UTF8Encoding $false))
  Write-Host "patched $($_.Name)"
}

# ============================== web ==============================
W 'apps/web/src/pages/Login.tsx' @'
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
'@

Patch 'apps/web/src/builder/PeoplePanel.tsx' @'
  const [password, setPassword] = useState('');
'@ @'
  const [password, setPassword] = useState('');
  const [phone, setPhone] = useState('');
'@

Patch 'apps/web/src/builder/PeoplePanel.tsx' @'
{ email, role, ...(needsAccount ? { name, password } : {}) }
'@ @'
{ email, role, ...(needsAccount ? { name, password, ...(phone ? { phone } : {}) } : {}) }
'@

Patch 'apps/web/src/builder/PeoplePanel.tsx' @'
            <input value={password} onChange={e => setPassword(e.target.value)} placeholder="Starting password (8+)" type="password" className="rounded border px-2 py-1" />
'@ @'
            <input value={password} onChange={e => setPassword(e.target.value)} placeholder="Starting password (8+)" type="password" className="rounded border px-2 py-1" />
            <input value={phone} onChange={e => setPhone(e.target.value)} placeholder="Mobile for the login code, e.g. 9876543210" className="col-span-2 rounded border px-2 py-1" />
'@

# ============================== docs ==============================
Patch 'README.md' @'
## How Axel compares
'@ @'
## Login: password + one-time code (MiniMoth)

- **Step 1:** email and password, checked with bcrypt.
- **Step 2:** Axel asks [MiniMoth](https://minimoth.dev) to send a 6-digit code (WhatsApp first, SMS fallback); the user enters it and MiniMoth verifies it.
- **Then** Axel issues its session JWT carrying the user's **roles and allowed sites** (`sites: [{ slug, role }]`, `amr: ["pwd", "otp"]`). The server still re-reads the role from the database on every request, so a demotion applies on the very next click.
- The OTP challenge is signed with a different key from the session, so it can never be used as a login token.
- Keys live only in `.env` (`MINIMOTH_API_KEY`, never committed). `OTP_REQUIRED=all | admins | off`. With a `mm_test_` key nothing is sent and the code is `000000`.

## How Axel compares
'@

Patch 'docs/API.md' @'
| POST | `/api/auth/refresh` | signed in | new token |
'@ @'
| POST | `/api/auth/verify-otp` | anyone | `{ challenge, code }` after a login that returned `otpRequired`; MiniMoth verifies the code, then `{ token, user, memberships }` |
| POST | `/api/auth/resend-otp` | anyone | `{ challenge }` sends a new code |
| POST | `/api/auth/refresh` | signed in | new token |
'@

Write-Host ''
Write-Host 'MiniMoth OTP added. Next: pnpm migrate, pnpm set-phone, .\start.ps1, pnpm test'