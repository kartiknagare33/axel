import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { REGISTRY, MODULE_IDS, compile, type Blueprint } from '@axel/compiler';
import { centralStores, serviceCentre, distribution } from '../seed/blueprints';

const out = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', 'docs');
mkdirSync(out, { recursive: true });
const sites: Blueprint[] = [centralStores, serviceCentre, distribution];
const tick = '`';
const code = (s: string) => tick + s + tick;

const DESC: Record<string, string> = {
  auth: 'Global JWT login, bcrypt password hashing, role checks (Public, Member, Manager, Admin).',
  users: 'Per-site memberships and roles. Only Admins change roles; nobody changes their own.',
  dashboard: 'App shell, navigation, generic forms, tables, kanban, queue and detail views.',
  inventory: 'Items plus the append-only stock ledger (receive, adjust, reserve, commit, release, return).',
  request: 'Members ask for material; guard checks available stock before submit.',
  approval: 'Managers approve or reject; approval reserves stock with an expiry.',
  'material-assignment': 'Approved stock is issued to a person; the reservation is committed.',
  'assignment-frontend': 'Queue page for assignments.',
  consumption: 'Field teams record what they used against an assignment.',
  returns: 'Material or boards come back; stock is returned to the ledger.',
  'pcb-repair': 'Board repairs with serial numbers; repair log opened and closed by the workflow.',
  analytics: 'Per-site dashboard widgets (Recharts) that respect column masks.',
  excel: 'Templates, dry-run import (Manager+), role-masked export.',
};

let reg = `# Module registry\n\nGenerated from ${code('packages/compiler/src/registry.ts')} by ${code('pnpm docs')}. `
  + 'Every module is a typed node in the builder. A connection is only allowed when the output type matches the input type, '
  + 'and a module cannot be published without the modules it requires.\n\n'
  + '| # | Module (node id) | Kind | Inputs | Outputs | Requires | What it does | Used by |\n|---|---|---|---|---|---|---|---|\n';
MODULE_IDS.forEach((id, i) => {
  const m = REGISTRY[id];
  const ins = m.in.map(p => `${p.name}${p.required ? '*' : ''}: ${p.types.join(' or ')}`).join('<br>') || '-';
  const outs = m.out.map(p => `${p.name}: ${p.types.join(' or ')}`).join('<br>') || '-';
  const req = m.requires.map(g => g.map(r => REGISTRY[r].name).join(' or ')).join(', ') || '-';
  const used = sites.filter(s => s.modules.includes(id)).map(s => s.name).join(', ') || '-';
  reg += `| ${i + 1} | ${m.name} (${code(id)}) | ${m.kind} | ${ins} | ${outs} | ${req} | ${DESC[id]} | ${used} |\n`;
});
const instances = sites.reduce((n, s) => n + s.modules.length, 0);
reg += `\n\\* required input.\n\n**Reuse:** the three seeded units use ${instances} module instances backed by 13 implementations.\n\n`
  + '## Port types\n\n| Port type | Carries |\n|---|---|\n'
  + '| Identity | The signed-in user |\n| Membership | The user\'s role in a site |\n| Page[] | Pages rendered by the shell |\n'
  + '| ItemStream | Items in the site |\n| StockLedger | Stock movements |\n| RequestStream | Requests |\n'
  + '| ApprovedStream | Approved requests |\n| AssignmentStream | Issued material |\n| RepairLog | Repair records |\n'
  + '| File | Spreadsheet output |\n| Any | Accepts any stream (analytics, Excel) |\n\n'
  + '## Rules the builder and compiler enforce\n\n'
  + `- ${code('MODULE_DEP')}: e.g. "Approval requires Request."\n`
  + `- ${code('PORT_MISSING')}: a required input has no connection.\n`
  + `- ${code('PORT_TYPE')}: the connected output type does not match the input type.\n`
  + `- ${code('STATE_UNREACHABLE')} / ${code('STATE_DEAD_END')}: workflow states nothing leads to, or with no way out.\n`
  + `- ${code('FORMULA_REF')}: a calculated field uses an unknown field (with a "did you mean" suggestion).\n`
  + `- ${code('LAW_ISOLATION_MISSING')}: the site isolation law is locked and cannot be removed.\n`;
writeFileSync(path.join(out, 'MODULE_REGISTRY.md'), reg);

function explain(bp: Blueprint) {
  const L: string[] = [`## ${bp.name} (/${bp.slug})`, ''];
  L.push(`Layout **${bp.theme.layout}**, ${bp.theme.density} density, home page ${code(bp.theme.home)}, primary colour ${bp.theme.tokens.primary}.`, '');
  L.push(`Modules (${bp.modules.length}): ${bp.modules.map(m => REGISTRY[m].name).join(', ')}.`, '');
  for (const [ek, e] of Object.entries(bp.entities)) {
    L.push(`### ${e.label ?? ek} (${code(ek)})`, '', '| Field | Type | Notes |', '|---|---|---|');
    for (const f of e.fields) {
      const notes = [
        f.required && 'required', f.unique && 'unique per site', f.expr && `= ${code(f.expr)}`,
        f.system && 'maintained by the ledger', f.type === 'relation' && `links to ${f.to}`,
        f.options && f.options.join(' / '), f.roles?.read && `visible only to ${f.roles.read.join(', ')}`,
      ].filter(Boolean).join('; ');
      L.push(`| ${f.label ?? f.key} (${code(f.key)}) | ${f.type} | ${notes} |`);
    }
    L.push('');
  }
  for (const [ek, wf] of Object.entries(bp.workflows)) {
    L.push(`### Workflow: ${ek}`, '', `States: ${wf.states.join(' > ')}. Starts at ${code(wf.initial)}; ends at ${wf.terminal.map(code).join(', ')}.`, '',
      '| Step | From | To | Who | Guard | Actions |', '|---|---|---|---|---|---|');
    for (const t of wf.transitions)
      L.push(`| ${t.id} ${t.label ?? ''} | ${t.from} | ${t.to} | ${t.roles.filter(r => r !== 'Public').join(', ')} | ${t.guard ? code(t.guard) : ''} | ${(t.actions ?? []).map(code).join(' ')} |`);
    L.push('');
  }
  L.push('### Pages', '', ...bp.pages.map(p => `- **${p.title}** (${code(p.path)}): ${p.view}${p.entity ? ` of ${p.entity}` : ''}${p.roles ? `, for ${p.roles.join(', ')}` : ''}`), '');
  L.push('### Laws', '', ...bp.laws.map(l => `- ${l.id}: ${l.template}${l.locked ? ' (locked)' : ''}`), '');
  const d = compile(bp).diagnostics.filter(x => x.severity === 'error');
  L.push(`Compiler result: ${d.length ? `${d.length} error(s)` : 'no errors'}.`, '');
  return L.join('\n');
}
writeFileSync(path.join(out, 'SITES.md'),
  `# Seeded sites\n\nGenerated by ${code('pnpm docs')} from ${code('apps/api/seed/blueprints.ts')}. `
  + 'Each unit below is a Blueprint (JSON) rendered by the same code. Nothing here is hand-coded per site.\n\n'
  + sites.map(explain).join('\n'));
console.log(`wrote ${path.join(out, 'MODULE_REGISTRY.md')} and SITES.md`);
