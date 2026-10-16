# API

REST over Express, JSON bodies, `Authorization: Bearer <jwt>`. Every site-scoped call also sends `X-Site-Id`, which must equal the `:siteId` in the URL. Errors are `{ code, message, ...details }` with plain-English messages.

**Roles:** Public, Member (create and submit, read), Manager (approve, assign, stock, import), Admin (builder, publish, rollback). Hub admins create sites and run the chaos test.

## Auth and hub

| Method | Path | Who | Notes |
|---|---|---|---|
| POST | `/api/auth/login` | anyone | `{ email, password }` to `{ token, user, memberships }`. Roles are read per request from memberships, never trusted from the token. |
| POST | `/api/auth/refresh` | signed in | new token |
| GET | `/api/me` | signed in | user and memberships |
| GET | `/api/sites` | signed in | sites you belong to, with theme and modules |
| POST | `/api/sites` | hub admin | `{ name, slug, preset? }` creates and publishes a site |
| POST | `/api/sites/infer?name=&slug=&create=` | hub admin; body is the raw .xlsx. `create=false` returns the proposed Blueprint, inferences (rule, confidence, explanation) and diagnostics; `create=true` creates the site and imports the rows |
| GET | `/api/sites/:siteId/members` | Admin: members and roles |
| POST | `/api/sites/:siteId/members` | Admin: `{ email, role, name?, password? }` (creates the account if new) |
| PATCH | `/api/sites/:siteId/members/:userId` | Admin: `{ role }`; changing your own role is refused |
| DELETE | `/api/sites/:siteId/members/:userId` | Admin: remove a member (not yourself) |
| GET | `/api/sites/:siteId/render-schema` | member | the compiled schema the renderer draws, masked for your role |
| GET | `/api/events?token=` | signed in | server-sent events: `site_published`, `record_changed` |
| POST | `/api/hub/chaos` | hub admin | `{ concurrency: 50, stock: 10 }` runs concurrent approvals and verifies the ledger |

## Builder, versions and releases (Admin of the site)

| Method | Path | Notes |
|---|---|---|
| GET | `/api/sites/:siteId/builder` | live version and latest draft |
| GET | `/api/sites/:siteId/versions` | all versions |
| POST | `/api/sites/:siteId/versions` | `{ config }` new draft, returns diagnostics |
| PUT | `/api/sites/:siteId/versions/:v` | `{ config, expectedRev }`, 409 `DRAFT_CONFLICT` if someone saved meanwhile |
| DELETE | `/api/sites/:siteId/versions/:v` | discard a draft |
| POST | `/api/sites/:siteId/publish` | `{ versionId, plans?, replay?, confirm? }`; `plans` maps `entity.state` to `keep` or `map:<state>`;, refused with 422 if the Blueprint has errors, 409 if records would be stranded |
| POST | `/api/sites/:siteId/rollback` | `{ versionId, confirm? }` |
| GET | `/api/sites/:siteId/deployments` | history with proof records |
| POST | `/api/sites/:siteId/versions/:v/replay` | `{ sample? }` replays the last N real requests through the live version and the draft; returns divergences, a summary and the Impact Report |
| GET | `/api/sites/:siteId/versions/:v/impact` | Impact Report of a version against live (additive, behavioural, destructive; plan options for removed states) |
| POST | `/api/sites/:siteId/versions/:v/gate` | `{ steps?, seed? }` runs the Release Gate; returns Laws, counter-example and a sample of the walk. Publish requires a passing run for the exact Blueprint. |

Preview: any GET with header `X-Preview-Version: <draftId>` (Admin only) reads live data through the draft Blueprint. Writes are refused.

## Site resources

| Method | Path | Notes |
|---|---|---|
| GET | `/api/:siteId/components` | modules enabled in this site |
| GET | `/api/:siteId/:entity` | list, `?page&limit&sort&filter[field]=` (entity key or table name, e.g. `requests`) |
| POST | `/api/:siteId/:entity` | create, validated against the role's write mask |
| GET | `/api/:siteId/:entity/:id` | record, `row_version`, and next steps with reasons |
| PATCH | `/api/:siteId/:entity/:id` | `{ ...fields, ifVersion }`, 409 `STALE_RECORD` on mismatch |
| POST | `/api/:siteId/:entity/:id/transition` | `{ to, idempotencyKey, ifVersion?, payload? }` |
| GET | `/api/:siteId/:entity/:id/timeline` | audit events and ledger movements |
| POST | `/api/:siteId/item/:id/stock` | `{ kind: receive or adjust, qty, idempotencyKey }` (Manager+) |
| GET | `/api/:siteId/analytics/:widgetId` | aggregated, respects masks |
| GET | `/api/:siteId/approvals` | decision history |
| POST | `/api/:siteId/approvals` | `{ requestId, decision, note? }` (same engine as transition) |
| GET | `/api/:siteId/assignments` | assignments |
| POST | `/api/:siteId/assignments` | `{ requestId, assignedTo? }` |

## Excel

| Method | Path | Who | Notes |
|---|---|---|---|
| GET | `/api/:siteId/excel/template/:entity` | Member+ | columns you may write, dropdowns for choices and links |
| POST | `/api/:siteId/excel/import/:entity?dryRun=true` | Manager+ | body is the raw .xlsx; returns row-by-row errors |
| POST | `/api/:siteId/excel/import/:entity?dryRun=false` | Manager+ | all-or-nothing |
| GET | `/api/:siteId/excel/export/:entity` | Member+ | columns follow your read mask; an About sheet lists hidden columns |

## Error codes

`UNAUTHENTICATED`, `NOT_FOUND`, `NO_MEMBERSHIP`, `FORBIDDEN`, `SITE_HEADER_MISMATCH`, `ENTITY_NOT_IN_SITE`, `VALIDATION_FAILED`, `FIELD_NOT_WRITABLE`, `FIELD_HIDDEN`, `TRANSITION_NOT_ALLOWED`, `GUARD_FAILED`, `INSUFFICIENT_STOCK`, `NO_RESERVATION`, `LAW_VIOLATION`, `STALE_RECORD`, `DRAFT_CONFLICT`, `VERSION_IMMUTABLE`, `GATE_NOT_PASSED`, `DESTRUCTIVE_CHANGE_UNPLANNED`, `ALREADY_LIVE`, `PREVIEW_READ_ONLY`, `DUPLICATE`.

## Example

```bash
TOKEN=$(curl -s localhost:4000/api/auth/login -H 'content-type: application/json' \
  -d '{"email":"manager@sc.dev","password":"demo1234"}' | jq -r .token)
SC=22222222-2222-4222-8222-222222222222
curl -s localhost:4000/api/$SC/requests -H "authorization: Bearer $TOKEN" -H "x-site-id: $SC"
```
