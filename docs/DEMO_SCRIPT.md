# Demo script (about 8 minutes)

## Before you go on stage

1. `.\restore.ps1` (clean demo data), then `.\start.ps1`.
2. Browser window A (normal): log in as **Hub admin**.
3. Browser window B (incognito): log in as **Distribution field member** (`field@dist.dev`), open Distribution, leave it on screen.
4. Have `apps/api/test` results ready: run `pnpm test` once so the terminal shows all tests passing.
5. Keep a screen recording of this script as a last resort.

## Brief step 1: one login, three units (1 min)

- Window A: the hub lists Central Stores, Distribution and Service Centre, with the Reuse meter ("27 module instances, 13 implementations").
- Open each unit. Point out that the **layout** changes, not just the colour: dark sidebar with analytics, teal kanban board, amber work queue.
- Press **Ctrl+K** and switch rapidly. No row from one unit ever appears under another.

*Say:* "One login, one codebase. Each unit is a Blueprint; the same renderer draws all of them."

## Brief step 2: two different working systems (2 min)

- **Service Centre:** drag a Submitted card to Approved. Open it: the timeline shows the step and the stock reservation. Start repair commits the stock; a repair log opens.
- **Central Stores:** the stock register with available, reserved and stock value; the Overview dashboard.
- Hub: click **Run chaos**. 50 concurrent approvals against 10 units: exactly 10 succeed, and the ledger matches.

*Say:* "Stock is a ledger with row locks and idempotency keys. It cannot go inconsistent."

## Brief step 3: enable Returns on Distribution with no code (2 min)

- Window A: Hub, Distribution card, **Builder**.
- Drag **Return Management** onto the canvas. It connects itself to Material Assignment; Problems shows none.
- Optional: drag **Approval** into Central Stores' builder first to show "Approval requires Request" and the one-click fix.
- Click **Publish**. Window B (field member) shows "This site was just updated" and a new **Returns** link, with no reload and no restart. Closed requests now have a Return button.
- Versions tab: the deploy history with proof; roll back and forward if time allows.

*Say:* "Typed ports stop invalid systems. Publish is live. Rollback never deletes data."

## Brief step 4: Excel with role rules (1.5 min)

- As `manager@cs.dev`, Central Stores, Stock register: **Template** (dropdowns), fill two rows with one missing SKU, **Import**, **Check file**: the row is reported. Fix, import; stock appears through the ledger.
- **Export**: includes Unit price and Stock value.
- As `member@cs.dev`: **Export** has no price columns (About sheet says why); **Import** is refused by the server with an explanation.

## Close: prove isolation (1 min)

- Show the terminal with `pnpm test` all green, or run `pnpm test:isolation` live (about 4 seconds).
- Explain: FORCE RLS, composite keys, transaction-local site context, 404-not-403, cache wipe on switch.

## Fallbacks

| If | Do |
|---|---|
| Data looks wrong | `.\restore.ps1` then `.\start.ps1`, log in again |
| A page is empty after a reset | Log out and log in again |
| The API window shows a database error | Docker Desktop is not running: start it, then `.\start.ps1` |
| Laptop fails | Play the screen recording |

## Likely judge questions

| Question | Answer |
|---|---|
| How is this different from Retool or Odoo? | Sites are Blueprints compiled by one engine; typed modules cannot be wired wrongly; publish is live and reversible; isolation is enforced by the database and tested. |
| Can a non-developer use it? | Drag a module, read plain-English problems, click Fix, Publish. No JSON needed (the JSON tab is optional). |
| What if two managers approve at once? | The chaos test: row locks on request and item, idempotency keys. Exactly the available quantity succeeds. |
| What if stock is approved but never issued? | Reservations expire; stock is released and the request goes back for re-approval. |
| Prove isolation. | `pnpm test:isolation`, plus 404 for any other unit's data and RLS forced on every table. |
| Scope? | Exactly the 13 approved modules; depth over breadth. |
