export type Role = 'Public' | 'Member' | 'Manager' | 'Admin';
export const ROLES: Role[] = ['Public', 'Member', 'Manager', 'Admin'];

export type FieldType =
  | 'text' | 'number' | 'money' | 'date' | 'boolean'
  | 'select' | 'relation' | 'formula' | 'file';

export interface Origin { kind: 'sheet' | 'recording' | 'preset' | 'manual'; [k: string]: unknown }

export interface Field {
  key: string; type: FieldType; label?: string;
  required?: boolean; default?: unknown; unique?: boolean; indexed?: boolean;
  min?: number; max?: number; pattern?: string;
  options?: string[];
  to?: string;
  expr?: string;
  system?: boolean;
  roles?: { read?: Role[]; write?: Role[] };
  origin?: Origin; owner_module?: string; reason?: string;
}

export interface Entity { label?: string; owner_module: string; fields: Field[] }

export interface Transition {
  id: string; from: string; to: string; roles: Role[];
  label?: string; guard?: string; actions?: string[]; owner_module?: string;
}
export interface Workflow { initial: string; states: string[]; transitions: Transition[]; terminal: string[] }

export interface Law { id: string; template: string; locked?: boolean; [k: string]: unknown }

export interface Widget {
  id: string; type: 'bar' | 'line' | 'pie' | 'stat'; title?: string;
  entity: string; measure: 'count' | 'sum' | 'avg'; field?: string; by?: string;
}

export interface Page {
  path: string; title: string;
  view: 'table' | 'kanban' | 'queue' | 'dashboard' | 'form' | 'detail';
  entity?: string; groupBy?: string; columns?: string[];
  filter?: Record<string, string>; widgets?: Widget[]; roles?: Role[]; owner_module?: string;
}

export type Layout = 'sidebar' | 'topbar' | 'kanban-first' | 'queue-first';
export interface Theme {
  tokens: { primary: string; surface: string; radius: string; font: string };
  layout: Layout; density: 'compact' | 'comfortable'; home: string;
}

export interface Edge { from: { module: string; port: string }; to: { module: string; port: string } }

export interface Blueprint {
  configVersion: 3;
  siteId: string; slug: string; name: string;
  theme: Theme;
  modules: string[];
  entities: Record<string, Entity>;
  workflows: Record<string, Workflow>;
  laws: Law[];
  pages: Page[];
  roles: Role[];
  nav: { label: string; path: string }[];
  edges?: Edge[];
  canvas?: { positions: Record<string, { x: number; y: number }> };
}

export interface Diagnostic {
  code: string; severity: 'error' | 'warning';
  nodeId?: string; entity?: string; fieldKey?: string;
  message: string; fix?: { label: string; patch: unknown };
}
