# Architecture

Axel has one codebase. The only thing that differs between sites is the **Blueprint**, a JSON document stored per version in `site_versions.config`. The compiler is a shared TypeScript package, so the problems an admin sees on the builder canvas are exactly what the API would reject.

## Hub, Builder, API, PostgreSQL

```mermaid
flowchart TB
  HUB["Hub<br/>one login, site switcher, theme engine, module catalogue, chaos test"]
  BUILDER["Builder (Forge)<br/>React Flow canvas, typed ports, presets, fields, theme, JSON, versions"]
  API["API (Node / Express)<br/>/api/:siteId/:resource, workflow engine, stock ledger, publish, Excel"]
  PG["PostgreSQL 16<br/>FORCE RLS on site_id, composite FKs, ledger, versions, audit"]
  HUB --> BUILDER --> API --> PG
```

## Components

```mermaid
flowchart LR
  subgraph Browser["Browser (React, one app)"]
    H["Hub shell"]
    F["Builder"]
    R["Renderer<br/>4 layouts, table, kanban, queue, dashboard, forms"]
  end
  subgraph Shared["@axel/compiler (shared TypeScript)"]
    C["Blueprint to diagnostics, validators,<br/>render schema, masks, formulas, typed ports"]
  end
  subgraph Server["API"]
    MW["JWT, membership, Blueprint, transaction with site context"]
    WF["Workflow engine"]
    LG["Stock ledger"]
    VR["Versions, publish, rollback"]
    XL["Excel"]
    EV["Live events (SSE)"]
  end
  subgraph DB["PostgreSQL"]
    T["Business tables (RLS)"]
    SM["stock_movements"]
    V["site_versions, site_deployments"]
    A["audit_events"]
  end
  H --> MW
  R --> MW
  F --> VR
  F -.-> C
  MW -.-> C
  MW --> WF --> LG --> SM
  MW --> T
  MW --> XL --> T
  WF --> A
  VR --> V
  VR -- "NOTIFY site_published" --> EV --> R
```

## The three layers from the brief

| Brief layer | In Axel |
|---|---|
| Hub layer | JWT login (bcrypt), memberships per site, roles Public/Member/Manager/Admin, site switcher with cache wipe, theme engine (CSS variables plus four layout shells), module catalogue in the builder palette |
| Site layer | Blueprint `{ siteId, slug, name, theme, modules, entities, workflows, laws, pages, roles, nav, edges }` |
| Module and node layer | 13 registry entries with typed input/output ports and dependencies; adding a module applies its effects (states, steps, entities, pages) to the Blueprint |

## A request that changes stock

```mermaid
sequenceDiagram
  participant U as Manager (browser)
  participant A as API
  participant P as PostgreSQL
  U->>A: POST /api/:siteId/requests/:id/transition (to approved)
  A->>A: verify JWT, read role from memberships, load published Blueprint
  A->>P: BEGIN and set_config app.site_id (transaction-local)
  A->>P: SELECT request FOR UPDATE
  A->>P: check idempotency key and row_version
  A->>P: SELECT item FOR UPDATE, evaluate guard
  A->>P: INSERT stock_movements reserve, UPDATE items reserved
  A->>P: UPDATE request state, INSERT approvals and audit_events
  A->>P: COMMIT
  A-->>U: 201 with the record and its next steps
```

Two approvals for the same request serialise on the request row lock; the second sees the new state and is refused. Approvals for different requests on the same item serialise on the item row lock, so reserved stock can never exceed on-hand stock.

## Publishing a change

```mermaid
sequenceDiagram
  participant B as Builder
  participant A as API
  participant P as PostgreSQL
  participant W as Open site windows
  B->>A: POST /api/sites/:id/publish (draft version)
  A->>A: compile Blueprint, refuse if any error
  A->>P: count records in states the new version removes
  A->>P: archive old version, publish new, INSERT site_deployments with proof
  A->>P: NOTIFY site_published
  P-->>A: notification
  A->>A: drop cached Blueprint
  A-->>W: server-sent event site_published
  W->>A: refetch render schema, re-render (no reload)
```

Rollback is the same path pointed at an earlier version. Data is never deleted: fields a version does not know are hidden, not dropped.

## Isolation in three layers

1. **Database.** Every business table has `site_id`, `ENABLE` and `FORCE ROW LEVEL SECURITY`, and a policy comparing it to `app.site_id`. The API connects as `axel_app`, which owns nothing and cannot bypass RLS. Context is set with `set_config(..., true)` inside each transaction, so pooled connections never carry a stale site; with no context, queries return zero rows. Foreign keys are composite `(site_id, id)`, so a row cannot reference another site's row, and another site's id looks exactly like a missing id.
2. **API.** Middleware checks the JWT, the membership for that site and that `X-Site-Id` matches the URL. Reads of other sites return 404 so existence is not leaked. Bodies are validated against the Blueprint's per-role write mask; responses are filtered by the read mask.
3. **Client.** Every query key starts with the entity and site id; switching sites removes cached queries and discards any response that started before the switch.

## Design decisions

- **Shared tables with RLS, not a schema per site.** One codebase and hot publish need shared tables; FORCE RLS plus composite keys gives isolation without per-site migrations.
- **Compile first.** The same compiler runs in the browser (instant feedback) and the server (source of truth).
- **Ledger, not counters.** On-hand and reserved stock are only changed by ledger operations under row locks, with idempotency keys, and can be recomputed from `stock_movements`.
- **Server-sent events for live updates.** One direction is all that is needed; no extra dependency.
