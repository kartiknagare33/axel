import pg from 'pg';
import type { Role } from '@axel/compiler';

pg.types.setTypeParser(1700, v => (v === null ? null : parseFloat(v)));

export const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL_APP, max: 20 });
export type Tx = pg.PoolClient;
export interface SiteCtx { siteId: string; userId: string; role: Role | ''; versionId?: string }

async function inTx<T>(setup: (c: Tx) => Promise<unknown>, fn: (c: Tx) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await setup(c);
    const r = await fn(c);
    await c.query('COMMIT');
    return r;
  } catch (e) {
    await c.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

// Every site-scoped query runs here. Context is transaction-local, so pooled connections never carry a stale site.
export const withSite = <T>(ctx: SiteCtx, fn: (c: Tx) => Promise<T>) =>
  inTx(c => c.query(
    `SELECT set_config('app.site_id',$1,true), set_config('app.user_id',$2,true), set_config('app.role',$3,true)`,
    [ctx.siteId, ctx.userId, ctx.role],
  ), fn);

// Hub-level context: no site, only the user (lets a user read their own memberships).
export const withUser = <T>(userId: string, fn: (c: Tx) => Promise<T>) =>
  inTx(c => c.query(`SELECT set_config('app.user_id',$1,true)`, [userId]), fn);

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
