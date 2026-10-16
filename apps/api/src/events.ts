import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { bus } from './blueprints';
import { memberships } from './auth';
import { ah } from './errors';

bus.setMaxListeners(500);
export const eventsRouter = Router();

// GET /api/events?token=... - server-sent events for every site the user belongs to.
eventsRouter.get('/events', ah(async (req, res) => {
  let userId = '';
  try { userId = String((jwt.verify(String(req.query.token ?? ''), process.env.JWT_SECRET!) as jwt.JwtPayload).sub); }
  catch { res.status(401).end(); return; }
  const mine = new Set((await memberships(userId)).map((m: any) => m.site_id));
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache, no-transform', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
  res.write(': connected\n\n');
  const relay = (type: string) => (ev: { siteId: string }) => {
    if (mine.has(ev.siteId)) res.write(`event: ${type}\ndata: ${JSON.stringify(ev)}\n\n`);
  };
  const onPub = relay('site_published');
  const onRec = relay('record_changed');
  bus.on('site_published', onPub);
  bus.on('record_changed', onRec);
  const ping = setInterval(() => res.write(': ping\n\n'), 25_000);
  req.on('close', () => { bus.off('site_published', onPub); bus.off('record_changed', onRec); clearInterval(ping); });
}));
