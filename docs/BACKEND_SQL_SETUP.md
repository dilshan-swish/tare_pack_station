# SWiSH Weighing Platform — SQL Server Setup Guide

This is the central store for the weight configuration and the weigh telemetry.
Head office configures weights here; store tablets read from it (through the Web
API) and send back weigh events. Build it on your laptop first, then move it to
the on-prem server unchanged.

---

## 1. What the database holds

| Table | Purpose |
|-------|---------|
| **Brands** | One row per Foodics brand (BBT, etc.). Holds the published-version counter. |
| **Branches** | Stores under each brand — used for telemetry and connectivity. |
| **Devices** | The tablets. Each has an API key (hashed) and a last-seen time. |
| **MenuItems** | Menu items per brand, keyed by Foodics product id, with **Min/Max weight** + packaging. `NULL` weight = *not configured*. |
| **Modifiers** | Modifiers per brand, keyed by Foodics modifier id, with a weight. |
| **MenuItemModifiers** | Which modifiers belong to which item (for the admin screen). |
| **WeighEvents** | Every weigh: expected range, measured, verdict, override reason. Feeds the dashboards + AI training. |
| **ConfigPublications** | Audit of each "publish" so tablets know when to re-sync. |
| **AdminUsers** | Optional — head-office logins (or use your existing AD/SSO instead). |

Weights are **per brand**, not per store — configure once, every store of that
brand uses it. Weights are stored as **Min/Max grams** only (no standard
deviation).

---

## 2. Create it in SSMS (laptop test)

> **Run the actual `.sql` files in `docs/sql/`** — this markdown no longer
> embeds a copy of the schema (see the note in section 4 below for why).

1. Install **SQL Server 2022 Developer edition** (free) + **SQL Server Management
   Studio (SSMS)**.
2. Open SSMS → connect to `localhost` (or `.\SQLEXPRESS`). Make sure this login
   is an **admin** (sysadmin / `sa`) — creating a database needs it.
3. Open **`docs/sql/DEPLOY_FULL.sql`** → **Execute** (F5). This creates the
   `SwishWeighing` database (if it doesn't exist yet) and every table, index,
   and the coverage view in one pass — this ONE file replaces running
   `00_create_database.sql` + `01_schema.sql` + every incremental
   `02_*.sql` through `13_*.sql` file individually. Safe to re-run.
4. Refresh Object Explorer to see the tables.

For the full production rollout (SQL Server + the API + the portal + the
tablet app, atomic steps, credentials, everything), see
**`docs/PRODUCTION_DEPLOYMENT_GUIDE.md`** — this file stays focused on just
the database.

### Troubleshooting

| Error | Cause & fix |
|-------|-------------|
| `Incorrect syntax near '`'` | You pasted the markdown ``` fences. Run the `.sql` files in `docs/sql/` instead. |
| `CREATE DATABASE permission denied in database 'master'` | Your login can't create databases. Connect as `sa`/sysadmin, or have your DBA create an empty `SwishWeighing` DB and grant you `db_owner`, then skip file `00`. |
| `There is already an object named 'Brands'…` + FK errors on `BrandId` | The database create failed, so the script ran in an **existing database** that already has those table names. **Those are not ours — don't drop them.** Create the dedicated `SwishWeighing` DB and run `01_schema.sql` inside it. |

Confirm you're in the right database any time with: `SELECT DB_NAME();` (should
return `SwishWeighing`).

Local connection string the API will use:

```
Server=localhost;Database=SwishWeighing;Trusted_Connection=True;TrustServerCertificate=True;
```

---

## 3. Move it to the on-prem server later

Pick one (option A is simplest):

**A. Backup / restore (recommended)**
1. SSMS → right-click `SwishWeighing` → *Tasks → Back Up…* → creates a `.bak`.
2. Copy the `.bak` to the on-prem server.
3. On the server: right-click *Databases → Restore Database… → Device →* select
   the `.bak` → restore. Done — schema **and** data move together.

**B. Generate scripts (schema only)**
Right-click the DB → *Tasks → Generate Scripts…* → choose *Schema and data* if
you also want the rows → run the produced `.sql` on the server.

**C. DACPAC (for repeatable deploys)**
Use *Tasks → Extract Data-tier Application* to make a `.dacpac`, then
`SqlPackage /Action:Publish` on the server. Best once you're doing regular
releases.

After moving, only the API's connection string changes (point it at the on-prem
server + a SQL login). Nothing else changes.

---

## 4. The schema script

**This section used to embed a full copy of the schema inline — that copy
silently drifted out of date as the schema grew (11 migrations' worth of
columns and a whole extra table were missing from it) and was removed for
exactly that reason: a second copy of the schema will always eventually
disagree with the real one.** There is now exactly one place the schema
lives: **`docs/sql/DEPLOY_FULL.sql`** — open that file directly, it's fully
commented and current as of migration 13. Run it as described in section 2
above.

---

## 5. How the app uses it (once the API is in place)

- **Foodics ingest** (scheduled) → upserts `MenuItems` / `Modifiers`; new rows land
  with `NULL` weight (= *not configured*).
- **Admin web app** → sets `MinWeightG` / `MaxWeightG` / `Modifiers.WeightG`, then
  **Publish** bumps `Brands.PublishedVersion` and logs to `ConfigPublications`.
- **Tablet** → pulls the published config for its brand; if it sees any item with
  a `NULL` weight it shows the **"weight not configured"** warning (already built)
  instead of guessing.
- **Tablet** → posts each weigh to `WeighEvents` for the dashboards and AI
  training.

> Note: `MinWeightG`/`MaxWeightG` here map 1:1 to the app's existing
> `minWeightGrams`/`maxWeightGrams` range model — so the tablet needs no model
> change, only a new data source (the API instead of the bundled file).
