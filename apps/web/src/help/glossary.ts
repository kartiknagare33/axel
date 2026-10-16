export const GLOSSARY: [string, string][] = [
  ['Unit', 'One part of the business with its own system, for example Central Stores.'],
  ['Blueprint', 'The saved design of a unit: its fields, steps, pages, rules and look. Publishing makes a Blueprint live.'],
  ['Module', 'A building block, such as Request or Approval. Only the 13 approved modules exist.'],
  ['Port', 'A connection point on a module. Ports only fit matching ports, so an impossible system cannot be wired.'],
  ['Workflow step', 'A move from one stage to the next, for example Submitted to Approved, and who may do it.'],
  ['Rule', 'A condition a step must meet, for example "qty <= 50".'],
  ['Law', 'A rule the unit must never break, written as a sentence. Checked before every publish.'],
  ['Release Gate', 'The automatic safety check before publishing. It acts out hundreds of random actions on real data, then undoes them.'],
  ['Replay', 'Re-runs recent real requests through your change to show who would be affected.'],
  ['Impact', 'What your change does to existing data, and what to do with records that no longer fit.'],
  ['Draft and Publish', 'A draft is saved but not live. Publish makes it live for everyone, with no restart.'],
  ['Rollback', 'Go back to an earlier version. Data is never deleted.'],
];

export const TAB_HELP: Record<string, string> = {
  problems: 'Mistakes in your design, in plain English, often with a one-click Fix',
  module: 'Details and fields of the selected building block',
  workflow: 'The steps records go through, who may take each step, and rules',
  laws: 'Rules this unit must never break',
  gate: 'Run the automatic safety check before publishing',
  impact: 'See who is affected by your change, using real past requests',
  theme: 'Layout and colours',
  json: 'The raw saved design, for technical users',
  versions: 'Every past release, and roll back',
  people: 'Who can use this unit, and their roles',
};
