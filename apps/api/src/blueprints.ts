import pg from 'pg';
import { EventEmitter } from 'node:events';
import { compile, type Blueprint, type Compiled } from '@axel/compiler';
import { withSite } from './db';

export interface Loaded { siteId: string; slug: string; name: string; versionId: string; compiled: Compiled }
const cache = new Map<string, Promise<Loaded | null>>();
export const bus = new EventEmitter();

export function getPublished(siteId: string): Promise<Loaded | null> {
  let p = cache.get(siteId);
  if (!p) {
    p = withSite({ siteId, userId: '', role: '' }, async c => {
      const r = (await c.query(
        `SELECT s.slug, s.name, v.id AS version_id, v.config
           FROM sites s JOIN site_versions v ON v.id = s.published_version_id
          WHERE s.id = $1`, [siteId])).rows[0];
      if (!r) return null;
      return { siteId, slug: r.slug, name: r.name, versionId: r.version_id, compiled: compile(r.config as Blueprint) };
    });
    p.catch(() => cache.delete(siteId));
    p.then(v => { if (!v) cache.delete(siteId); });
    cache.set(siteId, p);
  }
  return p;
}

export const invalidate = (siteId: string) => cache.delete(siteId);

export async function startPublishListener() {
  const c = new pg.Client({ connectionString: process.env.DATABASE_URL_APP });
  await c.connect();
  await c.query('LISTEN site_published');
  c.on('notification', n => {
    const [siteId, versionId] = (n.payload ?? '').split(':');
    invalidate(siteId);
    bus.emit('site_published', { siteId, versionId });
  });
  c.on('error', e => { console.error('listener lost', e); setTimeout(startPublishListener, 2000); });
}
