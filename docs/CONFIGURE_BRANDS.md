# Adding your brands (menu + Foodics tokens)

Each brand needs **two things**: a row in the `Brands` table (so it shows in the
portal) and its **Foodics token in the API config** (so the server can sync that
brand's menu). The `Code` must match between the two — that's how the API finds
the right token when you press *Sync from Foodics*.

You already have all the tokens in the TARE `brands.json` (code / name / token).
Use those same values here.

## 1. Add a row per brand (SQL)

Run in the `SwishWeighing` database. Safe to re-run — it skips any brand that
already exists (`Code` is unique, so BBT is left alone).

```sql
USE SwishWeighing;

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

## 2. Load the Foodics tokens into the API

**Dev (your laptop) — auto-load from the existing `brands.json`** (no manual
token copying; sets Code + Token per brand):

```powershell
$env:DOTNET_ROOT="$env:USERPROFILE\.dotnet"; $env:PATH="$env:USERPROFILE\.dotnet;$env:PATH"
cd "D:\Swish Projects\tare_pack_station\backend\SwishWeighing.Api"
$brands = Get-Content "..\..\assets\foodics\brands.json" -Raw | ConvertFrom-Json
for ($i = 0; $i -lt $brands.Count; $i++) {
  # NOTE: ${i} braces are required — "$i:Code" is parsed by PowerShell as a
  # scope-qualified variable and silently produces an empty key.
  dotnet user-secrets set "Foodics:Brands:${i}:Code"  $brands[$i].code
  dotnet user-secrets set "Foodics:Brands:${i}:Token" $brands[$i].token
}
Write-Host "Configured $($brands.Count) brand tokens."
```

**On-prem server — environment variables** (same keys, `:` → `__`), one pair per
brand:

```
Foodics__Brands__0__Code=MM
Foodics__Brands__0__Token=<Mishmash token>
Foodics__Brands__1__Code=TBL
Foodics__Brands__1__Token=<Tabel token>
# …through all brands
```

The token is matched to a brand by **Code**, so index order doesn't matter as
long as each entry's Code and Token belong together. Tokens live **only** on the
server — never in the portal or on the tablets.

## 3. Use it

In the portal: pick the brand → **Sync from Foodics** (pulls its products +
modifiers) → set **Ideal / Min / Max / Packaging** on items and weights on
modifiers → **Publish**. The brand switcher at the top of the weights page lets
you hop between brands without going back.

## New items added in the Foodics console

Nothing manual needed on the tablet side:

1. Someone adds a product/combo/modifier in Foodics.
2. Next **Sync from Foodics** (button now, or a scheduled job later) upserts it —
   the new item arrives with **no weight**.
3. It shows in the portal with a **red "Needs weight"** badge and a coral stripe,
   the brand's **coverage %/"missing" count** goes up, and the **"Missing only"**
   filter lists exactly what's outstanding.
4. Until someone sets its weight, the tablet shows that order as
   **"weight check unavailable"** (never a wrong verdict), and — if you use the
   publish gate — it's flagged before go-live.

> Tip for later: a nightly scheduled sync + an email/Slack alert ("N new items
> need weights at BRAND") makes this fully hands-off. Easy to add on top of the
> existing sync endpoint.
