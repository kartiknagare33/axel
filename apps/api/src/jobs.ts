import { pool, withSite } from './db';
import { getPublished } from './blueprints';
import * as ledger from './ledger';

// Every 10 s: release expired reservations and send their requests back for re-approval.
export function startJobs() {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      const sites = (await pool.query('SELECT id FROM sites')).rows;
      for (const s of sites) {
        const loaded = await getPublished(s.id);
        if (!loaded) continue;
        const ctx = { siteId: s.id, userId: '', role: 'Admin' as const, versionId: loaded.versionId };
        const reserveT = loaded.compiled.blueprint.workflows.request?.transitions.find(t => t.actions?.some(a => a.startsWith('stock.reserve')));
        const expired = await withSite(ctx, async tx => (await tx.query(
          `SELECT id, ref_id FROM stock_movements
            WHERE kind = 'reserve' AND consumed_by IS NULL AND expires_at < now() ORDER BY id LIMIT 100`)).rows);
        for (const r of expired) {
          await withSite(ctx, async tx => {
            if (r.ref_id) await tx.query('SELECT id FROM requests WHERE id = $1 FOR UPDATE', [r.ref_id]); // same lock order as transitions
            const done = await ledger.expireOne(tx, ctx, r.id);
            if (!done || !r.ref_id) return;
            const back = reserveT ? (await tx.query(
              `UPDATE requests SET state = $2, row_version = row_version + 1, updated_at = now() WHERE id = $1 AND state = $3 RETURNING id`,
              [r.ref_id, reserveT.from, reserveT.to])).rowCount : 0;
            await tx.query(
              `INSERT INTO audit_events (site_id, entity, record_id, kind, from_state, to_state, actor_role, after, version_id)
               VALUES ($1,'request',$2,'reservation_expired',$3,$4,'system',$5,$6)`,
              [ctx.siteId, r.ref_id, reserveT?.to ?? null, back ? reserveT!.from : null, { released: done.qty }, ctx.versionId]);
          });
        }
      }
    } catch (e) {
      console.error('expiry job', e);
    } finally {
      running = false;
    }
  };
  setInterval(tick, 10_000);
}
