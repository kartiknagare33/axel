import { Router } from 'express';
import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod';
import { compile, canonicalJson, PRESETS, type Blueprint } from '@axel/compiler';
import { withSite, withUser } from './db';
import { getPublished } from './blueprints';
import { requireAuth, requireHubAdmin } from './auth';
import { siteScope } from './site';
import { AxelError, ah } from './errors';
import { starterBlueprint } from './starter';

export const sitesRouter = Router();
export const hashBlueprint = (bp: Blueprint) => 'sha256:' + createHash('sha256').update(canonicalJson(bp)).digest('hex');

sitesRouter.get('/', requireAuth, ah(async (req, res) => {
  const mine = await withUser(req.user!.id, async c => (await c.query(
    `SELECT s.id, s.slug, s.name, m.role FROM memberships m JOIN sites s ON s.id = m.site_id
     WHERE m.user_id = $1 AND s.slug <> 'hub' ORDER BY s.name`, [req.user!.id])).rows);
  const out = await Promise.all(mine.map(async s => {
    const p = await getPublished(s.id);
    const bp = p?.compiled.blueprint;
    return { ...s, versionId: p?.versionId, theme: bp && { primary: bp.theme.tokens.primary, layout: bp.theme.layout }, modules: bp?.modules ?? [] };
  }));
  res.json(out);
}));

sitesRouter.post('/', requireAuth, requireHubAdmin, ah(async (req, res) => {
  const b = z.object({
    name: z.string().min(2).max(60),
    slug: z.string().regex(/^[a-z0-9][a-z0-9-]{1,40}$/),
    blueprint: z.any().optional(),
    preset: z.enum(['inventory-starter', 'approval-chain', 'repair-shop']).optional(),
    reason: z.string().max(200).optional(),
  }).parse(req.body);
  const siteId = randomUUID();
  const bp: Blueprint = { ...(b.blueprint ?? (b.preset ? PRESETS[b.preset].build() : starterBlueprint())), siteId, slug: b.slug, name: b.name };
  const compiled = compile(bp);
  if (!compiled.ok) throw new AxelError('VALIDATION_FAILED', 422, 'The blueprint has problems.', { diagnostics: compiled.diagnostics });

  const userId = req.user!.id;
  const result = await withSite({ siteId, userId, role: 'Admin' }, async c => {
    await c.query('INSERT INTO sites (id, slug, name, created_by) VALUES ($1,$2,$3,$4)', [siteId, b.slug, b.name, userId]);
    await c.query(`INSERT INTO memberships (site_id, user_id, role) VALUES ($1,$2,'Admin')`, [siteId, userId]);
    const v = (await c.query(
      `INSERT INTO site_versions (site_id, config, content_hash, status, author_id, reason)
       VALUES ($1,$2,$3,'published',$4,$5) RETURNING id`,
      [siteId, bp, hashBlueprint(bp), userId, b.reason ?? 'site created'])).rows[0];
    await c.query(
      `INSERT INTO site_deployments (site_id, version_id, proof, deployed_by) VALUES ($1,$2,$3,$4)`,
      [siteId, v.id, { versionHash: hashBlueprint(bp), compiledAt: new Date().toISOString(), note: 'initial publish' }, userId]);
    await c.query('UPDATE sites SET published_version_id = $2 WHERE id = $1', [siteId, v.id]);
    await c.query(`SELECT pg_notify('site_published', $1)`, [`${siteId}:${v.id}`]);
    return { id: siteId, slug: b.slug, name: b.name, versionId: v.id };
  });
  res.status(201).json(result);
}));

sitesRouter.get('/:siteId/render-schema', requireAuth, siteScope, (req, res) => {
  const { compiled, role, versionId } = req.site!;
  res.json({ versionId, ...compiled.renderSchema(role) });
});
