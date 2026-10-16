import { Router } from 'express';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { compile, type Blueprint } from '@axel/compiler';
import { withSite, UUID, type Tx } from './db';
import { TABLES } from './entities';
import { AxelError, ah, notFound } from './errors';
import { hashBlueprint } from './sites';
import { invalidate } from './blueprints';
import { runGate } from './laws';
import { impactReport } from './impact';

// Mounted at /api/sites/:siteId with requireAuth, siteScope, requireRole('Admin').
export const versionsRouter = Router({ mergeParams: true });

const pin = (req: any, config: any): Blueprint => ({ ...config, siteId: req.site.siteId, slug: req.site.slug });
const Config = z.object({
  configVersion: z.literal(3), modules: z.array(z.string()), entities: z.record(z.any()), workflows: z.record(z.any()),
  pages: z.array(z.any()), nav: z.array(z.any()), roles: z.array(z.string()), laws: z.array(z.any()), theme: z.any(),
}).passthrough();

function summarize(a: Blueprint, b: Blueprint) {
  const c: string[] = [];
  for (const m of b.modules) if (!a.modules.includes(m)) c.push(`+ module ${m}`);
  for (const m of a.modules) if (!b.modules.includes(m)) c.push(`- module ${m}`);
  for (const [ek, e] of Object.entries(b.entities)) {
    const old = a.entities[ek];
    if (!old) { c.push(`+ entity ${ek}`); continue; }
    for (const f of e.fields) if (!old.fields.some(x => x.key === f.key)) c.push(`+ field ${ek}.${f.key}`);
    for (const f of old.fields) if (!e.fields.some(x => x.key === f.key)) c.push(`- field ${ek}.${f.key} (data kept)`);
  }
  for (const ek of Object.keys(a.entities)) if (!b.entities[ek]) c.push(`- entity ${ek} (data kept)`);
  for (const [ek, wf] of Object.entries(b.workflows)) {
    const o = a.workflows[ek];
    for (const s of wf.states) if (!o?.states.includes(s)) c.push(`+ state ${ek}.${s}`);
    for (const s of o?.states ?? []) if (!wf.states.includes(s)) c.push(`- state ${ek}.${s}`);
  }
  for (const p of b.pages) if (!a.pages.some(x => x.path === p.path)) c.push(`+ page ${p.path}`);
  for (const p of a.pages) if (!b.pages.some(x => x.path === p.path)) c.push(`- page ${p.path}`);
  if (a.theme?.layout !== b.theme?.layout) c.push(`~ layout ${a.theme?.layout} to ${b.theme?.layout}`);
  if (a.theme?.tokens?.primary !== b.theme?.tokens?.primary) c.push('~ colours');
  return c;
}

async function stranded(c: Tx, a: Blueprint, b: Blueprint) {
  const out: string[] = [];
  for (const [ek, wf] of Object.entries(a.workflows ?? {})) {
    const removed = wf.states.filter(s => !b.workflows?.[ek]?.states.includes(s));
    const spec = TABLES[ek];
    if (!removed.length || !spec) continue;
    const rows = (await c.query(`SELECT state, count(*)::int AS n FROM ${spec.table} WHERE state = ANY($1) GROUP BY state`, [removed])).rows;
    for (const r of rows) out.push(`${r.n} ${ek} record(s) are in '${r.state}', which this version removes. They stay read-only and their data is kept.`);
  }
  return out;
}

async function deploy(req: any, c: Tx, targetId: string, o: { rollback: boolean; confirm: boolean; reason?: string; gate?: any; plans?: Record<string, string>; replay?: any }) {
  const s = req.site;
  const cur = (await c.query(
    `SELECT v.id, v.config FROM sites st JOIN site_versions v ON v.id = st.published_version_id WHERE st.id = $1 FOR UPDATE OF st`,
    [s.siteId])).rows[0];
  const v = (await c.query('SELECT id, config, status FROM site_versions WHERE id = $1 FOR UPDATE', [targetId])).rows[0];
  if (!v) throw notFound();
  if (cur && cur.id === v.id) throw new AxelError('ALREADY_LIVE', 409, 'That version is already live.');
  if (o.rollback && v.status === 'draft') throw new AxelError('VALIDATION_FAILED', 422, 'Only previously published versions can be rolled back to.');
  if (!o.rollback && v.status !== 'draft') throw new AxelError('VALIDATION_FAILED', 422, 'Publish a draft, or use rollback for an older version.');

  const bp = pin(req, v.config);
  const compiled = compile(bp);
  const errors = compiled.diagnostics.filter(d => d.severity === 'error');
  if (errors.length) throw new AxelError('GATE_NOT_PASSED', 422, `Fix ${errors.length} problem(s) first: ${errors[0].message}`, { diagnostics: errors });
  let gateProof: any = o.gate ?? null;
  if (!o.rollback) {
    const g = (await c.query(
      'SELECT passed, seed, steps, duration_ms FROM law_runs WHERE version_id = $1 AND content_hash = $2 ORDER BY ran_at DESC LIMIT 1',
      [v.id, hashBlueprint(bp)])).rows[0];
    if (!g?.passed) throw new AxelError('GATE_NOT_PASSED', 422, g
      ? 'The last Release Gate run on this draft failed. Fix the problem and run the gate again.'
      : 'Run the Release Gate on this draft before publishing.');
    gateProof = { passed: true, steps: g.steps, seed: Number(g.seed), durationMs: g.duration_ms };
  }

  const changes = cur ? summarize(cur.config, bp) : [];
  const impact = cur ? await impactReport(c, cur.config, bp) : [];
  const strandedStates = impact.filter(i => i.kind === 'state_removed' && (i.count ?? 0) > 0);
  const unplanned = strandedStates.filter(i => !o.plans?.[`${i.entity}.${i.state}`] && !o.confirm);
  if (unplanned.length)
    throw new AxelError('DESTRUCTIVE_CHANGE_UNPLANNED', 409, `${unplanned.map(i => i.detail).join(' ')} Choose a plan for each in the Impact list.`, { impact, changes });
  const destructive: string[] = [];
  const planned: Record<string, string> = {};
  for (const i of strandedStates) {
    const key = `${i.entity}.${i.state}`;
    const p = o.plans?.[key] ?? 'keep';
    planned[key] = p;
    if (p.startsWith('map:')) {
      const target = p.slice(4);
      if (!bp.workflows[i.entity!]?.states.includes(target)) throw new AxelError('VALIDATION_FAILED', 422, `'${target}' is not a state in the version being deployed.`);
      const moved = (await c.query(
        `UPDATE ${TABLES[i.entity!].table} SET state = $2, row_version = row_version + 1, updated_at = now() WHERE state = $1 RETURNING id`,
        [i.state, target])).rows;
      for (const m of moved)
        await c.query(
          `INSERT INTO audit_events (site_id, entity, record_id, kind, from_state, to_state, actor_id, actor_role, after, version_id)
           VALUES ($1,$2,$3,'rollback_map',$4,$5,$6,$7,$8,$9)`,
          [s.siteId, i.entity, m.id, i.state, target, s.ctx.userId, s.role, { plan: p }, v.id]);
      destructive.push(`${moved.length} ${i.entity}(s) moved from '${i.state}' to '${target}'.`);
    } else destructive.push(`${i.count} ${i.entity}(s) stay in '${i.state}' (read-only, data kept).`);
  }

  const hash = hashBlueprint(bp);
  let liveId = v.id as string;
  if (v.status === 'draft') {
    const same = (await c.query('SELECT id FROM site_versions WHERE content_hash = $1 AND id <> $2', [hash, v.id])).rows[0];
    if (same && cur && same.id === cur.id) throw new AxelError('ALREADY_LIVE', 409, 'No changes compared to the live version.');
    if (same) { liveId = same.id; await c.query('DELETE FROM site_versions WHERE id = $1', [v.id]); }
    else await c.query('UPDATE site_versions SET config = $2, content_hash = $3, reason = coalesce($4, reason) WHERE id = $1', [v.id, bp, hash, o.reason ?? null]);
  }
  if (cur) await c.query(`UPDATE site_versions SET status = 'archived' WHERE id = $1`, [cur.id]);
  await c.query(`UPDATE site_versions SET status = 'published' WHERE id = $1`, [liveId]);
  const prev = (await c.query('SELECT id FROM site_deployments ORDER BY deployed_at DESC, id LIMIT 1')).rows[0];
  const proof = {
    versionHash: hash, compiledAt: new Date().toISOString(), errors: 0,
    warnings: compiled.diagnostics.filter(d => d.severity === 'warning').length,
    changes, destructive, dataPreserved: true, kind: o.rollback ? 'rollback' : 'publish', gate: gateProof, plans: planned, replay: o.replay ?? null,
  };
  const dep = (await c.query(
    'INSERT INTO site_deployments (site_id, version_id, proof, deployed_by, rollback_of) VALUES ($1,$2,$3,$4,$5) RETURNING id',
    [s.siteId, liveId, proof, s.ctx.userId, o.rollback ? prev?.id ?? null : null])).rows[0];
  await c.query('UPDATE sites SET published_version_id = $2 WHERE id = $1', [s.siteId, liveId]);
  await c.query(`SELECT pg_notify('site_published', $1)`, [`${s.siteId}:${liveId}`]);
  return { deploymentId: dep.id, versionId: liveId, changes, destructive };
}

versionsRouter.get('/builder', ah(async (req, res) => {
  const s = req.site!;
  const out = await withSite(s.ctx, async c => ({
    published: (await c.query(`SELECT v.id, v.config FROM sites st JOIN site_versions v ON v.id = st.published_version_id WHERE st.id = $1`, [s.siteId])).rows[0],
    draft: (await c.query(`SELECT id, config, updated_rev FROM site_versions WHERE status = 'draft' ORDER BY created_at DESC LIMIT 1`)).rows[0] ?? null,
  }));
  res.json({
    site: { id: s.siteId, slug: s.slug, name: s.name },
    published: { versionId: out.published.id, config: pin(req, out.published.config) },
    draft: out.draft && { id: out.draft.id, rev: out.draft.updated_rev, config: pin(req, out.draft.config) },
  });
}));

versionsRouter.get('/versions', ah(async (req, res) => {
  const rows = await withSite(req.site!.ctx, async c => (await c.query(
    `SELECT v.id, v.status, v.content_hash, v.reason, v.created_at, u.name AS author
       FROM site_versions v LEFT JOIN users u ON u.id = v.author_id ORDER BY v.created_at DESC`)).rows);
  res.json(rows);
}));

versionsRouter.post('/versions', ah(async (req, res) => {
  const b = z.object({ config: Config, reason: z.string().max(200).optional() }).parse(req.body);
  const s = req.site!;
  const bp = pin(req, b.config);
  const row = await withSite(s.ctx, async c => (await c.query(
    `INSERT INTO site_versions (site_id, config, content_hash, parent_id, status, author_id, reason)
     VALUES ($1,$2,$3,$4,'draft',$5,$6) RETURNING id, updated_rev`,
    [s.siteId, bp, `draft:${randomUUID()}`, s.versionId, s.ctx.userId, b.reason ?? 'builder draft'])).rows[0]);
  res.status(201).json({ id: row.id, updated_rev: row.updated_rev, diagnostics: compile(bp).diagnostics });
}));

versionsRouter.put('/versions/:v', ah(async (req, res) => {
  if (!UUID.test(req.params.v)) throw notFound();
  const b = z.object({ config: Config, expectedRev: z.number().int() }).parse(req.body);
  const bp = pin(req, b.config);
  const row = await withSite(req.site!.ctx, async c => {
    const r = (await c.query(
      `UPDATE site_versions SET config = $2, updated_rev = updated_rev + 1
        WHERE id = $1 AND status = 'draft' AND updated_rev = $3 RETURNING updated_rev`, [req.params.v, bp, b.expectedRev])).rows[0];
    if (r) return r;
    const cur = (await c.query('SELECT status, updated_rev FROM site_versions WHERE id = $1', [req.params.v])).rows[0];
    if (!cur) throw notFound();
    if (cur.status !== 'draft') throw new AxelError('VERSION_IMMUTABLE', 409, 'Published versions cannot be edited. Reload to start a new draft.');
    throw new AxelError('DRAFT_CONFLICT', 409, `Someone else saved this draft meanwhile (now revision ${cur.updated_rev}). Load the latest and redo your change.`, { current: cur.updated_rev });
  });
  res.json({ updated_rev: row.updated_rev, diagnostics: compile(bp).diagnostics });
}));

versionsRouter.delete('/versions/:v', ah(async (req, res) => {
  if (!UUID.test(req.params.v)) throw notFound();
  await withSite(req.site!.ctx, c => c.query(`DELETE FROM site_versions WHERE id = $1 AND status = 'draft'`, [req.params.v]));
  res.json({ ok: true });
}));

versionsRouter.post('/publish', ah(async (req, res) => {
  const b = z.object({
    versionId: z.string().uuid(), reason: z.string().max(200).optional(), confirm: z.boolean().default(false),
    plans: z.record(z.string()).optional(), replay: z.record(z.unknown()).optional(),
  }).parse(req.body);
  const r = await withSite(req.site!.ctx, c => deploy(req, c, b.versionId, { rollback: false, confirm: b.confirm, reason: b.reason, plans: b.plans, replay: b.replay }));
  invalidate(req.site!.siteId);
  res.json(r);
}));

versionsRouter.post('/rollback', ah(async (req, res) => {
  const b = z.object({ versionId: z.string().uuid(), confirm: z.boolean().default(false), plans: z.record(z.string()).optional() }).parse(req.body);
  const s = req.site!;
  const target = await withSite(s.ctx, async c => (await c.query('SELECT config FROM site_versions WHERE id = $1', [b.versionId])).rows[0]);
  if (!target) throw notFound();
  const report = await runGate(s.siteId, s.ctx.userId, b.versionId, pin(req, target.config), { steps: 150 });
  if (!report.passed && !b.confirm)
    throw new AxelError('GATE_NOT_PASSED', 422,
      `That older version breaks a Law: ${report.counterExample?.message ?? report.laws.find(l => !l.passed)?.detail ?? report.compileErrors[0] ?? 'see the gate report'}`, { report });
  const gate = { passed: report.passed, steps: report.steps, seed: report.seed, durationMs: report.durationMs };
  const r = await withSite(s.ctx, c => deploy(req, c, b.versionId, { rollback: true, confirm: b.confirm, gate, plans: b.plans }));
  invalidate(req.site!.siteId);
  res.json(r);
}));

versionsRouter.get('/deployments', ah(async (req, res) => {
  const rows = await withSite(req.site!.ctx, async c => (await c.query(
    `SELECT d.id, d.version_id, d.proof, d.deployed_at, d.rollback_of, u.name AS deployed_by_name
       FROM site_deployments d LEFT JOIN users u ON u.id = d.deployed_by ORDER BY d.deployed_at DESC, d.id DESC`)).rows);
  res.json(rows);
}));
