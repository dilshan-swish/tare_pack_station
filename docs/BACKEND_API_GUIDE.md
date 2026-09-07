# SWiSH Weighing Web API — Run & Deploy Guide

ASP.NET Core 8 Web API. It's the single gateway between the store tablets / admin
portal and **SQL Server + Foodics**. Project: `backend/SwishWeighing.Api`.

## What it does

| Method & route | Purpose | Who calls it |
|---|---|---|
| `GET /health` | Liveness + DB check (open, no key) | anyone |
| `GET /api/brands` | Brands + weight-coverage counts | portal |
| `GET /api/brands/{id}/items?search=&missingOnly=` | Items for a brand | portal |
| `PUT /api/items/{id}/weight` | Set item Min/Max (+ packaging) | portal |
| `GET /api/brands/{id}/modifiers?search=` | Modifiers for a brand | portal |
| `PUT /api/modifiers/{id}/weight` | Set modifier weight | portal |
| `POST /api/brands/{id}/sync-foodics` | Pull the menu from Foodics into SQL | portal / scheduler |
| `POST /api/brands/{id}/publish` | Bump published version | portal |
| `GET /api/brands/{id}/config` | Published weights (items + modifiers) | tablets |
| `POST /api/weigh-events` | Record a weigh (telemetry) | tablets |
| `GET /api/weigh-events/summary?branchId=&days=` | Verdict counts for dashboards | portal |

Every `/api/**` call needs the header **`X-Api-Key`** (see below). `/health` and
`/swagger` are open.

## 1. Prerequisites

- **.NET 8 SDK** (already installed here at `%USERPROFILE%\.dotnet`).
- The `SwishWeighing` database created (see `BACKEND_SQL_SETUP.md`).

## 2. Configure

Non-secret settings live in `appsettings.json`:
- `ConnectionStrings:Sql` — defaults to `localhost\SQLEXPRESS`, `SwishWeighing`,
  Windows auth. For on-prem, change to the server + a SQL login.
- `Api:AdminKey` — the shared key callers must send as `X-Api-Key`. **Change it.**
- `Cors:Origins` — the admin portal's URL (dev: `http://localhost:5173`).

**Secrets (Foodics tokens + real AdminKey) — never commit these.** Use
user-secrets in dev:

```
cd backend/SwishWeighing.Api
dotnet user-secrets set "Foodics:Brands:0:Code" "BBT"
dotnet user-secrets set "Foodics:Brands:0:Token" "<BBT_FOODICS_TOKEN>"
dotnet user-secrets set "Api:AdminKey" "<a-long-random-key>"
```

On the on-prem server use **environment variables** instead (same keys, `:`
replaced by `__`), e.g. `Foodics__Brands__0__Token`.

## 3. Run locally

```
cd backend/SwishWeighing.Api
dotnet run
```

Then open **Swagger** at the printed `https://localhost:xxxx/swagger` to try every
endpoint (click *Authorize* and paste your `X-Api-Key`). Quick check:

```
curl http://localhost:5080/health
curl -H "X-Api-Key: dev-change-me" http://localhost:5080/api/brands
```

## 4. Typical flow

1. `POST /api/brands/1/sync-foodics` → pulls BBT's products + modifiers into SQL
   (new items arrive with **no weight**).
2. Portal sets weights via `PUT /api/items/{id}/weight` and
   `PUT /api/modifiers/{id}/weight`.
3. `POST /api/brands/1/publish` → bumps the version.
4. Tablets call `GET /api/brands/1/config` to pull the published weights, and
   `POST /api/weigh-events` after each weigh.

## 5. Deploy on-prem

> For the full, atomic, step-by-step production rollout — SQL Server, this
> API, the admin portal, AND the tablet app, together, including exact
> Windows Service setup, credentials, and an end-to-end verification
> checklist — see **`docs/PRODUCTION_DEPLOYMENT_GUIDE.md`**. The summary
> below stays here as the quick version for just this API.


1. Publish a self-contained folder:
   ```
   dotnet publish -c Release -o publish
   ```
2. Host it next to SQL Server. Two common options:
   - **IIS** with the *ASP.NET Core Hosting Bundle* (adds an IIS site pointing at
     the publish folder), or
   - **Windows Service / Kestrel** behind IIS or nginx as a reverse proxy for TLS.
3. Set the connection string + secrets as **environment variables** on the server.
4. Expose it to the stores over the existing store↔HQ network (HTTPS). Because the
   tablets reach it through the network you already have, no new internet exposure
   is required.

## 6. Security notes

- Rotate `Api:AdminKey`; give the portal and tablets their own keys later
  (per-device keys map to the `Devices` table — already in the schema).
- Foodics tokens live **only** on the server (config/secrets), never on devices.
- Always serve over **HTTPS** in production.
