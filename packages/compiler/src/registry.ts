export type PortType =
  | 'Identity' | 'Membership' | 'Page[]' | 'ItemStream' | 'StockLedger'
  | 'RequestStream' | 'ApprovedStream' | 'AssignmentStream' | 'RepairLog' | 'File' | 'Any';

export interface Port { name: string; types: PortType[]; required?: boolean }
export interface ModuleDef {
  id: string; name: string;
  kind: 'hub-core' | 'layout' | 'entity' | 'entity+workflow' | 'workflow' | 'page' | 'page+action';
  in: Port[]; out: Port[];
  requires: string[][];
  infer?: string[];
}

export const REGISTRY: Record<string, ModuleDef> = {
  auth: { id: 'auth', name: 'Authentication and RBAC', kind: 'hub-core', in: [], out: [{ name: 'identity', types: ['Identity'] }], requires: [] },
  users: { id: 'users', name: 'User Management', kind: 'hub-core', in: [{ name: 'identity', types: ['Identity'], required: true }], out: [{ name: 'membership', types: ['Membership'] }], requires: [['auth']] },
  dashboard: { id: 'dashboard', name: 'Dashboard Shell/Navigation/Forms', kind: 'layout', in: [{ name: 'pages', types: ['Page[]'] }], out: [], requires: [['auth']] },
  inventory: { id: 'inventory', name: 'Inventory', kind: 'entity', in: [], out: [{ name: 'items', types: ['ItemStream'] }, { name: 'ledger', types: ['StockLedger'] }], requires: [['dashboard']], infer: ['stock', 'qty', 'quantity', 'sku', 'item'] },
  request: { id: 'request', name: 'Request', kind: 'entity+workflow', in: [{ name: 'items', types: ['ItemStream'], required: true }], out: [{ name: 'requests', types: ['RequestStream'] }], requires: [['inventory']], infer: ['requested by', 'raised by', 'employee'] },
  approval: { id: 'approval', name: 'Approval', kind: 'workflow', in: [{ name: 'requests', types: ['RequestStream'], required: true }], out: [{ name: 'approved', types: ['ApprovedStream'] }], requires: [['request']], infer: ['approved by', 'approver', 'sanctioned by', 'authorised by'] },
  'material-assignment': { id: 'material-assignment', name: 'Material Assignment', kind: 'workflow', in: [{ name: 'approved', types: ['ApprovedStream'], required: true }, { name: 'ledger', types: ['StockLedger'], required: true }], out: [{ name: 'assignments', types: ['AssignmentStream'] }], requires: [['approval'], ['inventory']], infer: ['assigned to', 'issued to', 'technician'] },
  'assignment-frontend': { id: 'assignment-frontend', name: 'Assignment Frontend', kind: 'page', in: [{ name: 'assignments', types: ['AssignmentStream'], required: true }], out: [], requires: [['material-assignment']] },
  consumption: { id: 'consumption', name: 'Consumption Tracking', kind: 'workflow', in: [{ name: 'assignments', types: ['AssignmentStream'], required: true }], out: [{ name: 'ledger', types: ['StockLedger'] }], requires: [['material-assignment']], infer: ['consumed', 'used', 'utilised'] },
  returns: { id: 'returns', name: 'Return Management', kind: 'workflow', in: [{ name: 'source', types: ['AssignmentStream', 'RepairLog'], required: true }], out: [{ name: 'ledger', types: ['StockLedger'] }], requires: [['material-assignment', 'pcb-repair']], infer: ['returned on', 'return date', 'returned qty'] },
  'pcb-repair': { id: 'pcb-repair', name: 'PCB Repair', kind: 'entity+workflow', in: [{ name: 'requests', types: ['RequestStream'], required: true }], out: [{ name: 'repairs', types: ['RepairLog'] }], requires: [['request']], infer: ['serial', 'pcb', 'fault', 'board'] },
  analytics: { id: 'analytics', name: 'Analytics Dashboard', kind: 'page', in: [{ name: 'source', types: ['Any'] }], out: [], requires: [['dashboard']] },
  excel: { id: 'excel', name: 'Reports with Excel Integration', kind: 'page+action', in: [{ name: 'source', types: ['Any'] }], out: [{ name: 'file', types: ['File'] }], requires: [['dashboard']] },
};

export const MODULE_IDS = Object.keys(REGISTRY);
