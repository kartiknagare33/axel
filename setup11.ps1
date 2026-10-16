# Axel - README rewrite (novelty-first, with diagrams). Run from the axel folder.
$ErrorActionPreference = 'Stop'
function W([string]$Path, [string]$Content) {
  $full = Join-Path $PSScriptRoot $Path
  New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
  $text = $Content.Replace("`r`n", "`n").TrimStart("`n") + "`n"
  [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding $false))
  Write-Host "created $Path"
}

W 'README.md' @'
# Axel - Attested Multi-Site Execution Layer

**PS 03 OpsHub submission.** *Axel. Every site proven before it runs.*

Axel runs many completely different operations sites from one codebase. Every unit (Central Stores, Service Centre, Distribution, and any unit you add) is a **Blueprint**: one JSON document that declares its theme, layout, modules, fields, workflow, pages, roles and **Laws**. One compiler, one renderer, one API and PostgreSQL row-level security run them all.

Most platforms in this space let you *build* a site. Axel's focus is the part they leave to luck: **deriving** the site from what a unit already does, and **proving** every change is safe before it reaches real people and real stock.

![Axel architecture: Hub and Forge, PROVE services, shared compiler, runtime API, PostgreSQL](docs/images/architecture.jpeg)

![Axel flow: a unit's spreadsheet is inferred, proven by the Release Gate, published live, run, and safely changed or rolled back](docs/images/flow.png)

---

## What is new here

We studied the tools named in the brief and real multi-tenant projects. They fail at the same moments: turning what a unit already does into a system, changing a live system safely, rolling back without losing data, and proving tenants are isolated. Each item below answers one of those failures. Every one is live in the app and covered by an automated test.

### 1. Sheet Inferencer: the site is derived, not designed

**Problem.** Every builder starts from a blank canvas, so a process owner still needs someone technical to translate their spreadsheet into a system.

**What Axel does.** Upload the register the unit already keeps. Axel decides which sheet is the stock list and which is the request register. It infers field types, choice lists (from dropdowns or repeated values), money columns, and calculated fields: `=D2*I2` becomes `qty * unit_price`. It turns the **Status column into a workflow**: "Sanctioned" is read as approved, "Repairing" as in repair, "Issued" as assigned. From the columns present it enables modules (an "Approved by" column enables Approval, "Serial No" enables PCB Repair, "Returned On" enables Returns), proposes Laws, picks pages and a layout, and imports the rows with opening stock through the ledger.

**What makes it trustworthy.** Every inference shows a **confidence and a plain-English reason**, for example "'Total' is calculated as =D2*I2 in 100% of rows; mapped to qty * unit_price". Low-confidence guesses are highlighted. The rules are deterministic: no AI service, no internet, the same file always gives the same site.

**See it.** Hub, **+ From a spreadsheet**, `demo/registers/Workshop_Tools.xlsx`. Test: `test:infer`.

### 2. Laws and the Release Gate: nothing publishes without evidence

**Problem.** Low-code tools publish whatever the admin clicks. Mistakes are found by users.

**What Axel does.** Each site declares **Laws** as sentences: "Members never see Unit price", "Every Assignment comes from a request that was approved", "Reserved stock never exceeds on-hand stock", "This site never reads another site's data". Before any draft goes live, the **Release Gate**:

1. compiles it (zero errors allowed);
2. checks Laws against the Blueprint itself, for example a *calculated field that would leak a hidden price*;
3. runs a **seeded random walk**: hundreds to thousands of actions as Members, Managers and Admins on the site's **real data**, inside a transaction that is always rolled back, and checks every Law after every step.

If a Law breaks, publish is blocked and the builder shows a **counter-example**: the exact steps that broke it, plus the seed to replay them. Laws are property-based tests that a non-developer can read and add.

**See it.** Builder, Workflow tab: add a "Fast-track" step from submitted to assigned. **Run gate**: "Law l2 broken at step 37: Assignment ... was created for a request that never became 'approved'". Test: `test:gate`.

### 3. Replay Report: changes are tested against what actually happened

**Problem.** A tightened rule looks harmless until it blocks half of last month's real work.

**What Axel does.** Every state change is event-sourced. Before publishing, Axel takes the last 50 real requests and **replays their recorded history** (same steps, same roles) through both the live version and the draft, side by side, in a rolled-back transaction. It reports exactly which requests would now go differently and where: "3 of 50: submitted > approved would be blocked by a rule (today: allowed)".

**See it.** Service Centre builder, Workflow tab: give Approve the rule `qty <= 1`, then **Impact**, **Run replay and impact**. Test: `test:replay`.

### 4. Impact Report and data-preserving rollback

**Problem.** Platforms roll back configuration but orphan or lose the data created since.

**What Axel does.** Every change is classed as additive, behavioural or destructive, with record counts from live data. If a version removes a state that still holds records, publishing **or rolling back** requires a plan per state: keep those records read-only, or move them to another state. Moves are written to the audit trail. Fields that disappear are hidden, never dropped. Rollback runs a short gate on the older version too.

**See it.** Distribution: enable Returns, return one request, then roll back. The impact list asks what to do with the returned request; choose "Move to closed". Test: `test:replay`.

### 5. Proof-carrying releases

Every deployment stores a **proof record**: the Blueprint's content hash, the gate's steps, seed and result, the replay summary and whether it was reviewed, the plans chosen and the list of changes. The deploy history is an audit trail of *why* each version was allowed to go live, not just *when*.

### 6. A reservation ledger with expiry, proven under concurrency

**Problem.** Typical approval systems decrement a counter, so two managers approving at once double-spend stock, and approved-but-never-issued stock is locked forever.

**What Axel does.** Stock is an **append-only ledger** (receive, adjust, reserve, commit, release, return). Approve reserves; assign or repair commits; return gives back. Every operation takes row locks on the request and the item and carries an idempotency key. A double-click is a no-op, and a stale screen gets "this record changed since you opened it". **Reservations expire**: unclaimed stock is released and the request goes back for re-approval, visible on its timeline.

**See it.** Hub, **Run chaos**: 50 concurrent approvals against an item with 10 in stock. Exactly 10 succeed, 40 are refused, and the stock recomputed from the ledger matches the item. Test: `test:workflow`.

### 7. Isolation you can watch being proven

**Problem.** Row-level security is easy to switch on and easy to leak around: forgotten FORCE, owner bypass, pooled connections carrying the wrong tenant, foreign keys that reveal whether another tenant's row exists.

**What Axel does.** It uses FORCE RLS on every business table, an API role that cannot bypass RLS and owns no tables, transaction-local site context (no context means zero rows), and composite `(site_id, id)` foreign keys, so another unit's id is indistinguishable from a missing one. Reads of other units return 404, never 403. The client wipes its cache on every switch and discards late responses.

**See it.** Hub, **Isolation Ledger**: read live from PostgreSQL's own catalog. Then **Run live isolation check**: every unit reads every other unit, a cross-unit write and a cross-unit reference are attempted, and 30 parallel pooled requests run. Tests: `test:isolation` and `test:stage`.

### 8. A typed-port builder with the same compiler in browser and server

Modules are nodes with **typed ports**: Approval needs a RequestStream, and Material Assignment needs an ApprovedStream and a StockLedger. A wrong connection or a missing dependency is a plain-English problem ("Approval requires Request") with a one-click fix. Adding a module **changes the site**: Return Management adds a Return step, a Returns page and a stock action. The browser and the API run the **same compiler package**, so what the canvas accepts is exactly what the server accepts. Publishing is live: open windows of the site re-render with no reload and no restart.

### 9. Explained denials everywhere

Refusals say why and who decided: "Only Manager, Admin can approve in Service Centre (transition t2)", "Approve blocked: available stock for SC-104 is 3, rule 'stock.available(item_id) >= qty' is not met", "You can't see Unit price in Central Stores (cost confidential). Ask a Manager." A Member's Excel export carries an About sheet listing the columns hidden from them.

### 10. Zero lock-in

**Export** gives a zip with the Blueprint, a generated plain-language README for the unit (**Explain**), OpenAPI 3.1, all data as Excel, and the deploy history with proofs.

---

## How Axel compares

| Capability | Retool / Appsmith | Odoo / Zoho | Wix / Webflow | Axel |
|---|---|---|---|---|
| Many differently themed, isolated sites from one codebase | - | heavy customisation | one site each | yes |
| Site derived from the unit's existing spreadsheet, with explained confidence | - | - | - | yes |
| Rules (Laws) proven by a random walk before publish, with counter-examples | - | - | - | yes |
| Proposed change replayed against real history | - | - | - | yes |
| Rollback that plans for data created since | - | - | - | yes |
| Tenant isolation enforced in the database and checkable live | - | - | - | yes |
| Non-developer can change workflow and publish live | partly | needs a consultant | - | yes |

---

## Table stakes, done properly

JWT login with bcrypt; roles per unit (Public, Member, Manager, Admin) and a People tab; a site switcher (Ctrl+K) that changes layout, theme, pages and workflow, not just colours; four layout shells; table, kanban (drag to transition), queue and dashboard views (Recharts); calculated fields validated by the compiler; Excel templates with dropdowns, dry-run imports with row-by-row errors and all-or-nothing commits; role-masked exports; presets (Inventory Starter, Approval Chain, Repair Shop); versions with preview on live data; board history by serial number for PCB Repair.

---

## How Axel meets PS 03

| Requirement | Where |
|---|---|
| Hub layer: global JWT login, bcrypt, roles, user management, site switcher, theme engine, module catalogue | `apps/api/src/auth.ts`, `members.ts`, `apps/web/src/pages/Hub.tsx`, `renderer/SiteShell.tsx`, builder palette |
| Site layer: `{ siteId, slug, theme, modules, pages, roles }` | Blueprint in `packages/compiler/src/types.ts`; [docs/SITES.md](docs/SITES.md) |
| Module and node layer: 13 typed nodes | `packages/compiler/src/registry.ts`; [docs/MODULE_REGISTRY.md](docs/MODULE_REGISTRY.md) |
| Visual builder (React Flow): drag, connect, presets, field and workflow config | `apps/web/src/builder/` |
| Config saved as JSONB; one renderer for every site | `site_versions.config`; `apps/web/src/renderer/` |
| `/api/:siteId/:resource`; `site_id` on every business table | `apps/api/src/resources.ts`; `migrations/001_core.sql` |
| Isolation at API and database level, tested per endpoint | `site.ts`, RLS migrations, `test/isolation.test.ts`, `test/api.test.ts`, `test/stage.test.ts` |
| Request, approval, assignment with transactional stock | `workflow.ts`, `ledger.ts`, `test/workflow.test.ts` |
| Calculated fields (TOTAL = QTY x PRICE) with schema validation | `formula` fields, `packages/compiler/src/expr.ts` |
| Preview, publish, versioned releases, rollback, deploy history | `versions.ts`, `gate.ts`, `replay.ts`; builder Gate, Impact and Versions tabs |
| Per-site analytics (Recharts) | `analytics.ts`, dashboard view |
| Bulk Excel import and export with role restrictions | `excel.ts`, `test/excel.test.ts` |
| Scoped REST APIs incl. login, sites, components, requests, approvals, assignments, Excel export | [docs/API.md](docs/API.md) |
| Architecture diagram, module registry, data model, API design, README | this file, [docs/](docs/) |
| Seeded demo data plus offline backup | `pnpm seed`, `backups/axel-demo.dump`, `restore.ps1` |

---

## Quick start

**Needs:** Docker Desktop, Node.js 20+, pnpm (`npm i -g pnpm`).

**Windows, fresh machine:**
```powershell
powershell -ExecutionPolicy Bypass -File .\first-run.ps1
```
Day to day: `.\start.ps1` and `.\stop.ps1`. Reset the demo data: `.\restore.ps1`.

**macOS / Linux:**
```bash
cp .env.example .env
pnpm install
docker compose up -d db          # wait ~10 s the first time
pnpm migrate && pnpm seed
pnpm dev:api                     # terminal 1
pnpm dev:web                     # terminal 2, then open http://localhost:5173
```

Generate the demo spreadsheets: `pnpm registers` (written to `demo/registers/`).

## Demo accounts (password `demo1234`)

| Email | Role |
|---|---|
| admin@axel.dev | Hub admin, Admin of every unit |
| manager@cs.dev / member@cs.dev | Central Stores |
| manager@sc.dev / member@sc.dev | Service Centre |
| manager@dist.dev / field@dist.dev | Distribution |

The login page has one-click buttons for each. The full stage script is [docs/DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md).

## Tests

With Axel running: `pnpm test` (39 tests).

| Suite | Proves |
|---|---|
| `test:isolation` (11) | Cross-unit reads are 404, writes refused, header must match URL, masked fields never sent or written, another unit's ids look nonexistent, 60 interleaved pooled requests never mix, no context means zero rows, RLS forced on every table |
| `test:workflow` (4) | 50 concurrent approvals vs 10 units, role on transition, stale versions refused, double-click idempotent |
| `test:excel` (4) | Dry-run row errors, all-or-nothing commit, Member cannot import, export follows the role mask |
| `test:api` (4) | Every brief endpoint works for its unit and refuses other units |
| `test:gate` (4) | Unchanged units pass, a leaked price is blocked by a Law, a shortcut that skips approval is caught with a counter-example, publishing without a passing gate is refused |
| `test:replay` (4) | Unchanged drafts replay identically, a stricter rule shows which past requests it blocks, a removed state with records needs a plan, publishing it without one is refused |
| `test:infer` (4) | A repair register infers approval, repair and returns with a mapped formula; a stock sheet infers an inventory site; upload is hub-admin only; members can be managed but nobody changes their own role |
| `test:stage` (4) | Isolation Ledger and its live check, export zip contents, Explain, board history scoped to its unit |

## Project layout

```text
axel/
  packages/compiler/   Blueprint types, expression DSL, diagnostics, validators, render schema, typed ports,
                       module effects, presets, Laws, Sheet Inferencer, Explain, OpenAPI (browser and server)
  apps/api/            Express API: auth, site scope, resources, workflow engine, stock ledger, versions,
                       Release Gate, Replay and Impact, Excel, analytics, members, isolation ledger, live events
    migrations/        PostgreSQL schema with FORCE RLS
    seed/              Three demo units, run through the real workflow engine
    scripts/           Docs and demo-register generators
    test/              39 tests in 8 suites
  apps/web/            React: hub, builder (React Flow), renderer with four layouts
  docs/                Architecture, module registry, sites, data model, API, demo script, diagrams
  demo/registers/      Example spreadsheets for the Sheet Inferencer
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md): Hub, Builder, API, PostgreSQL; request and publish flows
- [Module registry](docs/MODULE_REGISTRY.md): the 13 modules as typed builder nodes (generated by `pnpm docs`)
- [Seeded sites](docs/SITES.md): each unit explained from its Blueprint (generated)
- [Data model](docs/DATA_MODEL.md) and [API](docs/API.md)
- [Demo script](docs/DEMO_SCRIPT.md), with fallbacks and judge Q&A

## Honest scope

Exactly the 13 approved modules; depth over breadth. Not built yet, though the Blueprint and compiler are designed for them: Record mode (derive a workflow by acting it out), an interactive sandbox simulator, generated database columns for formulas, canary releases to selected roles, offline field consumption, and camera scanning of serial labels.
'@

if (-not (Test-Path (Join-Path $PSScriptRoot 'docs/images/architecture.jpeg'))) { Write-Host 'WARNING: docs/images/architecture.jpeg not found' }
if (-not (Test-Path (Join-Path $PSScriptRoot 'docs/images/flow.png'))) { Write-Host 'WARNING: docs/images/flow.png not found' }
Write-Host 'README written.'