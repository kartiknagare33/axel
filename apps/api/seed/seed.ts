import pg from 'pg';
import bcrypt from 'bcryptjs';
import { randomUUID } from 'node:crypto';
import { compile, type Blueprint } from '@axel/compiler';
import { pool, withSite } from '../src/db';
import { hashBlueprint } from '../src/sites';
import { centralStores, serviceCentre, distribution, SITE_IDS } from './blueprints';
import { runLifecycle } from './lifecycle';

const owner = new pg.Client({ connectionString: process.env.DATABASE_URL_OWNER });
await owner.connect();
await owner.query(`TRUNCATE users, sites, memberships, site_versions, site_deployments, recordings, law_runs,
  audit_events, items, stock_movements, requests, approvals, assignments, consumptions, returns, repairs
  RESTART IDENTITY CASCADE`);
await owner.end();

const hash = await bcrypt.hash('demo1234', 12);
let phoneN = 0;
const normPhone = (p: string) => (p.startsWith('+') ? p : `+91${p}`).replace(/[\s-]/g, '');
// Demo accounts get distinct placeholder numbers (fine with a test key). The hub admin can use your real number.
const mk = async (email: string, name: string, hub = false) => {
  phoneN++;
  const phone = hub && process.env.DEMO_ADMIN_PHONE ? normPhone(process.env.DEMO_ADMIN_PHONE) : `+919000000${String(phoneN).padStart(3, '0')}`;
  return (await pool.query('INSERT INTO users (email, password_hash, name, is_hub_admin, phone) VALUES ($1,$2,$3,$4,$5) RETURNING id', [email, hash, name, hub, phone])).rows[0].id as string;
};

const admin = await mk('admin@axel.dev', 'Admin', true);
const people: Record<string, [string, 'Manager' | 'Member'][]> = {
  'central-stores': [[await mk('manager@cs.dev', 'Chetan Manager'), 'Manager'], [await mk('member@cs.dev', 'Meera Member'), 'Member']],
  'service-centre': [[await mk('manager@sc.dev', 'Priya Manager'), 'Manager'], [await mk('member@sc.dev', 'Sahil Member'), 'Member']],
  distribution:     [[await mk('manager@dist.dev', 'Dev Manager'), 'Manager'], [await mk('field@dist.dev', 'Farah Field'), 'Member']],
};

const CATALOGUE: Record<string, [string, string, string, number][]> = {
  'central-stores': [['CS-001', 'Copper wire 2.5mm', 'Electrical', 42], ['CS-002', 'MCB 16A', 'Electrical', 180], ['CS-003', 'Hex bolt M8', 'Mechanical', 4], ['CS-004', 'Bearing 6204', 'Mechanical', 95], ['CS-005', 'Cable ties', 'Consumable', 1], ['CS-006', 'Insulation tape', 'Consumable', 18], ['CS-007', 'Relay 12V', 'Electrical', 65], ['CS-008', 'Gear oil 1L', 'Consumable', 310]],
  'service-centre': [['SC-101', 'Power board PB-4', 'PCB', 2400], ['SC-102', 'Control board CB-2', 'PCB', 3100], ['SC-103', 'Capacitor 470uF', 'Electrical', 12], ['SC-104', 'MOSFET IRF540', 'Electrical', 38], ['SC-105', 'Solder wire', 'Consumable', 220], ['SC-106', 'Display ribbon', 'Electrical', 150]],
  distribution:     [['DS-201', 'Smart meter', 'Electrical', 1850], ['DS-202', 'Service cable 10m', 'Electrical', 640], ['DS-203', 'Meter box', 'Mechanical', 410], ['DS-204', 'Seal kit', 'Consumable', 25], ['DS-205', 'Junction box', 'Mechanical', 120]],
};

const blueprints: Blueprint[] = [centralStores, serviceCentre, distribution];

for (const bp of blueprints) {
  const c = compile(bp);
  if (!c.ok) throw new Error(`${bp.slug}: ${JSON.stringify(c.diagnostics.filter(d => d.severity === 'error'), null, 2)}`);
  const siteId = SITE_IDS[bp.slug as keyof typeof SITE_IDS];
  const ctx = { siteId, userId: admin, role: 'Admin' as const };

  await withSite(ctx, async tx => {
    await tx.query('INSERT INTO sites (id, slug, name, created_by) VALUES ($1,$2,$3,$4)', [siteId, bp.slug, bp.name, admin]);
    const v = (await tx.query(
      `INSERT INTO site_versions (site_id, config, content_hash, status, author_id, reason)
       VALUES ($1,$2,$3,'published',$4,'seeded from register') RETURNING id`,
      [siteId, bp, hashBlueprint(bp), admin])).rows[0].id;
    await tx.query(`INSERT INTO site_deployments (site_id, version_id, proof, deployed_by) VALUES ($1,$2,$3,$4)`,
      [siteId, v, { versionHash: hashBlueprint(bp), seeded: true }, admin]);
    await tx.query('UPDATE sites SET published_version_id = $2 WHERE id = $1', [siteId, v]);

    await tx.query(`INSERT INTO memberships (site_id, user_id, role) VALUES ($1,$2,'Admin')`, [siteId, admin]);
    for (const [uid, role] of people[bp.slug]) await tx.query('INSERT INTO memberships (site_id, user_id, role) VALUES ($1,$2,$3)', [siteId, uid, role]);

    const items: { id: string; price: number }[] = [];
    const rows = [...CATALOGUE[bp.slug], [`MARKER-${bp.slug}`, `MARKER-${bp.slug}`, 'Consumable', 1] as [string, string, string, number]];
    for (const [sku, name, category, price] of rows) {
      const qty = sku.startsWith('MARKER') ? 1 : 20 + Math.floor(Math.random() * 60);
      const id = (await tx.query(
        `INSERT INTO items (site_id, name, on_hand, data, created_under_version, created_by) VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
        [siteId, name, qty, { sku, category, unit_price: price, reorder_level: 10 }, v, admin])).rows[0].id;
      await tx.query(
        `INSERT INTO stock_movements (site_id, item_id, kind, qty, reason, idempotency_key, actor_id) VALUES ($1,$2,'receive',$3,'opening balance',$4,$5)`,
        [siteId, id, qty, `seed-${randomUUID()}`, admin]);
      items.push({ id, price });
    }

    if (bp.workflows.request) {
      const member = people[bp.slug].find(p => p[1] === 'Member')![0];
      for (let i = 0; i < 10; i++) {
        const it = items[i % (items.length - 1)];
        const data: Record<string, unknown> = { unit_price: it.price };
        if (bp.slug === 'service-centre') Object.assign(data, {
          serial_no: `PCB-${24000 + (i === 8 ? 7 : i)}`,
          fault: ['No power', 'Display dead', 'Relay chatter', 'Overheating'][i % 4],
          fault_category: ['No power', 'Component failure', 'Solder joint', 'Short circuit', 'Firmware'][i % 5],
          board_model: ['MCB-200 controller', 'PSU-48V', 'VFD drive card', 'HMI panel board'][i % 4],
          customer: ['Acme Pumps', 'Bharat Textiles', 'Metro Elevators', 'Sunrise Plastics'][i % 4],
          priority: ['low', 'normal', 'urgent'][i % 3],
        });
        if (bp.slug === 'distribution') Object.assign(data, { site_location: ['Ward 4', 'Sector 12', 'Plant gate', 'Substation B'][i % 4] });
        const state = i % 2 ? 'submitted' : 'draft';
        const r = (await tx.query(
          `INSERT INTO requests (site_id, item_id, qty, state, requested_by, data, created_under_version) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
          [siteId, it.id, 1 + (i % 4), state, member, data, v])).rows[0].id;
        await tx.query(
          `INSERT INTO audit_events (site_id, entity, record_id, kind, actor_id, actor_role, after, version_id) VALUES ($1,'request',$2,'create',$3,'Member',$4,$5)`,
          [siteId, r, member, data, v]);
      }
    }
  });
  console.log(`seeded ${bp.slug}`);
}
const managerIds = Object.fromEntries(Object.entries(people).map(([slug, ps]) => [slug, ps.find(p => p[1] === 'Manager')![0]]));
await runLifecycle(blueprints, SITE_IDS, managerIds);
// Service Centre: fill in diagnosis details on the repair logs the lifecycle opened.
await withSite({ siteId: SITE_IDS['service-centre'], userId: admin, role: 'Admin' }, async tx => {
  const reps = (await tx.query('SELECT id FROM repairs ORDER BY opened_at')).rows;
  for (const [k, r] of reps.entries())
    await tx.query('UPDATE repairs SET diagnosis = $2, data = data || $3 WHERE id = $1', [r.id,
      ['Dry solder joint on regulator', 'Failed MOSFET on output stage', 'Corroded trace near connector', 'Corrupt firmware image'][k % 4],
      { root_cause: ['Thermal cycling', 'Overcurrent event', 'Moisture ingress', 'Power loss during update'][k % 4],
        parts_replaced: ['U3 regulator', 'Q2 MOSFET, R14', 'Jumper wire on trace 7', 'None (reflashed)'][k % 4],
        firmware_version: `v2.${k + 1}.0`, technician: ['Ravi', 'Neha', 'Imran'][k % 3], bench_hours: 1.5 + (k % 4) }]);
  // Make one finished repair belong to the board that comes back (PCB-24007), so the repeat-failure demo is reliable.
  const done = (await tx.query(`SELECT request_id FROM repairs WHERE state = 'closed' ORDER BY closed_at LIMIT 1`)).rows[0];
  if (done) {
    await tx.query(`UPDATE repairs SET serial_no = 'PCB-24007' WHERE request_id = $1`, [done.request_id]);
    const core = (await tx.query(`SELECT 1 FROM information_schema.columns WHERE table_name = 'requests' AND column_name = 'serial_no'`)).rowCount;
    await tx.query(core
      ? `UPDATE requests SET serial_no = 'PCB-24007' WHERE id = $1`
      : `UPDATE requests SET data = jsonb_set(data, '{serial_no}', '"PCB-24007"') WHERE id = $1`, [done.request_id]);
  }
});
await pool.end();
console.log('done. login: admin@axel.dev / demo1234');
