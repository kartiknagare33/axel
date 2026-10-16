import pg from 'pg';

// pnpm set-phone                           -> give every account without a number a placeholder (admin: DEMO_ADMIN_PHONE)
// pnpm set-phone admin@axel.dev 98xxxxxxxx -> set one account's real mobile number
const norm = (p: string) => (p.startsWith('+') ? p : `+91${p}`).replace(/[\s-]/g, '');
const [email, phoneArg] = process.argv.slice(2);
const c = new pg.Client({ connectionString: process.env.DATABASE_URL_APP });
await c.connect();
if (email && phoneArg) {
  const phone = norm(phoneArg);
  if (!/^\+91[6-9]\d{9}$/.test(phone)) { console.error('Use an Indian mobile number, e.g. 9876543210 or +919876543210'); process.exit(1); }
  const r = await c.query('UPDATE users SET phone = $2 WHERE email = $1 RETURNING email', [email, phone]);
  console.log(r.rowCount ? `${email} -> ${phone}` : `No account with email ${email}`);
}
const missing = (await c.query('SELECT id, email, is_hub_admin FROM users WHERE phone IS NULL ORDER BY created_at')).rows;
let n = 0;
for (const u of missing) {
  n++;
  const p = u.is_hub_admin && process.env.DEMO_ADMIN_PHONE ? norm(process.env.DEMO_ADMIN_PHONE) : `+919000000${String(100 + n)}`;
  await c.query('UPDATE users SET phone = $2 WHERE id = $1', [u.id, p]);
  console.log(`${u.email} -> ${p}`);
}
if (!missing.length && !(email && phoneArg)) console.log('Every account already has a phone number.');
await c.end();
