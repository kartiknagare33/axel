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
