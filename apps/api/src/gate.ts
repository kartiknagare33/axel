import { Router } from 'express';
import { z } from 'zod';
import { withSite, UUID } from './db';
import { ah, notFound } from './errors';
import { hashBlueprint } from './sites';
import { runGate } from './laws';

// Mounted at /api/sites/:siteId (Admin only).
export const gateRouter = Router({ mergeParams: true });

gateRouter.post('/versions/:v/gate', ah(async (req, res) => {
  if (!UUID.test(req.params.v)) throw notFound();
  const b = z.object({ steps: z.number().int().min(20).max(3000).default(300), seed: z.number().int().optional() }).parse(req.body ?? {});
  const s = req.site!;
  const v = await withSite(s.ctx, async c => (await c.query('SELECT id, config FROM site_versions WHERE id = $1', [req.params.v])).rows[0]);
  if (!v) throw notFound();
  const bp = { ...v.config, siteId: s.siteId, slug: s.slug };
  const report = await runGate(s.siteId, s.ctx.userId, v.id, bp, { steps: b.steps, seed: b.seed });
  const hash = hashBlueprint(bp);
  await withSite(s.ctx, c => c.query(
    `INSERT INTO law_runs (site_id, version_id, seed, steps, passed, failures, duration_ms, content_hash, report)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
    [s.siteId, v.id, report.seed, report.steps, report.passed, JSON.stringify(report.laws.filter(l => !l.passed)), report.durationMs, hash, report]));
  res.json({ ...report, versionHash: hash });
}));
