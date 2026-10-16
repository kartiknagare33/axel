import pg from 'pg';
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'migrations');
const c = new pg.Client({ connectionString: process.env.DATABASE_URL_OWNER });
await c.connect();
await c.query('CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz DEFAULT now())');
const done = new Set((await c.query('SELECT name FROM schema_migrations')).rows.map(r => r.name));
for (const f of (await readdir(dir)).filter(f => f.endsWith('.sql')).sort()) {
  if (done.has(f)) continue;
  const sql = await readFile(path.join(dir, f), 'utf8');
  try {
    await c.query('BEGIN');
    await c.query(sql);
    await c.query('INSERT INTO schema_migrations (name) VALUES ($1)', [f]);
    await c.query('COMMIT');
    console.log(`applied ${f}`);
  } catch (e) {
    await c.query('ROLLBACK');
    console.error(`failed ${f}`, e);
    process.exit(1);
  }
}
await c.end();
