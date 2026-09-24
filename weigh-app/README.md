# TARE Weigh — branch item-weighing app

Branch staff sign in with just their branch email (no password), pick a live Foodics order (the Keeta / Talabat number is the big one on each card), and type each item's weight. The data lands in Supabase. The portal's **Staff Weighing** page shows it with stats, charts and exports.

## 1. Supabase (once)

1. Create a project. Then go to **Authentication → Sign In / Providers**: keep Email enabled and **turn off "Allow new users to sign up"**.
2. **SQL editor** → paste and run `supabase/schema.sql`. It's safe to re-run. It creates the tables, security rules and views, and seeds the 12 BBT branches and the focus list. (Already ran an older version? Run it again — it upgrades in place.)
3. Branch logins need no setup: typing an email listed in `public.branches` (and active) signs that branch in, and its login is created automatically the first time. To add a branch, insert a row into `public.branches`. To lock one out, untick "Active" in the portal's Setup tab.

## 2. Vercel

Import this `weigh-app` folder as a project (framework: Vite). Set these environment variables:

| Name | Value |
| --- | --- |
| `VITE_SUPABASE_URL` | Supabase → Project Settings → API → URL |
| `VITE_SUPABASE_ANON_KEY` | the **anon public** key |
| `SUPABASE_SERVICE_ROLE_KEY` | the **service_role** key: server-side only, used to sign branches in by email |
| `FOODICS_TOKEN` | BBT's Foodics token (account 643525), server-side only |

The service-role key and Foodics token are only ever read by the `/api` functions and never sent to a browser. Don't give them a `VITE_` prefix.

## 3. Portal (no extra login)

The portal's **Staff Weighing** page reads Supabase through the .NET API it's already connected to. Give the API the Supabase URL and service-role key, then restart it:

```
cd backend/SwishWeighing.Api
dotnet user-secrets set "Supabase:Url" "https://xxxx.supabase.co"
dotnet user-secrets set "Supabase:ServiceRoleKey" "<service_role key>"
```

In production, set environment variables `Supabase__Url` and `Supabase__ServiceRoleKey` instead.

## Local dev

```
cp .env.example .env.local   # fill in values (.env.local is git-ignored; keep real keys out of .env.example)
npm install
npm run dev                  # http://localhost:5180 (API included)
```

## How it behaves

- **Sign-in:** email only, as requested. Anyone who knows a branch's email can sign in as that branch, so keep branch emails internal. Attempts are rate-limited, and a branch can be switched off instantly in Setup.
- **Security:** a branch only sees and writes its own entries. The branch, staff email, business day and size are set by the database, not the device. Staff can fix their own entries for 48 h; the portal can fix anything.
- **Offline:** weights save on the device and sync automatically when the connection is back. Retries never duplicate an entry.
- **Skipped lines:** staff meals, drinks, merch and add-ons priced at or below 0.7 KD are hidden. Meals (priced 0 in Foodics) are never skipped.
- **Sizes and business day:** REGULAR / MEDIUM / SUUUBER are recorded per entry. The business day rolls at 06:00 Kuwait time. All of this is editable in the portal's Setup tab.
