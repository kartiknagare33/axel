import { Router } from 'express';
import { canRead } from '@axel/compiler';
import { withSite } from './db';
import { TABLES, toRecord } from './entities';
import { AxelError, ah, notFound } from './errors';

export const analytics = Router({ mergeParams: true });

// GET /api/:siteId/analytics/:widgetId - aggregates respect page visibility and column masks
analytics.get('/analytics/:widgetId', ah(async (req, res) => {
  const { compiled, role, ctx, name } = req.site!;
  const widget = compiled.renderSchema(role).pages.flatMap(p => p.widgets ?? []).find(w => w.id === req.params.widgetId);
  if (!widget) throw notFound();
  const ent = compiled.blueprint.entities[widget.entity];
  const spec = TABLES[widget.entity];
  if (!ent || !spec) throw notFound();

  for (const k of [widget.field, widget.by]) {
    if (!k || k === 'state' || k === 'month') continue;
    const f = ent.fields.find(x => x.key === k);
    if (!f || !canRead(f, role))
      throw new AxelError('FIELD_HIDDEN', 403,
        `You can't see ${f?.label ?? k} in ${name}${f?.reason ? ` (${f.reason})` : ''}. Ask a Manager.`,
        { because: { kind: 'mask', ref: k, reason: f?.reason ?? null } });
  }

  const rows = await withSite(ctx, async c => (await c.query(`SELECT * FROM ${spec.table} ORDER BY created_at LIMIT 5000`)).rows);
  const groups = new Map<string, number[]>();
  for (const row of rows) {
    const rec = compiled.computeFormulas(widget.entity, toRecord(widget.entity, row));
    const key = widget.by === 'month'
      ? new Date(rec.created_at as string).toISOString().slice(0, 7)
      : widget.by ? String(rec[widget.by] ?? 'none') : 'all';
    const v = widget.field ? Number(rec[widget.field] ?? 0) : 1;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(Number.isFinite(v) ? v : 0);
  }
  const sum = (vs: number[]) => vs.reduce((a, b) => a + b, 0);
  const agg = (vs: number[]) => widget.measure === 'count' ? vs.length : widget.measure === 'sum' ? sum(vs) : sum(vs) / (vs.length || 1);
  const data = [...groups].map(([key, vs]) => ({ key, value: Math.round(agg(vs) * 100) / 100 }));
  if (widget.by === 'month') data.sort((a, b) => a.key.localeCompare(b.key));
  res.json({ widget, data });
}));
