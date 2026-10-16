import type { RequestHandler } from 'express';
import type { Role } from '@axel/compiler';
import { withSite, UUID, type SiteCtx } from './db';
import { getPublished, type Loaded } from './blueprints';
import { AxelError, ah, notFound } from './errors';

export interface SiteReq extends Loaded { role: Role; ctx: SiteCtx }

export const siteScope: RequestHandler = ah(async (req, _res, next) => {
  const siteId = req.params.siteId;
  const isRead = req.method === 'GET';
  if (!UUID.test(siteId)) throw notFound();
  if (req.header('x-site-id') !== siteId)
    throw new AxelError('SITE_HEADER_MISMATCH', 400, 'X-Site-Id must match the site in the URL.');

  const userId = req.user!.id;
  const role = await withSite({ siteId, userId, role: '' }, async c =>
    (await c.query('SELECT role FROM memberships WHERE site_id = $1 AND user_id = $2', [siteId, userId])).rows[0]?.role as Role | undefined);
  if (!role) throw isRead ? notFound() : new AxelError('NO_MEMBERSHIP', 403, 'You are not a member of this site.');

  const loaded = await getPublished(siteId);
  if (!loaded) throw notFound();
  req.site = { ...loaded, role, ctx: { siteId, userId, role, versionId: loaded.versionId } };
  next();
});

export const requireRole = (min: Role): RequestHandler => (req, _res, next) => {
  const rank = { Public: 0, Member: 1, Manager: 2, Admin: 3 };
  next(rank[req.site!.role] >= rank[min] ? undefined
    : new AxelError('TRANSITION_NOT_ALLOWED', 403, `Only ${min}s and above can do this in ${req.site!.name}.`));
};
