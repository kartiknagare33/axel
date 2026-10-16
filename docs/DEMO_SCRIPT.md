# Demo script (about 8 minutes)

## Before you go on stage

1. `.\restore.ps1` (clean demo data), then `.\otp-mode.ps1 live` (real WhatsApp code for the admin; it restarts Axel).
2. Browser window A (normal): log in as **Hub admin**, type the code from WhatsApp. Log in once only: live mode allows 3 codes per 10 minutes.
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

## The Release Gate (1.5 min)

- Central Stores builder: click the **Inventory** node. On **unit_price**, click **Member: hidden** so it says **Member: sees**.
- Click **Run gate**: **BLOCKED**, "Law l3: Members never see Unit price". Click **Undo**, run again: **PASSED**.
- Distribution builder, **JSON** tab: inside `"transitions"` of `request`, add
  `{ "id": "t99", "from": "submitted", "to": "assigned", "label": "Fast-track", "roles": ["Manager", "Admin"] },`
  then **Apply JSON**, **Gate** tab, choose **1000 steps**, **Run gate**: BLOCKED with a counter-example such as "Law l2 broken at step 37: Assignment ... was created for a request that never became 'approved'", and the steps that led there.
- Undo or Discard.

*Say:* "Nobody tests by hand. The gate acts out hundreds of random sessions on real data, rolls everything back, and refuses to publish anything that breaks a rule."

## Replay and Impact (1.5 min)

- Service Centre builder, **Workflow** tab: on **Approve**, type the rule `qty <= 1` and click elsewhere.
- **Impact** tab, **Run replay and impact**: "N of 50 past requests go exactly the same way", plus the requests the new rule would block and at which step. Click **Undo**.
- Distribution (after enabling Returns and returning one request): **Versions** tab, **Roll back to this version** on the version before Returns. The Impact list shows "1 request(s) are in 'returned', which this version removes". Choose **Move these records to 'closed'** and **Roll back now**. The record moves, the timeline records it, nothing is deleted.

*Say:* "We test changes against what actually happened, not against what we imagine. And no rollback ever loses data."

## A fourth unit from a spreadsheet (1.5 min)

- Hub, **+ From a spreadsheet**, choose `demo/registers/Workshop_Tools.xlsx` (or a judge's own register), **Read spreadsheet**.
- Walk through a few inferences: the Tool column became the item list, Status values became the workflow, "Returned On" enabled Return Management, unit prices are hidden from Members by default. Point at the confidence bars.
- **Create unit**. The builder opens on the new unit with its rows already imported. **People** tab: add `member@cs.dev` as Member; in the second window that user now sees the new unit on the hub.

*Say:* "We did not design this site. We read the spreadsheet the unit already keeps, and every guess is explained."

## Brief step 4: Excel with role rules (1.5 min)

- As `manager@cs.dev`, Central Stores, Stock register: **Template** (dropdowns), fill two rows with one missing SKU, **Import**, **Check file**: the row is reported. Fix, import; stock appears through the ledger.
- **Export**: includes Unit price and Stock value.
- As `member@cs.dev`: **Export** has no price columns (About sheet says why); **Import** is refused by the server with an explanation.

## Close: prove isolation and zero lock-in (1 min)

- Hub, **Isolation Ledger**: every table shows RLS enabled and forced, composite keys, and the API role cannot bypass RLS and owns no tables. Click **Run live isolation check**: every pair of units reads 0 rows of the other, writes across units are refused, 30 parallel pooled requests never mix.
- Any builder, **Export**: a zip with the Blueprint, a plain-language README, OpenAPI, all data as Excel and the deploy history with proofs. "You can leave any time."
- Service Centre, **Board history**: type a serial such as `PCB-24001` to see the whole life of one board.

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
| How does login work? | Password (bcrypt), then a one-time code through MiniMoth on WhatsApp with SMS fallback. Only then do we issue our JWT, which carries roles and allowed sites; the server still re-checks them on every request. |
