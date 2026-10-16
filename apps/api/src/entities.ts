import { randomUUID } from 'node:crypto';
import type { Blueprint } from '@axel/compiler';

export interface TableSpec { table: string; core: string[]; insertDefaults?: () => Record<string, unknown> }

export const TABLES: Record<string, TableSpec> = {
  item:        { table: 'items',        core: ['name', 'on_hand', 'reserved'] },
  request:     { table: 'requests',     core: ['item_id', 'qty', 'state', 'requested_by'] },
  approval:    { table: 'approvals',    core: ['request_id', 'decision', 'decided_by', 'note'] },
  assignment:  { table: 'assignments',  core: ['request_id', 'item_id', 'qty', 'assigned_to', 'state'] },
  consumption: { table: 'consumptions', core: ['assignment_id', 'qty', 'note'], insertDefaults: () => ({ idempotency_key: randomUUID() }) },
  return:      { table: 'returns',      core: ['ref_type', 'ref_id', 'item_id', 'qty', 'condition'] },
  repair:      { table: 'repairs',      core: ['request_id', 'serial_no', 'fault', 'diagnosis', 'state', 'technician_id'] },
};

export function resolveEntity(bp: Blueprint, seg: string): string | null {
  if (bp.entities[seg] && TABLES[seg]) return seg;
  return Object.keys(bp.entities).find(k => TABLES[k]?.table === seg) ?? null;
}

export function toRecord(entity: string, row: Record<string, any>) {
  const { data, site_id, created_under_version, ...rest } = row;
  const rec: Record<string, unknown> = { ...(data ?? {}), ...rest };
  if (entity === 'item') rec.available = Number(rec.on_hand) - Number(rec.reserved);
  return rec;
}

export function split(spec: TableSpec, body: Record<string, unknown>) {
  const core: Record<string, unknown> = {}, data: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(body)) (spec.core.includes(k) ? core : data)[k] = v;
  return { core, data };
}
