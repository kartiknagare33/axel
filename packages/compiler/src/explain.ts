import type { Blueprint, Field } from './types';
import { REGISTRY } from './registry';
import { lawSentence } from './laws';

const tick = '`';
const code = (s: string) => tick + s + tick;

function notes(f: Field) {
  return [
    f.required && 'required', f.unique && 'unique', f.expr && `calculated: ${f.expr}`, f.system && 'kept by the stock ledger',
    f.type === 'relation' && `links to ${f.to}`, f.options && `one of: ${f.options.join(', ')}`,
    f.roles?.read && `visible to ${f.roles.read.join(', ')}`,
  ].filter(Boolean).join('; ') || '-';
}
function effect(actions: string[]) {
  if (!actions.length) return '-';
  return actions.map(a =>
    a.startsWith('stock.reserve') ? 'reserves stock'
    : a.startsWith('stock.commit') ? 'takes stock out'
    : a.startsWith('stock.release') ? 'releases reserved stock'
    : a.startsWith('stock.return') ? 'puts stock back'
    : a.startsWith('repair.open') ? 'opens a repair log'
    : a.startsWith('repair.close') ? 'closes the repair log' : a).join(', ');
}

/** "Explain this site": the unit in plain language, generated from its Blueprint. */
export function explain(bp: Blueprint): string {
  const L: string[] = [`# ${bp.name}`, '', `This unit runs on Axel from one Blueprint (configuration version ${bp.configVersion}). Everything below is generated from that Blueprint; nothing is hand-written per unit.`, ''];
  L.push('## At a glance', '',
    `- Layout: **${bp.theme.layout}**, ${bp.theme.density} density, home page ${code(bp.theme.home)}.`,
    `- Modules (${bp.modules.length}): ${bp.modules.map(m => REGISTRY[m]?.name ?? m).join(', ')}.`,
    `- Roles: ${bp.roles.join(', ')}.`, '');
  L.push('## Data', '');
  for (const [ek, e] of Object.entries(bp.entities)) {
    L.push(`### ${e.label ?? ek}`, '', '| Field | Type | Notes |', '|---|---|---|');
    for (const f of e.fields) L.push(`| ${f.label ?? f.key} (${code(f.key)}) | ${f.type} | ${notes(f)} |`);
    L.push('');
  }
  for (const [ek, wf] of Object.entries(bp.workflows)) {
    L.push(`## Workflow: ${bp.entities[ek]?.label ?? ek}`, '',
      `A record starts as **${wf.initial}** and ends as ${wf.terminal.map(s => `**${s}**`).join(' or ')}.`, '',
      '| Step | From | To | Who may do it | Rule | Effect |', '|---|---|---|---|---|---|');
    for (const t of wf.transitions)
      L.push(`| ${t.label ?? t.to} | ${t.from} | ${t.to} | ${t.roles.filter(r => r !== 'Public').join(', ')} | ${t.guard ? code(t.guard) : '-'} | ${effect(t.actions ?? [])} |`);
    L.push('');
  }
  L.push('## Pages', '', ...bp.pages.map(p => `- **${p.title}** (${code(p.path)}): ${p.view}${p.entity ? ` of ${bp.entities[p.entity]?.label ?? p.entity}` : ''}${p.roles ? `; only ${p.roles.join(', ')}` : ''}.`), '');
  L.push('## Laws', '', 'The Release Gate proves these before every publish.', '', ...bp.laws.map(l => `- ${lawSentence(l, bp)}${l.locked ? ' (locked)' : ''}.`), '');
  return L.join('\n');
}

const schemaOf = (f: Field): Record<string, unknown> => {
  switch (f.type) {
    case 'number': case 'money': case 'formula': return { type: 'number' };
    case 'boolean': return { type: 'boolean' };
    case 'date': return { type: 'string', format: 'date' };
    case 'relation': return { type: 'string', format: 'uuid', description: `id of a ${f.to}` };
    case 'select': return { type: 'string', enum: f.options ?? [] };
    default: return { type: 'string' };
  }
};

/** OpenAPI 3.1 for one unit's entities and workflow steps. */
export function openapi(bp: Blueprint) {
  const paths: Record<string, unknown> = {};
  const schemas: Record<string, unknown> = {};
  const site = [
    { name: 'siteId', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } },
    { name: 'X-Site-Id', in: 'header', required: true, schema: { type: 'string', format: 'uuid' } },
  ];
  const id = { name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } };
  const ok = (d: string) => ({ description: d });
  for (const [ek, e] of Object.entries(bp.entities)) {
    const name = ek[0].toUpperCase() + ek.slice(1);
    const label = e.label ?? ek;
    schemas[name] = {
      type: 'object',
      properties: Object.fromEntries([
        ['id', { type: 'string', format: 'uuid', readOnly: true }],
        ...e.fields.map(f => [f.key, { ...schemaOf(f), ...(f.type === 'formula' || f.system ? { readOnly: true } : {}), description: f.label ?? f.key }]),
      ]),
      required: e.fields.filter(f => f.required).map(f => f.key),
    };
    const ref = { $ref: `#/components/schemas/${name}` };
    paths[`/api/{siteId}/${ek}`] = {
      parameters: site,
      get: { summary: `List ${label}`, responses: { 200: ok('Rows visible to your role') } },
      post: { summary: `Create ${label}`, requestBody: { content: { 'application/json': { schema: ref } } }, responses: { 201: ok('Created'), 422: ok('Validation failed') } },
    };
    paths[`/api/{siteId}/${ek}/{id}`] = {
      parameters: [...site, id],
      get: { summary: `Read one ${label}`, responses: { 200: ok('Record with next steps'), 404: ok('Not found') } },
      patch: { summary: `Edit ${label}`, requestBody: { content: { 'application/json': { schema: ref } } }, responses: { 200: ok('Updated'), 409: ok('Stale record') } },
    };
    const wf = bp.workflows[ek];
    if (wf) paths[`/api/{siteId}/${ek}/{id}/transition`] = {
      parameters: [...site, id],
      post: {
        summary: `Move a ${label} to its next step`,
        requestBody: { content: { 'application/json': { schema: { type: 'object', required: ['to', 'idempotencyKey'], properties: { to: { type: 'string', enum: wf.states }, idempotencyKey: { type: 'string' }, ifVersion: { type: 'integer' } } } } } },
        responses: { 201: ok('Moved'), 200: ok('Repeat of an earlier request'), 403: ok('Role not allowed'), 409: ok('Not possible from the current state'), 422: ok('Blocked by a rule') },
      },
    };
  }
  return {
    openapi: '3.1.0',
    info: { title: `${bp.name} API (Axel)`, version: String(bp.configVersion) },
    security: [{ bearer: [] }],
    components: { schemas, securitySchemes: { bearer: { type: 'http', scheme: 'bearer' } } },
    paths,
  };
}
