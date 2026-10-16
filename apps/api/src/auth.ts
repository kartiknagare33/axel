import { Router, type RequestHandler } from 'express';
import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { pool, withUser } from './db';
import { AxelError, ah } from './errors';
import type { SiteReq } from './site';

export interface AuthUser { id: string; hubAdmin: boolean }
declare global {
  namespace Express { interface Request { user?: AuthUser; site?: SiteReq } }
}

const SECRET = process.env.JWT_SECRET!;
if (!SECRET || SECRET.length < 32) throw new Error('JWT_SECRET must be at least 32 chars');

export const sign = (u: { id: string; is_hub_admin: boolean }) =>
  jwt.sign({ hub_admin: u.is_hub_admin }, SECRET, { subject: u.id, expiresIn: process.env.JWT_TTL ?? '12h' } as jwt.SignOptions);

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

export const memberships = (userId: string) =>
  withUser(userId, async c => (await c.query(
    `SELECT m.site_id, m.role, s.slug, s.name FROM memberships m JOIN sites s ON s.id = m.site_id
     WHERE m.user_id = $1 ORDER BY s.name`, [userId])).rows);

export const authRouter = Router();

authRouter.post('/login', ah(async (req, res) => {
  const { email, password } = z.object({ email: z.string().email(), password: z.string().min(1) }).parse(req.body);
  const u = (await pool.query('SELECT * FROM users WHERE email = $1', [email])).rows[0];
  const ok = await bcrypt.compare(password, u?.password_hash ?? '$2a$12$invalidinvalidinvalidinvalidinvalidinvalidinvalidinv');
  if (!u || !ok) throw new AxelError('UNAUTHENTICATED', 401, 'Email or password is wrong.');
  res.json({
    token: sign(u),
    user: { id: u.id, email: u.email, name: u.name, hubAdmin: u.is_hub_admin },
    memberships: await memberships(u.id),
  });
}));

authRouter.post('/refresh', requireAuth, ah(async (req, res) => {
  const u = (await pool.query('SELECT id, is_hub_admin FROM users WHERE id = $1', [req.user!.id])).rows[0];
  if (!u) throw new AxelError('UNAUTHENTICATED', 401, 'Account no longer exists.');
  res.json({ token: sign(u) });
}));
