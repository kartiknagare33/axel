import pg from 'pg';
const c = new pg.Client({ connectionString: process.env.DATABASE_URL_APP });
await c.connect();
const sites = (await c.query('SELECT id, name FROM sites ORDER BY name')).rows;
for (const s of sites) {
  try {
    await c.query('BEGIN');
    await c.query("SELECT set_config('app.site_id', $1, true)", [s.id]);
    await c.query("DELETE FROM law_runs WHERE version_id IN (SELECT id FROM site_versions WHERE status = 'draft')");
    const r = await c.query("DELETE FROM site_versions WHERE status = 'draft'");
    await c.query('COMMIT');
    console.log(`${s.name}: removed ${r.rowCount} old draft(s)`);
  } catch (e) {
    await c.query('ROLLBACK');
    console.log(`${s.name}: could not clean - ${(e as Error).message}`);
  }
}
await c.end();
