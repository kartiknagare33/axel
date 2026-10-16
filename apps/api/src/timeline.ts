import { Router } from 'express';
import { z } from 'zod';
import { withSite } from './db';
import { TABLES, toRecord } from './entities';
import { AxelError, ah } from './errors';

// GET /api/:siteId/timeline?serial=  - the whole life of one board, inside this unit only, plus its passport.
export const timeline = Router({ mergeParams: true });
const DAY = 86400000;

timeline.get('/timeline', ah(async (req, res) => {
  const serial = z.string().trim().min(1).max(100).parse(req.query.serial);
  const s = req.site!;
  const bp = s.compiled.blueprint;
  const ents = Object.entries(bp.entities).filter(([k, e]) => TABLES[k] && e.fields.some(f => f.key === 'serial_no'));
  if (!ents.length) throw new AxelError('ENTITY_NOT_IN_SITE', 404, 'This unit does not track serial numbers.');
  const out = await withSite(s.ctx, async c => {
    const records: { entity: string; label: string; rec: Record<string, unknown> }[] = [];
    const repairRows: any[] = [];
    for (const [ek, e] of ents) {
      const spec = TABLES[ek];
      const col = spec.core.includes('serial_no') ? 'serial_no' : `data->>'serial_no'`;
      const rows = (await c.query(`SELECT * FROM ${spec.table} WHERE lower(${col}) = lower($1) ORDER BY created_at`, [serial])).rows;
      for (const r of rows) {
        records.push({ entity: ek, label: e.label ?? ek, rec: s.compiled.mask(ek, s.role, s.compiled.computeFormulas(ek, toRecord(ek, r))) });
        if (ek === 'repair') repairRows.push(r);
      }
    }
    const ids = records.map(r => String(r.rec.id));
    const events = ids.length ? (await c.query(
      `SELECT e.entity, e.record_id, e.kind, e.from_state, e.to_state, e.actor_role, e.at, u.name AS actor_name
         FROM audit_events e LEFT JOIN users u ON u.id = e.actor_id WHERE e.record_id = ANY($1) ORDER BY e.at, e.id`, [ids])).rows : [];
    const moves = ids.length ? (await c.query(
      `SELECT m.kind, m.qty, m.reason, m.at, i.name AS item FROM stock_movements m JOIN items i ON i.id = m.item_id
        WHERE m.ref_id = ANY($1) ORDER BY m.id`, [ids])).rows : [];
    return { records, events, moves, repairRows };
  });

  const history = out.repairRows
    .map(r => ({
      request_id: r.request_id, closed_at: r.closed_at, outcome: r.data?.outcome ?? null, reworks: Number(r.data?.reworks ?? 0),
      warranty_until: r.closed_at ? new Date(+new Date(r.closed_at) + Number(r.data?.warranty_days ?? 90) * DAY).toISOString() : null,
      parts: r.data?.parts_replaced ?? null,
    }))
    .sort((a, b) => +new Date(b.closed_at ?? 0) - +new Date(a.closed_at ?? 0));
  const last = history.find(h => h.closed_at);
  const passport = {
    requests: out.records.filter(r => r.entity === 'request').length,
    repairs: history.length,
    reworks: history.reduce((n, h) => n + h.reworks, 0),
    lastClosedAt: last?.closed_at ?? null,
    lastOutcome: last?.outcome ?? null,
    warrantyUntil: last?.warranty_until ?? null,
    underWarranty: !!last?.warranty_until && new Date(last.warranty_until) > new Date(),
    parts: history.map(h => h.parts).filter(Boolean),
    history: history.filter(h => h.closed_at),
  };
  res.json({ serial, records: out.records, events: out.events, moves: out.moves, passport });
}));
