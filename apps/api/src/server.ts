import express from 'express';
import { authRouter, requireAuth, memberships } from './auth';
import { sitesRouter } from './sites';
import { siteScope, requireRole } from './site';
import { resources } from './resources';
import { analytics } from './analytics';
import { workflow } from './workflowRoutes';
import { hubRouter } from './hub';
import { versionsRouter } from './versions';
import { eventsRouter } from './events';
import { excel } from './excel';
import { aliases } from './aliases';
import { gateRouter } from './gate';
import { replayRouter } from './replay';
import { inferRouter } from './infer';
import { membersRouter } from './members';
import { exportRouter } from './export';
import { isolationRouter } from './isolation';
import { timeline } from './timeline';
import { errorHandler, ah } from './errors';
import { pool } from './db';
import { startPublishListener } from './blueprints';
import { startJobs } from './jobs';
import { otpMode } from './minimoth';

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '2mb' }));

app.get('/api/health', ah(async (_req, res) => { await pool.query('SELECT 1'); res.json({ ok: true }); }));
app.use('/api/auth', authRouter);
app.get('/api/me', requireAuth, ah(async (req, res) => {
  const u = (await pool.query('SELECT id, email, name, is_hub_admin FROM users WHERE id = $1', [req.user!.id])).rows[0];
  res.json({ user: { id: u.id, email: u.email, name: u.name, hubAdmin: u.is_hub_admin }, memberships: await memberships(u.id) });
}));
app.use('/api/sites', sitesRouter);
app.use('/api/sites', inferRouter);
app.use('/api/sites/:siteId', requireAuth, siteScope, requireRole('Admin'), versionsRouter, gateRouter, replayRouter, membersRouter, exportRouter);
app.use('/api/hub', hubRouter);
app.use('/api/hub', isolationRouter);
app.use('/api', eventsRouter);
app.use('/api/:siteId', requireAuth, siteScope, analytics, aliases, timeline, workflow, excel, resources);
app.use(errorHandler);

console.log(`OTP login (MiniMoth): ${otpMode()}; required for: ${otpMode() === 'off' ? 'nobody (set MINIMOTH_API_KEY in .env)' : process.env.OTP_REQUIRED ?? 'all'}`);
await startPublishListener();
startJobs();
const port = Number(process.env.PORT ?? 4000);
app.listen(port, () => console.log(`Axel API on :${port}`));
