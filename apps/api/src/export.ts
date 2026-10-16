import { Router } from 'express';
import ExcelJS from 'exceljs';
import JSZip from 'jszip';
import { explain, openapi } from '@axel/compiler';
import { withSite } from './db';
import { TABLES, toRecord } from './entities';
import { ah } from './errors';

// Mounted at /api/sites/:siteId (Admin only).
export const exportRouter = Router({ mergeParams: true });

exportRouter.get('/explain', (req, res) => {
  res.type('text/markdown').send(explain(req.site!.compiled.blueprint));
});

exportRouter.get('/openapi.json', (req, res) => {
  res.json(openapi(req.site!.compiled.blueprint));
});

exportRouter.get('/export', ah(async (req, res) => {
  const s = req.site!;
  const bp = s.compiled.blueprint;
  const zip = new JSZip();
  zip.file('blueprint.json', JSON.stringify(bp, null, 2));
  zip.file('README.md', explain(bp));
  zip.file('openapi.json', JSON.stringify(openapi(bp), null, 2));
  const wb = new ExcelJS.Workbook();
  wb.creator = 'Axel';
  const deployments = await withSite(s.ctx, async c => {
    const used = new Set<string>();
    for (const [ek, e] of Object.entries(bp.entities)) {
      const spec = TABLES[ek];
      if (!spec) continue;
      let sheet = (e.label ?? ek).replace(/[\[\]:*?\/\\]/g, ' ').slice(0, 28) || ek;
      while (used.has(sheet)) sheet = `${sheet}_`;
      used.add(sheet);
      const ws = wb.addWorksheet(sheet);
      const keys = ['id', ...e.fields.map(f => f.key), ...(bp.workflows[ek] ? ['state'] : [])];
      ws.addRow(keys);
      ws.getRow(1).font = { bold: true };
      const rows = (await c.query(`SELECT * FROM ${spec.table} ORDER BY created_at LIMIT 10000`)).rows;
      for (const r of rows) {
        const rec = s.compiled.computeFormulas(ek, toRecord(ek, r));
        ws.addRow(keys.map(k => {
          const v = rec[k];
          if (v instanceof Date || v == null || typeof v !== 'object') return v ?? null;
          return JSON.stringify(v);
        }));
      }
    }
    return (await c.query('SELECT id, version_id, proof, deployed_at, rollback_of FROM site_deployments ORDER BY deployed_at')).rows;
  });
  zip.file('data.xlsx', Buffer.from(await wb.xlsx.writeBuffer() as ArrayBuffer));
  zip.file('deployments.json', JSON.stringify(deployments, null, 2));
  const buf = await zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE' });
  res.setHeader('Content-Type', 'application/zip');
  res.setHeader('Content-Disposition', `attachment; filename="${s.slug}-export.zip"`);
  res.send(buf);
}));
