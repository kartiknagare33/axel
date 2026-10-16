import type { RequestHandler } from 'express';
import { compile, type Blueprint, type Role } from '@axel/compiler';
import { withSite, UUID, type SiteCtx } from './db';
import { getPublished, type Loaded } from './blueprints';
import { AxelError, ah, notFound } from './errors';

export interface SiteReq extends Loaded { role: Role; ctx: SiteCtx; preview?: boolean }

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

  let loaded = await getPublished(siteId);
  if (!loaded) throw notFound();

  // Preview: an Admin may read the site through a draft Blueprint. Writes are refused.
  const previewId = req.header('x-preview-version');
  if (previewId) {
    if (role !== 'Admin') throw new AxelError('PREVIEW_ADMIN_ONLY', 403, 'Only Admins can preview a draft.');
    if (!isRead) throw new AxelError('PREVIEW_READ_ONLY', 403, 'Preview is read-only. Nothing here is saved.');
    if (!UUID.test(previewId)) throw notFound();
    const cfg = await withSite({ siteId, userId, role }, async c =>
      (await c.query('SELECT config FROM site_versions WHERE id = $1', [previewId])).rows[0]?.config);
    if (!cfg) throw notFound();
    loaded = { ...loaded, versionId: previewId, compiled: compile({ ...cfg, siteId, slug: loaded.slug } as Blueprint) };
  }

  req.site = { ...loaded, role, preview: !!previewId, ctx: { siteId, userId, role, versionId: loaded.versionId } };
  next();
});

export const requireRole = (min: Role): RequestHandler => (req, _res, next) => {
  const rank = { Public: 0, Member: 1, Manager: 2, Admin: 3 };
  next(rank[req.site!.role] >= rank[min] ? undefined
    : new AxelError('FORBIDDEN', 403, `Only ${min}s can do this in ${req.site!.name}.`));
};
