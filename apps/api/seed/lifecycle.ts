import { compile, type Blueprint, type Workflow } from '@axel/compiler';
import { pool, withSite } from '../src/db';
import { runTransition } from '../src/workflow';

// Seeded reservations always use the Blueprint TTL, never the stage-demo override.
delete process.env.DEMO_RESERVATION_TTL;

function happyPath(wf: Workflow) {
  const out: string[] = [];
  const seen = new Set<string>(['submitted']);
  let s = 'submitted';
  for (;;) {
    const t = wf.transitions.find(x => x.from === s && x.to !== 'rejected' && !seen.has(x.to));
    if (!t) break;
    out.push(t.to); seen.add(t.to); s = t.to;
  }
  return out;
}

// Push seeded requests through the real engine so every state, reservation and audit event is genuine.
export async function runLifecycle(bps: Blueprint[], siteIds: Record<string, string>, managers: Record<string, string>) {
  for (const bp of bps) {
    const wf = bp.workflows.request;
    if (!wf) continue;
    const compiled = compile(bp);
    const siteId = siteIds[bp.slug];
    const versionId = (await pool.query('SELECT published_version_id FROM sites WHERE id = $1', [siteId])).rows[0].published_version_id;
    const ctx = { siteId, userId: managers[bp.slug], role: 'Manager' as const, versionId };
    const submitted: string[] = await withSite(ctx, async tx =>
      (await tx.query(`SELECT id FROM requests WHERE state = 'submitted' ORDER BY created_at, id`)).rows.map(r => r.id));
    const path = happyPath(wf);
    for (const [i, id] of submitted.entries()) {
      const closedAt = path.indexOf('closed');
      const depth = [0, 1, 2, closedAt >= 0 ? closedAt + 1 : path.length][i % 4] ?? 0;
      const steps = i === submitted.length - 1 && wf.transitions.some(t => t.to === 'rejected') ? ['rejected'] : path.slice(0, Math.min(depth, path.length));
      for (const to of steps) {
        try {
          await withSite(ctx, tx => runTransition(tx, ctx, compiled, bp.name, 'request', id, {
            to, idempotencyKey: `seed-${id}-${to}`,
            payload: to === 'assigned' ? { assigned_to: ['Ravi', 'Neha', 'Imran'][i % 3] } : undefined,
          }));
        } catch (e) {
          console.warn(`seed ${bp.slug}: ${to} failed: ${(e as Error).message}`);
          break;
        }
      }
    }
    console.log(`lifecycle ${bp.slug}: walked ${submitted.length} requests along ${path.join(' > ')}`);
  }
}
