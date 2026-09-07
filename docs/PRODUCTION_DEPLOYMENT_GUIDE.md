# SWiSH Weighing — Production Deployment Guide

End-to-end guide for hosting the full system on a company server: **SQL
Server** (data), the **backend API** (ASP.NET Core 8), the **admin portal**
(React, static files), and provisioning the **tablet app** (Flutter/Android)
against it. Written for a Windows Server (or a dedicated Windows PC acting
as one) — everything in this repo assumes Windows (SQL Server, PowerShell,
IIS) throughout.

Every command below was actually run and verified against this codebase
while writing this guide — none of it is untested boilerplate. Where a step
can't be verified without your real server/domain, that's called out
explicitly.

---

## 1. Architecture — who talks to whom

```
 Foodics (cloud)  <----HTTPS---->  Backend API  <----SQL---->  SQL Server
                                   (ASP.NET Core,                (SwishWeighing DB)
                                    Windows Service)
                                        ^
                                        | HTTPS + X-Api-Key / X-Device-Key
                          ______________|______________
                         |                              |
                   Admin Portal                    Tablet App
                (static files, browser,          (Flutter/Android,
                 any PC on the network)          one per pack station)
```

- The **backend API** is the only thing that talks to SQL Server and to
  Foodics. Neither the portal nor the tablets ever do.
- The **portal** is a static single-page app — it needs nothing installed
  server-side beyond a place to host static files (IIS, or literally any
  web server). It only ever calls the backend API over HTTP(S).
- The **tablet app** is an Android app installed on each pack-station
  tablet. It only ever calls the backend API too.
- The backend's own background sweep (catalog auto-sync — see
  `FoodicsAutoSyncHostedService`) needs the API process to simply stay
  running continuously — that requirement drives the hosting choice in
  Part B.

---

## 2. What you need — platform checklist

On the server:
- **Windows Server 2019/2022** (or Windows 10/11 Pro if it's a dedicated PC — anything that can stay powered on continuously).
- **SQL Server** — Express edition is enough for this workload (confirmed against this exact schema; see Part 3). Standard/Enterprise work identically if you already have one.
- **SQL Server Management Studio (SSMS)** — for the one-time schema setup and any manual DB work.
- **.NET 8 Runtime** (or the ASP.NET Core Hosting Bundle if you'll also use IIS — see 4.4) — to run the backend.
- **IIS** (Web Server role) — only needed if you want IIS to host the portal's static files and/or terminate HTTPS in front of the API. Not required to run the API itself (Part 4 uses a Windows Service instead).
- **URL Rewrite Module for IIS** (separate Microsoft download, not bundled with IIS) — required if IIS hosts the portal, so client-side routes like `/tablets` don't 404 on refresh.

On a build machine (can be your own laptop — nothing below needs to run *on* the server):
- **.NET 8 SDK** — to `dotnet publish` the API.
- **Node.js 18+** — to build the portal (`npm run build`).
- **Flutter SDK + Android SDK** — to build the tablet app APK.

For each tablet:
- An Android tablet, 8–10" recommended (matches the app's design target), with USB debugging enabled for the initial install (or an MDM tool if you're provisioning many at once).

---

## 3. Part A — SQL Server

### 3.1 Install SQL Server + SSMS (skip if you already have one)

Install **SQL Server 2022** (Express is fine) and **SQL Server Management
Studio**. Standard install options are fine — no special configuration
needed for this schema.

### 3.2 Run the schema script

Everything the database needs — every table, column, index, and the one
view — is in a single file: **`docs/sql/DEPLOY_FULL.sql`**.

This file was tested three separate ways while writing this guide, so it's
safe to run as-is:
1. Against a completely fresh, empty database — zero errors, every object created.
2. Run a **second time** immediately after — zero errors, confirmed idempotent (nothing re-created, nothing duplicated).
3. Run against the real, already-populated development database — zero errors, and confirmed via direct row counts that no existing data was touched.

Run it as a login with rights to create a database (`sa`, or a login in the
`sysadmin` role):

```
sqlcmd -S <your-sql-server-instance> -E -C -i "docs\sql\DEPLOY_FULL.sql"
```

(`-E` = Windows auth; if you're using SQL auth instead, use `-U <login> -P
<password>`. `-C` trusts the server certificate — fine for an internal
server.)

Or in SSMS: open `docs/sql/DEPLOY_FULL.sql` and hit **Execute (F5)**. You
should see, as the final output:
```
SwishWeighing schema is fully up to date (through migration 13).
```

If your login can't create databases, you'll see a clear error telling you
so — either connect as `sa`, or have a DBA create an empty `SwishWeighing`
database and grant you `db_owner` on it first, then re-run.

### 3.2b Failsafe deployment: backup, verify, and the real rollback plan

`DEPLOY_FULL.sql` isn't wrapped in one big transaction — on SQL Server,
`CREATE DATABASE` can never run inside a transaction at all, and every
statement in the file is already individually atomic (a `CREATE TABLE`
either fully succeeds or fully fails, never partially). Combined with the
guarantees from 3.2 (additive-only, every create/alter guarded, no DROP/
TRUNCATE/DELETE), the real rollback story for a mid-run failure is: **read
the error, fix whatever caused it, and re-run the whole file** — everything
already created is skipped, only the failed step (and anything after it)
actually runs. `SET XACT_ABORT ON` (already at the top of the file) makes
sure a failing statement never lets a later statement in the same batch run
past it unnoticed.

What a re-run *can't* undo is a mistake made outside this script — by hand
in SSMS, or a genuinely bad idea that got scripted correctly. For that, take
a full backup immediately before deploying, and — this is the "tested and
verified" part — actually prove it restores, rather than trusting it blind:

```sql
-- 1) Back up (skip this for a brand-new, empty database — nothing to lose yet)
BACKUP DATABASE SwishWeighing
TO DISK = N'C:\SQLBackups\SwishWeighing_pre_deploy.bak'
WITH INIT, CHECKSUM, STATS = 10;

-- 2) Prove the backup file itself isn't corrupt
RESTORE VERIFYONLY FROM DISK = N'C:\SQLBackups\SwishWeighing_pre_deploy.bak';

-- 3) Find the backup's logical file names (yours may differ from the example below)
RESTORE FILELISTONLY FROM DISK = N'C:\SQLBackups\SwishWeighing_pre_deploy.bak';

-- 4) Actually restore it into a THROWAWAY database and confirm real data comes back —
--    replace the two logical names below with whatever step 3 printed.
RESTORE DATABASE SwishWeighing_RestoreTest
FROM DISK = N'C:\SQLBackups\SwishWeighing_pre_deploy.bak'
WITH MOVE 'SwishWeighing'     TO 'C:\SQLData\SwishWeighing_RestoreTest.mdf',
     MOVE 'SwishWeighing_log' TO 'C:\SQLData\SwishWeighing_RestoreTest_log.ldf',
     REPLACE;

SELECT COUNT(*) FROM SwishWeighing_RestoreTest.dbo.Brands;  -- confirm real rows came back
DROP DATABASE SwishWeighing_RestoreTest;                    -- clean up the scratch copy
```

Only once that dry-run restore has actually printed real row counts back at
you do you have a *proven*, not assumed, rollback point. Now run
`DEPLOY_FULL.sql` (3.2) as normal.

If something ever goes wrong badly enough that a re-run genuinely can't fix
it (this has not happened in any of the three verified test runs, but the
plan should exist regardless), the real rollback is restoring that backup
over the live database:

```sql
ALTER DATABASE SwishWeighing SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE SwishWeighing
FROM DISK = N'C:\SQLBackups\SwishWeighing_pre_deploy.bak'
WITH REPLACE;
ALTER DATABASE SwishWeighing SET MULTI_USER;
```

This document can give you the exact commands and explain why they work —
it can't run them against your real server for you. Run the backup +
dry-run-restore once yourself, for real, before the first production
deploy, so you know — not assume — that it works in your environment.

> **No stored procedures, functions, or triggers exist in this schema, and
> none are added by this script — deliberately.** The "periodic sweep" that
> keeps the menu synced with Foodics runs *inside the API process itself*
> (Part 4.6), not as a SQL Server Agent job. That also matters concretely
> if you're on SQL Server **Express**: Express edition has no SQL Server
> Agent at all, so a job-based approach wouldn't even be possible there.

### 3.3 Create a least-privilege login for the API

Don't point the production API at `sa` or Windows-trusted auth. Create a
dedicated SQL login the API uses, with only the access it actually needs
(the API only ever does CRUD at runtime — schema changes only ever happen
via `docs/sql/*.sql`, run by you):

```sql
USE SwishWeighing;
GO
CREATE LOGIN swish_api WITH PASSWORD = '<a-long-random-password>';
GO
CREATE USER swish_api FOR LOGIN swish_api;
GO
ALTER ROLE db_datareader ADD MEMBER swish_api;
ALTER ROLE db_datawriter ADD MEMBER swish_api;
GO
```

Note the connection string you'll use for this (Part 4.3):
```
Server=<your-sql-server-instance>;Database=SwishWeighing;User Id=swish_api;Password=<that-password>;TrustServerCertificate=True;
```

### 3.3b Bringing over your existing dev-database catalog

If you've already been configuring real brands, menu items, modifiers, and
their weights against a dev/local database, you don't need to re-enter any
of it by hand — bring the actual rows over instead. This covers exactly
`Brands`, `Modifiers`, `MenuItems`, `MenuItemModifiers`, and
`ModifierCombinationWeights` (menu/modifier configuration only) — never
`Branches` (created fresh by the Foodics sync — see 4.4), and never
`WeighEvents`/`Devices`/anything else operational.

**On your dev machine**, in SSMS: right-click your dev `SwishWeighing`
database → **Tasks → Generate Scripts…** → Next → **"Select specific
database objects"** → expand **Tables** and tick only:
`dbo.Brands`, `dbo.Modifiers`, `dbo.MenuItems`, `dbo.MenuItemModifiers`,
`dbo.ModifierCombinationWeights` — Next → on "Set Scripting Options" click
**Advanced** → find **"Types of data to script"** and change it from
*Schema only* to **Data only** → set an output file path → OK → Next →
Next → Finish. SSMS writes one `.sql` file with plain `INSERT` statements,
automatically wrapped in `SET IDENTITY_INSERT ... ON/OFF` per table — the
exact same `BrandId`/`MenuItemId`/`ModifierId` values carry over, so every
cross-table reference stays valid with nothing to remap.

**Before importing**, run Part 1 of `docs/sql/MIGRATE_CATALOG_PREFLIGHT.sql`
on the **production** database — it refuses to continue (with a clear error)
if any of those five tables already has rows, which is exactly the
situation that would otherwise cause an `IDENTITY_INSERT`/primary-key
conflict. If it's clean, copy the exported `.sql` file to the server (USB
drive, network share, or however you like) and run it there — in SSMS
(open the file, Execute) or `sqlcmd -S <server> -E -C -i catalog_export.sql`.

**After importing**, run Part 2 of the same script on both dev and
production and compare the row counts — they must match exactly — then run
Part 3, which should return **zero rows** (any row it does return means a
reference didn't resolve, naming exactly which table/id).

> If the import itself errors with a foreign-key violation, the file's
> `INSERT` blocks landed out of dependency order (rare in a modern SSMS,
> but simple to fix): open the file and manually move the blocks so
> `Brands` comes first, then `Modifiers` and `MenuItems` (either order,
> since they only depend on `Brands`), then `MenuItemModifiers` and
> `ModifierCombinationWeights` last.

**Do this instead of 3.4 below, not in addition to it** — running both
would insert the same brands twice under different ids.

**Are the weights safe after this, forever?** Yes. The automatic Foodics
sync (4.6) only ever refreshes an item/modifier's name, category, SKU, and
active-state when it already exists — it explicitly never touches weight
columns (`FoodicsService.cs`: *"Refresh name/category/sku/active-state
only — never touch configured weights."*). Once imported, these weights
stay exactly as you set them, indefinitely, regardless of how many times
the sync runs.

### 3.3c Adding a brand LATER, after go-live

Two ways to handle a brand you add after production is already running —
pick whichever fits how you work:

**Option 1 (recommended) — configure it directly in the live portal.**
Register the brand (3.4) and its Foodics token (4.4), let the sync pull in
its real menu automatically, then just set weights for its items in the
production portal the same way you would have on dev — there's no dev copy
to protect against being overwritten, so there's nothing to export. This is
the simplest path for any brand you didn't already fully configure on your
laptop beforehand.

**Option 2 — you already configured this new brand on your dev machine
first.** The same Generate Scripts export from 3.3b works, with two
differences:
- Use **PART 0** (not PART 1) of `docs/sql/MIGRATE_CATALOG_PREFLIGHT.sql`
  as the pre-flight check — it checks that this one brand's `Code` doesn't
  already exist, rather than requiring the whole table to be empty (which
  would wrongly fail once production already has other brands on it).
- SSMS's wizard exports **every row** in a selected table, not just the
  new brand's — since your dev database now has other brands mixed in too,
  open the generated `.sql` file afterward and delete the `INSERT`
  statements for any brand that isn't the new one (they're grouped by
  table, and each row's values make its `BrandId`/brand `Code` obvious) —
  keep only the new brand's rows across all five tables before running it
  against production.

### 3.4 Add your real brands (skip if you just did 3.3b)

The portal has no "create brand" button — brands are added directly in
SQL, once each. Run (edit the list to your real brands first):

```sql
USE SwishWeighing;
GO
INSERT INTO dbo.Brands (Code, Name)
SELECT v.Code, v.Name
FROM (VALUES
    ('MM',  'Mishmash'),
    ('TBL', 'Tabel'),
    ('YP',  'Yelo Pizza'),
    ('SS',  'Shawarma Shakir'),
    ('SLC', 'Slice'),
    ('PAT', 'Pattie Pattie'),
    ('BBT', 'BBT'),
    ('BUR', 'Just C'),
    ('CHP', 'Chili Pepper')
) AS v(Code, Name)
WHERE NOT EXISTS (SELECT 1 FROM dbo.Brands b WHERE b.Code = v.Code);
```

(This exact block is also sitting commented-out at the bottom of
`DEPLOY_FULL.sql`, and in `docs/CONFIGURE_BRANDS.md` — safe to re-run, it
only inserts brands that don't already exist.) Each `Code` here **must**
match the `Code` you use for that brand's Foodics token in Part 4.5 — that's
the only thing that links a brand row to its Foodics credentials.

---

## 4. Part B — Backend API

### 4.1 Build

On your build machine:
```
cd backend\SwishWeighing.Api
dotnet publish -c Release -o publish
```

Copy the resulting `publish` folder to the server, e.g. `C:\swish\api`.

### 4.2 Install the .NET 8 Runtime

On the server, install the **.NET 8 Hosting Bundle**
(includes the runtime + IIS integration, safe to install even if you end up
not using IIS) from Microsoft's .NET download page.

### 4.3 Configure — connection string, admin key, CORS

**There's no traditional username/password anywhere in this system.** The
portal authenticates with one shared secret string — `Api:AdminKey` — sent
as an `X-Api-Key` header on every request; whoever holds that string has
full admin access. Each tablet instead gets its **own**, unique key
(`X-Device-Key`), generated *by the server* when you register that tablet in
the portal (6.3) — there's no "pick your own device key" option, and the raw
key is shown exactly once. You are the one who invents the admin key's
value — it's just a string, and it should be long and random, not a real
word. Generate one on the server (or any Windows machine) in PowerShell:

```powershell
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($bytes)
[Convert]::ToBase64String($bytes)
```

Copy that output — you'll set it as `Api__AdminKey` below, and later enter
the exact same string into the portal's Connection screen (5.3).

Nothing secret belongs in a checked-in file. Set these as **machine-level
environment variables** on the server (`:` in a config key becomes `__` in
an env var name — this project's existing convention, already documented
in `docs/BACKEND_API_GUIDE.md`):

```powershell
# Run once, as Administrator, in PowerShell on the server. setx /M sets a
# MACHINE-level variable — required for a Windows Service to see it (a
# service doesn't inherit your interactive user's environment).
setx /M ConnectionStrings__Sql "Server=<your-sql-server-instance>;Database=SwishWeighing;User Id=swish_api;Password=<that-password>;TrustServerCertificate=True;"
setx /M Api__AdminKey "<a-long-random-key-you-generate>"
setx /M ASPNETCORE_ENVIRONMENT "Production"
```

Non-secret production overrides (CORS origin — the portal's real URL) live
in `backend/SwishWeighing.Api/appsettings.Production.json`, which already
exists in this repo as a template — edit the placeholder before deploying:
```json
"Cors": { "Origins": [ "https://REPLACE-WITH-YOUR-PORTAL-URL" ] }
```

**A safety net is already built in:** if the API starts in the `Production`
environment with `Api:AdminKey` still at its dev default, or with no
Foodics tokens configured, it logs a clear warning naming exactly which
environment variable to set — so a forgotten step shows up in the logs
instead of silently shipping with insecure defaults. This was verified live
while writing this guide (both firing when secrets are missing, and staying
silent once they're set).

### 4.4 Set Foodics brand tokens

One `Code`/`Token` pair per brand you added in 3.4, as machine-level env
vars (matching each brand's `Code` from the SQL insert exactly):

```powershell
setx /M Foodics__Brands__0__Code "MM"
setx /M Foodics__Brands__0__Token "<Mishmash Foodics token>"
setx /M Foodics__Brands__1__Code "TBL"
setx /M Foodics__Brands__1__Token "<Tabel Foodics token>"
# ...one pair per brand, index doesn't need to be in any particular order
```

Leave `Foodics__WebhookSecret` **unset**. It's entirely optional — see
4.6 below — automatic sync works fully without it.

### 4.5 Host it — Windows Service (recommended)

**Why a Windows Service instead of IIS for the API itself:** the automatic
catalog sync (Part 4.6) depends on the API process staying alive
continuously. IIS application pools, by default, **idle-timeout and
recycle after 20 minutes of no incoming requests** — which would silently
pause the sync until the next request happens to wake the pool back up.
A Windows Service has no such idle concept; it just runs. (If you'd
still rather use IIS, see the note at the end of this section for the
exact setting that neutralizes this — but a Windows Service avoids the
whole issue by construction.)

This repo already has the plumbing for this (`Microsoft.Extensions.Hosting.WindowsServices`
+ `builder.Host.UseWindowsService()` in `Program.cs`) — it's a no-op
anywhere else (local `dotnet run`, IIS), so this doesn't change local dev
at all.

Register it, as Administrator, in PowerShell (one line each — `sc.exe` doesn't
accept PowerShell's backtick continuation, so these are written to not need
any):
```powershell
sc.exe create SwishWeighingApi binPath= "\"C:\Program Files\dotnet\dotnet.exe\" \"C:\swish\api\SwishWeighing.Api.dll\"" start= auto obj= "NT AUTHORITY\NetworkService"
sc.exe description SwishWeighingApi "SWiSH Weighing backend API + Foodics catalog sync"
sc.exe start SwishWeighingApi
```
(`obj=` runs it under a low-privilege built-in account rather than
`LocalSystem` — least privilege. If your SQL login is Windows-authenticated
instead of the SQL login from 3.3, use a dedicated domain/service account
here instead, and grant *that* account DB access rather than `swish_api`.)

Check it started cleanly:
```powershell
Get-Service SwishWeighingApi
Get-EventLog -LogName Application -Source SwishWeighingApi -Newest 10
```

By default Kestrel listens on port 5000 — set a specific port via another
machine env var if you want a different one:
```powershell
setx /M ASPNETCORE_URLS "http://+:5025"
```
Then open that port in Windows Firewall:
```powershell
New-NetFirewallRule -DisplayName "SWiSH API" -Direction Inbound -Protocol TCP -LocalPort 5025 -Action Allow
```

**For HTTPS** (recommended — tablets and the portal both send an API key on
every request, which should never travel in the clear over a real network):
put IIS in front as a **reverse proxy** terminating TLS with a real
certificate, forwarding to the Windows Service on `localhost:5025`. This is
the standard ASP.NET Core Module V2 "out-of-process" reverse-proxy pattern —
if you go this route, note the IIS idle-timeout caveat above doesn't apply
here, since the Windows Service (not IIS) is what actually stays alive;
IIS is only relaying traffic to it.

*(If you deploy the API directly under IIS instead of as a Windows Service:
in IIS Manager → Application Pools → your pool → Advanced Settings, set
**Idle Time-out (minutes) = 0** and **Start Mode = AlwaysRunning**, and
enable the Application Initialization feature so the pool starts with IIS
itself rather than waiting for the first request. Skipping this is the one
way this whole deployment would silently stop doing its job.)*

### 4.6 Verify

```powershell
curl http://localhost:5025/health
curl -H "X-Api-Key: <your-real-admin-key>" http://localhost:5025/api/brands
```
The second call should list your real brands from 3.4. If it 401s, the
admin key env var didn't take — machine-level env vars require a fresh
process (a service restart, or reboot) to be picked up; `setx` does **not**
affect an already-running process.

Then trigger one real sync to confirm end-to-end Foodics connectivity:
```powershell
curl -X POST -H "X-Api-Key: <your-real-admin-key>" http://localhost:5025/api/brands/1/sync-foodics
```
Expect a JSON result like `{"itemsAdded":..,"itemsUpdated":..,...}`. From
this point on, `FoodicsAutoSyncHostedService` re-runs this automatically
for every brand every 5 minutes on its own — nothing else to configure.
See `docs/CONFIGURE_BRANDS.md` for the day-to-day "a new item appeared in
Foodics" workflow once this is running.

---

## 5. Part C — Admin Portal

### 5.1 Build

On your build machine:
```
cd frontend
npm install
npm run build
```
This produces a static `frontend/dist` folder — plain HTML/CSS/JS, no
server-side runtime needed to host it.

### 5.2 Host it (IIS example)

1. In IIS Manager, create a new site (or virtual directory) pointing its
   physical path at the copied `dist` folder on the server.
2. Install the **URL Rewrite Module** (Microsoft download) if not already
   present — required for the next step.
3. The portal uses real client-side routes (`/tablets`, `/analytics/...`),
   so refreshing on any of those needs to still serve `index.html`, not a
   404. Add a `web.config` inside the `dist` folder before deploying it:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="SPA fallback" stopProcessing="true">
          <match url=".*" />
          <conditions logicalGrouping="MatchAll">
            <add input="{REQUEST_FILENAME}" matchType="IsFile" negate="true" />
            <add input="{REQUEST_FILENAME}" matchType="IsDirectory" negate="true" />
          </conditions>
          <action type="Rewrite" url="/index.html" />
        </rule>
      </rules>
    </rewrite>
  </system.webServer>
</configuration>
```

4. Serve it over HTTPS (a certificate on this IIS site) — the portal sends
   the admin API key on every request; it shouldn't travel in the clear.

### 5.3 Point it at the backend — no rebuild needed per deployment

The portal does **not** need the API URL baked in at build time. On first
load it shows a connection screen with two fields:
- **API base URL** — e.g. `https://api.yourcompany.local` (or `http://` +
  port if you're not fronting it with HTTPS yet)
- **API key** — the `Api:AdminKey` value from 4.3

This is saved in that browser's `localStorage` (per-browser, not shared
across machines) — enter it once per browser/device that uses the portal.
The same header (labeled "Connection") reopens this screen later to change
it. (There's also a build-time option — `VITE_API_BASE`/`VITE_API_KEY` env
vars at `npm run build` time — if you'd rather every browser auto-connect
with no manual step; the localStorage value always wins if both are set.)

---

## 6. Part D — Tablet App

### 6.1 Build the Android app

On your build machine (Flutter + Android SDK installed):
```
flutter build apk --release
```
Output: `build/app/outputs/flutter-apk/app-release.apk`.

Two things worth doing before a real rollout (not blocking, but avoid
finding out later):
- `android/app/build.gradle` currently has `applicationId =
  "com.example.tare_pack_station"` — the Flutter template default. Worth
  changing to something under your own domain (e.g.
  `com.swish.weighing`) before distributing to real tablets, since Android
  treats the applicationId as the app's permanent identity — changing it
  later means every tablet needs a fresh install, not an update.
- There's no release signing key configured yet (`android/key.properties`
  doesn't exist) — it currently builds with Flutter's debug key. That's
  fine for an initial internal rollout, but set up a real release keystore
  (`keytool -genkey ...`, referenced from `android/app/build.gradle`)
  before this goes to more than a handful of tablets — otherwise every
  future update requires manually reinstalling instead of overwriting.

### 6.2 Install it on each tablet

Simplest path for a fleet of a few to a few dozen tablets — sideload:
1. Enable **Developer options → USB debugging** on the tablet (Settings →
   About tablet → tap Build number 7 times, then Developer options).
2. Connect via USB, then: `adb install app-release.apk`
   (or copy the APK to the tablet and open it directly, allowing "install
   from unknown sources" for that one file).

For a larger fleet, distribute via your MDM tool of choice instead
(Android Enterprise, etc.) — the same APK works either way.

### 6.3 Register the device in the portal, get its key

For each tablet, in the portal:
1. Open the relevant **brand → branch**, find the **Tablets/Smart Scales**
   panel.
2. Enter a label (e.g. "Pack station 1") → **Add**.
3. The tablet's key is shown **once**, in the format `XXXX-XXXX` — copy it
   immediately (a "regenerate" action exists later if it's ever lost, but
   the original is never shown again).

### 6.4 Configure the tablet

On the tablet, open **Settings → head-office connection** and enter:
- **API address** — e.g. `https://api.yourcompany.local` (same URL as the
  portal connects to)
- **Scale key** — the `XXXX-XXXX` key from 6.3

Tap **Save & test connection**. On success, the tablet's own branch/brand
follow automatically from its registered device — no separate brand/branch
picker to keep in sync by hand.

### 6.5 Configure the weight source

Still in Settings, leave **Weight source mode** on **Manual (test)** until
a physical scale is actually wired up — the app is fully usable end-to-end
in this mode (see the root `README.md` / `CLAUDE.md` for the full manual
weight-entry flow). Switching to a real scale later is a Settings change
only, no reinstall.

---

## 7. End-to-end verification checklist

Work through this once, in order, before calling the rollout done:

- [ ] `sqlcmd ... -i DEPLOY_FULL.sql` completed with the "schema is fully up to date" message, no errors.
- [ ] `SELECT * FROM dbo.Brands;` in SSMS shows all your real brands.
- [ ] `Get-Service SwishWeighingApi` shows **Running**, and survives a server reboot (`start= auto` from 4.5) — test this once deliberately.
- [ ] `curl http://<server>/health` returns 200.
- [ ] `curl -H "X-Api-Key: ..." http://<server>/api/brands` lists your brands.
- [ ] `POST /api/brands/{id}/sync-foodics` for at least one brand returns a real item/modifier count (proves the Foodics token works).
- [ ] Wait 5+ minutes with no manual action, then check the Windows Event Log for `FoodicsAutoSync (sweep): ...` entries — proves the background sync is alive on its own.
- [ ] Open the portal in a browser on a machine that isn't the server, connect with the real API URL + key, see the real brands and items.
- [ ] Refresh the portal on a deep link (e.g. `/tablets`) — must NOT 404 (proves the IIS SPA rewrite rule from 5.2 is working).
- [ ] Add one test tablet device in the portal, get its key.
- [ ] On an actual tablet, enter the API address + scale key, "Save & test connection" succeeds.
- [ ] Weigh-check a real order on the tablet end to end, confirm the resulting weigh event shows up in the portal's dashboard.
- [ ] Confirm the connection is over HTTPS end-to-end (portal→API and tablet→API) before rolling out beyond a pilot.

---

## 8. Ongoing operations

- **New menu item in Foodics** → fully automatic, nothing to deploy or
  configure — see `docs/CONFIGURE_BRANDS.md`'s "New items added in the
  Foodics console" section for the exact staff-facing workflow (someone
  still has to weigh it and set the weight in the portal; everything else
  is automatic).
- **Future schema changes** → new files will land in `docs/sql/` as
  `14_*.sql`, `15_*.sql`, etc. Apply each one, in order, the same way as
  `DEPLOY_FULL.sql` (`sqlcmd -i <file>`) — they're all written with the same
  safe-to-re-run guarantee.
- **Deploying a backend code update** → `dotnet publish` on the build
  machine → copy the new `publish` folder over the old one on the server →
  `Restart-Service SwishWeighingApi`. Config (env vars) isn't touched by
  this, so nothing to re-enter.
- **Deploying a portal update** → `npm run build` → copy the new `dist`
  contents over the old ones. No backend restart needed.
- **Rotating the admin key** → `setx /M Api__AdminKey "<new key>"` →
  restart the service → re-enter the new key in every browser's Connection
  screen and don't forget any build-time `VITE_API_KEY` if you used that
  option.
- **Backups** — this guide doesn't set a backup policy; that's a call for
  whoever owns this SQL Server. At minimum, schedule regular full backups
  of the `SwishWeighing` database (SSMS → right-click the DB → Tasks → Back
  Up…, or a proper maintenance plan) — this is the only place weigh
  history and configured weights live.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `sqlcmd` fails with `CREATE DATABASE permission denied` | Your login can't create databases | Connect as `sa`/sysadmin, or have a DBA create an empty `SwishWeighing` DB + grant you `db_owner`, then re-run |
| `sqlcmd` fails with error 1934 (`QUOTED_IDENTIFIER`) | Only possible with an **older** copy of these scripts — `DEPLOY_FULL.sql` and `03_branches_devices.sql` both set `SET QUOTED_IDENTIFIER ON` up front now | Use the current version of the script from this repo |
| Portal shows "Unauthorized — check your API key" | Wrong/stale key in the browser's Connection screen, or the server's `Api__AdminKey` env var didn't take | Re-enter the key in the portal; on the server, confirm with `[Environment]::GetEnvironmentVariable("Api__AdminKey","Machine")`, restart the service if you just set it |
| Tablet shows "Scale not responding" / can't connect | Wrong API address, tablet key revoked/mistyped, or a firewall/network path issue | Re-check the address+key in tablet Settings; confirm the tablet can reach `http://<server>:<port>/health` from its own network |
| New Foodics items never appear in the portal | No brand token configured for that brand's `Code`, or the service isn't actually running continuously | Check the Windows Event Log for `FoodicsAutoSync` warnings; confirm `Get-Service SwishWeighingApi` is Running, not just Stopped-but-not-noticed |
| Portal 404s when refreshing on `/tablets` etc. | Missing the IIS URL Rewrite rule from 5.2 | Add the `web.config` shown there, confirm the URL Rewrite Module is installed |
| Server reboots and nothing comes back automatically | Service not set to auto-start, or IIS app pool idle-timeout (if using IIS instead) | Re-run `sc.exe create ... start= auto`, or set the IIS pool's Idle Time-out to 0 per 4.5 |

---

## 10. Getting the code onto the server (GitHub)

Everything above assumes the code is already sitting on whichever machine is
building it. This section covers using a private GitHub repo as the way to
get it there — and, more importantly, exactly what must **never** end up in
that repo.

### 10.1 STOP — fix secrets hygiene before you ever run `git init`

Once something is committed, it lives in git history forever, on every
clone, even after you later "delete" it — the only real fix at that point is
rewriting history (`git filter-repo`/BFG) on every clone that exists, which
is exactly the kind of mess this step avoids entirely by not happening in
the first place.

This repo's root `.gitignore` and `frontend/.gitignore` have already been
updated (as part of this same deployment work) to exclude:
- Every `<digits>_integration_prd_token.txt` file at the repo root (the
  per-brand Foodics production tokens from 4.4) — pattern
  `*_integration_prd_token.txt`.
- `"# FOODICS BRAND API KEYS.txt"` and `assets/foodics/brands.json` (already
  excluded).
- `backend/**/bin/`, `backend/**/obj/`, `backend/**/publish/` — build output,
  large and regenerated every time, never source.
- `frontend/.env` — holds `VITE_API_KEY`, a real secret once you set one for
  production. `frontend/.env.example` (a safe, placeholder-only template) is
  committed instead so a fresh clone knows what shape to create.

Before your first commit, verify this actually worked — don't just trust it:

```powershell
cd "D:\Swish Projects\tare_pack_station"
git init
git add -A
git status
```

Read the full file list in `git status` (or `git diff --cached --stat` after
`add`). None of the following should appear anywhere in it:
- Any `*_integration_prd_token.txt` file
- `# FOODICS BRAND API KEYS.txt`
- `frontend/.env` (note: `frontend/.env.example` **should** appear — that's
  the safe template)
- Anything under `backend/**/bin`, `backend/**/obj`, `backend/**/publish`
- `frontend/node_modules`, `frontend/dist`

If any of those show up, stop, fix the relevant `.gitignore`, `git reset`,
and check again before committing.

### 10.2 Commit and push to a private GitHub repo

```powershell
git commit -m "Initial commit"
```

On github.com: **New repository** → give it a name → **Private** (this repo
contains real business logic and, once real secrets are set, would otherwise
expose them if ever made public) → do **not** initialize with a README
(this local repo already has content, and GitHub will refuse to push over a
repo it thinks is empty-but-isn't if you do). Copy the HTTPS (or SSH) URL it
shows you, then:

```powershell
git remote add origin https://github.com/<your-org-or-user>/<repo-name>.git
git branch -M main
git push -u origin main
```

First push over HTTPS will prompt for GitHub credentials — use a Personal
Access Token (Settings → Developer settings → Personal access tokens) as the
password if prompted, since GitHub no longer accepts account passwords
directly for git operations.

### 10.3 What still never goes in git, even now

The `.gitignore` fixes stop *accidental* commits — they don't change the
rule that real secret *values* never belong in source control, a commit
message, a GitHub issue, or a gist, even temporarily "to test something."
Everything below lives only as a machine-level environment variable on the
server (already documented above) or a per-browser localStorage value in
the portal — never in a file that gets committed:

| Secret | Lives here instead |
|---|---|
| `Api:AdminKey` real value | Server env var `Api__AdminKey` (4.3) + typed into the portal's Connection screen (5.3) |
| `swish_api` SQL login password | Server env var `ConnectionStrings__Sql` (4.3) |
| Each brand's Foodics token | Server env vars `Foodics__Brands__N__Token` (4.4) — once transcribed there, the original `*_integration_prd_token.txt` files can be deleted from the project folder entirely, gitignored or not |
| A tablet's device key | Never stored anywhere by you — shown once in the portal (6.3), typed into that one tablet, done |

**Sharing these values with a colleague** (or with future-you, setting up a
second server): use a password manager's shared vault (1Password, Bitwarden)
or another genuinely encrypted channel — not plain email, not a Slack/Teams
message, not a text file attached anywhere. If a secret ever does end up
somewhere it shouldn't (a chat message, a screen-share), the correct
response is to rotate it (generate a new AdminKey, regenerate the device
key, ask Foodics to reissue that brand's token) — not to simply delete the
message and hope.

### 10.4 Building from the cloned repo

On whichever machine builds (your laptop, or the server itself if you'd
rather install the .NET SDK + Node there too — the SDK, not just the
runtime, is required to build, unlike Part B's runtime-only requirement to
*run* it):

```powershell
git clone https://github.com/<your-org-or-user>/<repo-name>.git
cd <repo-name>
```

Then continue exactly at 4.1 (`dotnet publish`) and 5.1 (`npm run build`) —
nothing about those steps changes based on where the source came from.

**Updating later**: `git pull` becomes step zero of the existing "Deploying
a backend/portal update" workflow in §8 — pull, then publish/build, then
copy over the old files and restart the service, exactly as already
documented there.

---

## 11. Exposing the API to the internet

Everything through Part B gets the API reachable on your **local network**
— `http://<server-LAN-IP>:5025`, or via an IIS reverse proxy on the LAN.
This section is specifically for making that reachable from the real
internet, so tablets and portal users outside the building (or on mobile
data) can reach it too.

> **The one rule that matters most in this whole section: only ever expose
> the API's HTTPS port to the internet. SQL Server's port (1433, or your
> named instance's port) and Remote Desktop (3389) must NEVER be forwarded
> from your router to the internet.** SQL Server should only ever accept
> connections from the API server itself (or, at most, other machines on
> the same LAN) — there is no scenario in this system where SQL Server needs
> to be reachable from outside your building.

### 11.1 A domain name that points at your server

Buy a domain (or use a subdomain of one you already own), then create a
**DNS A record** pointing it at your server's **public** IP address (find
it with `Invoke-RestMethod http://ifconfig.me` from the server, or any
"what is my IP" site — this is different from the server's LAN IP from
`ipconfig`).

If your internet connection has a **dynamic** public IP (true for most
residential and many small-business plans — check with your ISP if unsure),
a plain A record will silently go stale the next time your IP changes. Set
up **Dynamic DNS** instead — either your router's built-in DDNS client
(most consumer/small-business routers have one under a "Dynamic DNS"
settings page) pointed at a provider like No-IP or DuckDNS, or your domain
registrar's own dynamic-DNS feature if it has one.

Verify the record actually resolves correctly before moving on:
```powershell
Resolve-DnsName yourdomain.com
```

### 11.2 Port forward on your router

Log into your router's admin page (commonly `192.168.1.1` or `192.168.0.1`
in a browser — check the label on the router itself, or `ipconfig`'s
"Default Gateway" line on any device on that network). Find the
**Port Forwarding** (sometimes "Virtual Server" or "NAT") section and add a
rule:

- **WAN port**: 443 (and 80, only if you're using win-acme's HTTP-01
  challenge below, which needs it briefly during each renewal)
- **Forwards to**: your server's LAN IP (from `ipconfig` on the server
  itself), same port

Every router's admin UI looks different — the exact click path can't be
given generically here; look for "Port Forwarding" in whatever menu your
router's admin page has.

### 11.3 A real TLS certificate

Tablets and the portal both send the API key on every request — it must
never travel in the clear over the real internet, and a self-signed
certificate would make every tablet/browser show a security warning (or
require manually trusting it on every device). Use **win-acme**, the
standard free, automated Let's Encrypt client for Windows/IIS:

1. Download it from `https://www.win-acme.com` (a zip, no installer).
2. Run `wacs.exe` **as Administrator** on the server.
3. Choose the option to create a certificate for an IIS site (if IIS is
   fronting the API per 4.5's reverse-proxy note) — it auto-detects the
   domain from the site binding, matching your DNS record from 11.1.
4. It completes Let's Encrypt's HTTP-01 validation (needs port 80 reachable
   from the internet at that moment — this is why 11.2 forwards 80 too),
   installs the certificate, and binds it to the site automatically.
5. It also registers a **scheduled task** that renews the certificate
   automatically before it expires (Let's Encrypt certs are short-lived by
   design) — confirm this exists: open **Task Scheduler** and look for a
   task named something like `win-acme renew (...)`.

If you're not using IIS at all (API exposed directly via the Windows
Service's Kestrel), win-acme also supports a "manual"/standalone binding
mode — see its own prompts; the certificate + private key end up as files
you'd then reference from `ASPNETCORE_URLS`/Kestrel's HTTPS configuration
instead of an IIS binding.

### 11.4 Firewall — confirm exactly what's open

```powershell
Get-NetFirewallRule -Direction Inbound -Enabled True |
  Where-Object { $_.Action -eq 'Allow' } |
  Get-NetFirewallPortFilter |
  Select-Object -Property LocalPort, Protocol
```

Confirm **443** (and, if IIS/win-acme need it, 80) are the only inbound
rules allowing traffic from "Any" remote address. If port 1433 (or 5025,
the raw Kestrel port, if IIS is fronting it) shows up as open to "Any",
restrict it — it should only be reachable from the LAN, or not open at all
in Windows Firewall (the router-level port forward from 11.2 not existing
for it is the primary control; the firewall rule is the second layer).

### 11.5 Test from truly outside your network

The most common mistake here is testing "success" from a device still on
the same WiFi — that only proves the LAN path works, not the internet path.
Turn off WiFi on your phone (use mobile data), then:

```
https://yourdomain.com/health
```

This must return `200` with **no certificate warning** in the browser. Once
that works, re-run the full checklist in §7 from a genuinely external
network before rolling out beyond a pilot.

### 11.6 If this isn't practical on your actual internet connection

Some ISPs (especially some residential/mobile-carrier connections) use
**CGNAT**, which means you don't have a real public IP to forward a port to
at all, no matter what you configure on your router — port forwarding
simply cannot work in that case. If `Resolve-DnsName`/pinging your own
public IP from outside never reaches your router no matter what you try,
this is the likely cause; ask your ISP directly whether you have a
dedicated public IP or are behind CGNAT. The workaround in that situation is
a small cloud VM (a low-cost Windows VM on Azure/AWS/any VPS provider) that
either runs the whole stack itself, or just reverse-proxies to your
on-prem server over a VPN tunnel — a bigger topic than fits here, but worth
knowing the constraint exists before spending hours on port forwarding that
was never going to work.

---

## 12. Environment & configuration — the complete list

Every value the system needs, in one place, so nothing gets missed. Each
row links back to where it's explained in full above.

### Lives on the server, as machine-level environment variables (4.3–4.4)

| Variable | Value | Notes |
|---|---|---|
| `ConnectionStrings__Sql` | `Server=...;Database=SwishWeighing;User Id=swish_api;Password=...;TrustServerCertificate=True;` | The `swish_api` login + password from 3.3 |
| `Api__AdminKey` | A long random string you generate | Must match exactly what you enter in the portal (5.3) |
| `ASPNETCORE_ENVIRONMENT` | `Production` | |
| `ASPNETCORE_URLS` | `http://+:5025` (or your chosen port) | |
| `Foodics__Brands__0__Code`, `Foodics__Brands__0__Token` | e.g. `MM`, `<token>` | One `Code`/`Token` pair per brand — `Code` must match `Brands.Code` in the database **exactly**, or that brand's sync silently never runs |
| `Foodics__Brands__1__Code`, `Foodics__Brands__1__Token` | (repeat per brand) | Index (`0`, `1`, `2`...) just needs to be unique, not in any order |
| `Foodics__WebhookSecret` | leave unset | Optional — automatic sync (every 5 min) works fully without it |

### Lives in `backend/SwishWeighing.Api/appsettings.Production.json` (checked into git — no secrets here)

| Key | Value |
|---|---|
| `Cors:Origins` | `["https://your-portal-url"]` — the portal's real address |

### For the portal (5.3) — pick ONE of these two, not both required

| Mechanism | Where | Notes |
|---|---|---|
| Connection screen (per-browser) | Typed once into the portal itself | Saved in that browser's `localStorage`; re-enter on every browser/device that uses the portal |
| `frontend/.env` at build time | `VITE_API_BASE`, `VITE_API_KEY` | Bakes the values into the built files so every browser auto-connects with no manual step. `VITE_API_KEY` must match `Api__AdminKey` exactly. Copy `frontend/.env.example`'s placeholders, never commit the real file (already gitignored) |

### For each tablet (6.4) — entered on-device, not a file or env var at all

| Field | Where it comes from |
|---|---|
| API address | Same URL as the portal connects to |
| Device key (`XXXX-XXXX`) | Generated by the server the moment you register that tablet in the portal (6.3) — shown once, never stored anywhere by you |

### In the database itself — not config, but must exist before anything works

| What | How it gets there |
|---|---|
| `Brands` rows (Code + Name) | Either the migration in 3.3b/3.3c, or the manual insert in 3.4 |
| Each brand's Foodics token | Matched to its `Brands.Code` via the env vars above — **the database row and the token are two separate things you must keep in sync by hand**; the token itself is never stored in the database |
| Menu items, modifiers, weights | Migrated in 3.3b, or configured directly in the portal per-item afterward |

**The one gotcha that causes silent, hard-to-notice failures**: a brand's
`Code` in the database and its `Foodics__Brands__N__Code` env var must be
**identical, character for character** — that's the only thing linking a
database row to its Foodics token. Get this wrong and that one brand's
sync simply never runs, with no error shown anywhere obvious — check the
Windows Event Log for `FoodicsAutoSync` entries if a brand's items never
appear.
