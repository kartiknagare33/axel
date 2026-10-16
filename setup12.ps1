# Replace the "What is new here" section of README.md with a bullet-point version.
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'README.md'
$text = [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n")

$new = @'
## What is new here

Most platforms help you *build* a site. Axel focuses on what they leave to luck: **deriving** the site from what a unit already does, and **proving** every change is safe before it goes live.

| # | Novelty | In one line | Try it |
|---|---|---|---|
| 1 | Sheet Inferencer | Upload a unit's spreadsheet, get a working site with every guess explained | Hub, + From a spreadsheet |
| 2 | Laws + Release Gate | Rules in plain sentences, proven by a random walk before publish | Builder, Run gate |
| 3 | Replay Report | A change is tested against the last 50 real requests | Builder, Impact |
| 4 | Data-preserving rollback | Roll back with a plan for records created since | Builder, Versions |
| 5 | Proof-carrying releases | Every deployment stores why it was allowed | Builder, Versions |
| 6 | Reservation ledger | Stock reserved, committed, expired; proven under 50 concurrent approvals | Hub, Run chaos |
| 7 | Live isolation proof | Tenant isolation checked live from PostgreSQL's own catalog | Hub, Isolation Ledger |
| 8 | Typed-port builder | Wrong wiring is impossible; one compiler in browser and server | Builder canvas |
| 9 | Explained denials | Every refusal says why and who decided | Anywhere |
| 10 | Zero lock-in | Export Blueprint, docs, OpenAPI, data and history as a zip | Builder, Export |

### 1. Sheet Inferencer: the site is derived, not designed

- **Gap:** every builder starts from a blank canvas, so a process owner still needs someone technical.
- **What it does:**
  - Finds the stock list and the request register in the workbook.
  - Infers field types, money columns and choice lists (from dropdowns or repeated values).
  - Turns sheet formulas into calculated fields: `=D2*I2` becomes `qty * unit_price`.
  - Turns the **Status column into a workflow**: "Sanctioned" is read as approved, "Repairing" as in repair, "Issued" as assigned.
  - Enables modules from the columns it finds: "Approved by" enables Approval, "Serial No" enables PCB Repair, "Returned On" enables Returns.
  - Proposes Laws, pages and a layout, then imports the rows (opening stock through the ledger).
- **Why trust it:**
  - Every guess shows a **confidence %** and a **plain-English reason**.
  - Low-confidence guesses are highlighted as "check this".
  - Rule-based and deterministic: no AI service, no internet, same file gives the same site.
- **Try it:** Hub, **+ From a spreadsheet**, `demo/registers/Workshop_Tools.xlsx`. **Test:** `test:infer`

### 2. Laws and the Release Gate: nothing publishes without evidence

- **Gap:** low-code tools publish whatever the admin clicks; users find the mistakes.
- **Laws are rules in plain sentences**, for example:
  - "Members never see Unit price"
  - "Every Assignment comes from a request that was approved"
  - "Reserved stock never exceeds on-hand stock"
  - "This site never reads another site's data"
- **The Release Gate runs before every publish:**
  - **Compile:** zero errors allowed.
  - **Static check:** Laws checked against the Blueprint, for example a calculated field that would leak a hidden price.
  - **Random walk:** hundreds to thousands of actions as Members, Managers and Admins on **real data**, in a transaction that is always rolled back; every Law checked after every step.
- **If a Law breaks:** publish is blocked and the builder shows a **counter-example** (the exact steps that broke it) plus a **seed** to replay it.
- **Try it:** add a "Fast-track" step from submitted to assigned, then **Run gate**. You get "Law l2 broken at step 37". **Test:** `test:gate`

### 3. Replay Report: tested against what actually happened

- **Gap:** a "small" rule change can silently block real work.
- **What it does:**
  - Takes the last 50 real requests and their recorded history (same steps, same roles).
  - Replays them through the **live version** and the **draft**, side by side, in a rolled-back transaction.
  - Lists every request that would now go differently, and at which step.
- **Example output:** "3 of 50: submitted > approved would be blocked by a rule (today: allowed)".
- **Try it:** Service Centre builder, Workflow tab, give Approve the rule `qty <= 1`, then **Impact**. **Test:** `test:replay`

### 4. Impact Report and data-preserving rollback

- **Gap:** platforms roll back configuration but lose or orphan the data created since.
- **What it does:**
  - Classes every change as **additive**, **behavioural** or **destructive**, with live record counts.
  - If a removed state still holds records, publish **or rollback** needs a plan per state:
    - keep those records read-only, or
    - move them to another state (written to the audit trail).
  - Removed fields are hidden, never dropped.
  - Rollbacks run a short Release Gate on the older version too.
- **Try it:** Distribution: enable Returns, return one request, roll back, and choose "Move to closed". **Test:** `test:replay`

### 5. Proof-carrying releases

- Every deployment stores a **proof record**:
  - Blueprint content hash
  - gate steps, seed and result
  - replay summary and whether it was reviewed
  - plans chosen and the list of changes
- The deploy history records **why** each version was allowed live, not just **when**.

### 6. Reservation ledger with expiry, proven under concurrency

- **Gap:** counters get double-spent when two managers approve at once, and approved-but-unused stock stays locked forever.
- **What it does:**
  - Stock is an **append-only ledger**: receive, adjust, reserve, commit, release, return.
  - Approve **reserves**, assign or repair **commits**, return **gives back**.
  - Row locks on request and item, plus **idempotency keys**: a double-click is a no-op.
  - Stale screens are refused: "this record changed since you opened it".
  - **Reservations expire**: stock is released and the request goes back for re-approval.
- **Proof:** **Run chaos** fires 50 concurrent approvals at 10 units. **Exactly 10 succeed**, 40 are refused, and the ledger matches. **Test:** `test:workflow`

### 7. Isolation you can watch being proven

- **Gap:** row-level security leaks through forgotten FORCE, owner bypass, pooled connections, and foreign keys that reveal other tenants' rows.
- **What Axel does:**
  - FORCE RLS on every business table.
  - API database role **cannot bypass RLS** and **owns no tables**.
  - Site context is per transaction: no context means **zero rows**.
  - Composite `(site_id, id)` foreign keys: another unit's id looks exactly like a missing one.
  - Other units' data returns **404, never 403**.
  - The browser wipes its cache on every switch and drops late responses.
- **Try it:** Hub, **Isolation Ledger** (read live from PostgreSQL), then **Run live isolation check**. **Tests:** `test:isolation`, `test:stage`

### 8. Typed-port builder, one compiler everywhere

- Modules are nodes with **typed ports**: Approval needs a RequestStream; Material Assignment needs an ApprovedStream and a StockLedger.
- Wrong wiring or missing modules become plain-English problems ("Approval requires Request") with **one-click fixes**.
- Adding a module **changes the site**: Return Management adds a Return step, a Returns page and a stock action.
- Browser and API run the **same compiler**, so what the canvas accepts is exactly what the server accepts.
- Publishing is **live**: open windows re-render with no reload and no restart.

### 9. Explained denials everywhere

- "Only Manager, Admin can approve in Service Centre (transition t2)"
- "Approve blocked: available stock for SC-104 is 3, rule 'stock.available(item_id) >= qty' is not met"
- "You can't see Unit price in Central Stores (cost confidential). Ask a Manager."
- A Member's Excel export includes an **About** sheet listing the columns hidden from them.

### 10. Zero lock-in

- **Export** downloads a zip with:
  - `blueprint.json`
  - a generated plain-language `README.md` (**Explain**)
  - `openapi.json` (OpenAPI 3.1)
  - `data.xlsx` with all records
  - `deployments.json` with every proof record

---

'@

$pattern = '(?s)## What is new here.*?(?=## How Axel compares)'
if (-not [regex]::IsMatch($text, $pattern)) { throw 'Could not find the "What is new here" section. Run setup11.ps1 first.' }
$text = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $new.Replace("`r`n", "`n") })
[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
Write-Host 'README updated: "What is new here" is now bullet points.'