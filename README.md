# Axel - Attested Multi-Site Execution Layer

**PS 03 OpsHub submission.** *Axel. Every site proven before it runs.*

Axel runs many completely different operations sites from one codebase. Each unit (Central Stores, Service Centre, Distribution, and any unit you add) is a **Blueprint**: a JSON document that declares its theme, layout, modules, fields, workflow, pages and roles. One compiler turns a Blueprint into validators, masks and a render schema; one renderer draws every site; one API serves every site; PostgreSQL row-level security keeps every site's data apart.

## What you can see it do

- **One login, one hub, many products.** Switch between three units that look and behave differently: a dense analytics stock register, a repair kanban, an assignment queue.
- **Build without code.** Drag modules onto a canvas with typed ports. The builder explains problems in plain English ("Approval requires Request") and fixes most of them in one click.
- **Publish live, roll back safely.** Preview a draft on real data, publish with no restart, and every open window updates by itself. Roll back to any earlier version; data is never deleted.
- **Transactional stock.** Approve reserves stock, assign or repair commits it, return gives it back. 50 concurrent approvals against 10 units: exactly 10 succeed (Chaos test on the hub).
- **Isolation you can prove.** FORCE row-level security, composite foreign keys, transaction-local site context, 404-not-403 for other sites. 31 automated tests.
- **Excel with role rules.** Templates with dropdowns, dry-run imports with row-by-row errors, all-or-nothing commits, exports that leave out what your role cannot see.

## Release Gate and Laws

Nothing is published without evidence. Each site declares **Laws** as plain sentences, for example "Members never see Unit price", "Every Assignment comes from a request that was approved", "Reserved stock never exceeds on-hand stock". Before a draft goes live, the **Release Gate**:

1. compiles the Blueprint (zero errors allowed);
2. checks each Law against the Blueprint itself (for example, a calculated field that would reveal a hidden price);
3. performs hundreds of random actions as Members, Managers and Admins on the site's real data, inside a transaction that is always rolled back, and checks every Law after each step.

If a Law breaks, publish is blocked and the builder shows the counter-example: the exact steps that broke it, with a seed to replay. The proof (steps, seed, duration) is stored on every deployment; rollbacks run a short gate too.

## Replay Report and Impact Report

- **Replay.** Before publishing, Axel takes the last 50 real requests and runs their recorded history (same steps, same roles) through both the live version and the draft, inside a transaction that is rolled back. It reports exactly which requests would now go differently and at which step, for example "3 of 50: submitted > approved would be blocked by a rule".
- **Impact.** Every change is classified as additive, behavioural or destructive. When a removed state still holds records, publishing or rolling back requires a plan per state: keep those records read-only, or move them to another state (recorded in the audit trail). Fields that disappear are hidden, never dropped.
- Publish runs Gate, then Replay and Impact; anything that differs must be reviewed first. The replay summary and the chosen plans are stored with the deployment.

## Quick start

**Needs:** Docker Desktop, Node.js 20+, pnpm (`npm i -g pnpm`).

**Windows (one command on a fresh machine):**
```powershell
powershell -ExecutionPolicy Bypass -File .\first-run.ps1
```
Day to day: `.\start.ps1` and `.\stop.ps1`.

**macOS / Linux:**
```bash
cp .env.example .env
pnpm install
docker compose up -d db      # wait ~10 s the first time
pnpm migrate && pnpm seed
pnpm dev:api                 # terminal 1
pnpm dev:web                 # terminal 2, then open http://localhost:5173
```

## Demo accounts (password `demo1234`)

| Email | Role |
|---|---|
| admin@axel.dev | Hub admin, Admin of every unit |
| manager@cs.dev / member@cs.dev | Central Stores manager / member |
| manager@sc.dev / member@sc.dev | Service Centre manager / member |
| manager@dist.dev / field@dist.dev | Distribution manager / field member |

The login page has one-click buttons for each.

## How Axel meets PS 03

| Requirement | Where |
|---|---|
| Hub layer: global JWT login, bcrypt, roles, user management, site switcher (Ctrl+K), theme engine, module catalogue | `apps/api/src/auth.ts`, `apps/web/src/pages/Hub.tsx`, `apps/web/src/renderer/SiteShell.tsx` |
| Site layer: `{ siteId, slug, theme, modules, pages, roles }` | `packages/compiler/src/types.ts` (Blueprint), [docs/SITES.md](docs/SITES.md) |
| Module and node layer: 13 typed nodes | `packages/compiler/src/registry.ts`, [docs/MODULE_REGISTRY.md](docs/MODULE_REGISTRY.md) |
| Visual builder (React Flow), drag, connect, presets, field and workflow config | `apps/web/src/builder/Builder.tsx`, `packages/compiler/src/{ports,modules,presets}.ts` |
| Config saved as JSONB; one renderer for every site | `site_versions.config`, `apps/web/src/renderer/` |
| `/api/:siteId/:resource` with `site_id` on every business table | `apps/api/src/resources.ts`, `apps/api/migrations/001_core.sql` |
| Isolation at ORM/API and database level, tested per endpoint | `apps/api/src/site.ts`, RLS in `001_core.sql`, `apps/api/test/isolation.test.ts`, `api.test.ts` |
| Request, approval, assignment with transactional stock | `apps/api/src/workflow.ts`, `ledger.ts`, `test/workflow.test.ts` (chaos) |
| Calculated fields (TOTAL = QTY x PRICE) with schema validation | `formula` fields, `packages/compiler/src/expr.ts` |
| Preview, publish, versioned releases, rollback, deploy history | `apps/api/src/versions.ts`, builder Versions tab |
| Per-site analytics (Recharts) | `apps/api/src/analytics.ts`, dashboard view |
| Bulk Excel import and export with role restrictions | `apps/api/src/excel.ts`, `test/excel.test.ts` |
| Scoped REST APIs incl. login, sites, components, requests, approvals, assignments, Excel export | [docs/API.md](docs/API.md) |
| Architecture diagram, registry, data model, API design, README | [docs/](docs/) |
| Seeded demo data plus offline backup | `pnpm seed`, `backups/axel-demo.dump`, `restore.ps1` |

## Project layout

```text
axel/
  packages/compiler/   Blueprint types, expression DSL, diagnostics, validators, render schema,
                       typed ports, module effects, presets (shared by browser and server)
  apps/api/            Express API: auth, site scope, resources, workflow engine, stock ledger,
                       versions/publish/rollback, Excel, analytics, live events, jobs
    migrations/        PostgreSQL schema with FORCE RLS
    seed/              Three demo units, run through the real workflow engine
    test/              isolation, workflow (chaos), excel, api
  apps/web/            React app: hub, builder (React Flow), renderer with four layouts
  docs/                Architecture, module registry, sites, data model, API, demo script
  db/init/             Database roles (owner for migrations, app role without BYPASSRLS)
```

## Tests

Run with Axel started: `pnpm test` (31 tests).

| Suite | Proves |
|---|---|
| `test:isolation` (11) | Cross-site reads are 404, writes refused, header must match URL, masked fields never sent or written, other sites' ids look nonexistent, 60 interleaved pooled requests never mix, no context means zero rows, RLS forced on every table |
| `test:workflow` (4) | 50 concurrent approvals vs 10 units, role on transition, stale versions refused, double-click idempotent |
| `test:excel` (4) | Dry-run row errors, all-or-nothing commit, Member cannot import, export follows the role mask |
| `test:api` (4) | Every brief endpoint works for its site and refuses other sites |
| `test:gate` (4) | Unchanged sites pass the gate, a leaked price is blocked by a Law, a shortcut that skips approval is caught with a counter-example, publishing without a passing gate is refused |
| `test:replay` (4) | An unchanged draft replays identically, a stricter rule shows which past requests it would block, a removed state with records is reported with plans, publishing it without a plan is refused |

## Docs

- [Architecture](docs/ARCHITECTURE.md): Hub, Builder, API, PostgreSQL; request and publish flows
- [Module registry](docs/MODULE_REGISTRY.md): all 13 modules as builder nodes (generated)
- [Seeded sites](docs/SITES.md): each unit explained from its Blueprint (generated)
- [Data model](docs/DATA_MODEL.md)
- [API](docs/API.md)
- [Demo script](docs/DEMO_SCRIPT.md)

Regenerate the generated docs with `pnpm docs`.

## Offline backup

- Everything runs locally; no internet is needed during the demo.
- `.\backup.ps1` saves the database to `backups/axel-demo.dump`; `.\restore.ps1` brings it back in seconds.
- Keep a screen recording of the demo script as the last fallback.

## What comes next

Built: the Release Gate with Laws, the Replay Report and the Impact Report (above). Next: a Sheet Inferencer that derives a site from a unit's existing spreadsheets.
