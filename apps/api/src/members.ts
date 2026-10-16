import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { pool, withSite, UUID } from './db';
import { AxelError, ah, notFound } from './errors';

// Mounted at /api/sites/:siteId (Admin only). User management for the Hub layer.
export const membersRouter = Router({ mergeParams: true });
const ROLE = z.enum(['Public', 'Member', 'Manager', 'Admin']);

membersRouter.get('/members', ah(async (req, res) => {
  const rows = await withSite(req.site!.ctx, async c => (await c.query(
    `SELECT m.user_id, m.role, u.email, u.name FROM memberships m JOIN users u ON u.id = m.user_id
      WHERE m.site_id = $1 ORDER BY u.name`, [req.site!.siteId])).rows);
  res.json(rows);
}));

membersRouter.post('/members', ah(async (req, res) => {
  const b = z.object({
    email: z.string().email(), role: ROLE,
    name: z.string().min(2).max(80).optional(), password: z.string().min(8).max(100).optional(),
  }).parse(req.body);
  let user = (await pool.query('SELECT id, name, email FROM users WHERE email = $1', [b.email])).rows[0];
  if (!user) {
    if (!b.name || !b.password)
      throw new AxelError('VALIDATION_FAILED', 422, 'This email has no account yet. Give a name and a starting password (8+ characters) to create one.', { needsAccount: true });
    user = (await pool.query('INSERT INTO users (email, password_hash, name) VALUES ($1,$2,$3) RETURNING id, name, email',
      [b.email, await bcrypt.hash(b.password, 12), b.name])).rows[0];
  }
  await withSite(req.site!.ctx, async c => {
    const r = await c.query('INSERT INTO memberships (site_id, user_id, role) VALUES ($1,$2,$3) ON CONFLICT (site_id, user_id) DO NOTHING RETURNING id',
      [req.site!.siteId, user.id, b.role]);
    if (!r.rowCount) throw new AxelError('DUPLICATE', 409, `${user.email} is already a member of ${req.site!.name}.`);
  });
  res.status(201).json({ user_id: user.id, email: user.email, name: user.name, role: b.role });
}));

membersRouter.patch('/members/:userId', ah(async (req, res) => {
  if (!UUID.test(req.params.userId)) throw notFound();
  const { role } = z.object({ role: ROLE }).parse(req.body);
  if (req.params.userId === req.site!.ctx.userId) throw new AxelError('FORBIDDEN', 403, 'You cannot change your own role. Ask another Admin.');
  const row = await withSite(req.site!.ctx, async c => (await c.query(
    'UPDATE memberships SET role = $2 WHERE site_id = $3 AND user_id = $1 RETURNING user_id, role', [req.params.userId, role, req.site!.siteId])).rows[0]);
  if (!row) throw notFound();
  res.json(row);
}));

membersRouter.delete('/members/:userId', ah(async (req, res) => {
  if (!UUID.test(req.params.userId)) throw notFound();
  if (req.params.userId === req.site!.ctx.userId) throw new AxelError('FORBIDDEN', 403, 'You cannot remove yourself. Ask another Admin.');
  const n = await withSite(req.site!.ctx, async c => (await c.query(
    'DELETE FROM memberships WHERE site_id = $2 AND user_id = $1', [req.params.userId, req.site!.siteId])).rowCount);
  if (!n) throw notFound();
  res.json({ ok: true });
}));
