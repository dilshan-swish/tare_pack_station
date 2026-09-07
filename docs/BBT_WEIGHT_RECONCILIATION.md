# BBT weight-sheet reconciliation

Reconciles the "Final BBT Menu Items Weight (Ideal - Min and Max) scenarios"
PDF (133 rows: ~90 food items, ~35 drinks, 4 modifiers) against the real,
Foodics-synced BBT catalog in `SwishWeighing.dbo.MenuItems`/`Modifiers`
(queried live, not assumed). Nothing in this document has been written to
the database yet — it's the proposal to review before anything is entered.

**Current weight coverage: 26 of BBT's 253 real menu-item rows (~10%) have
any weight configured.** This sheet is the source for closing most of that
gap — but about a third of it doesn't map cleanly, for reasons below.

## Bucket 1 — Ready to enter as-is (63 rows)

Direct, unambiguous name match to a single active Foodics item. Nothing
blocking these — safe to enter via the portal (or I can do it, once you
confirm you want me writing directly to the DB rather than you doing it
through the portal UI).

Examples: Filaaa On Toast, Beef/Chicken/Corn Dynamite Stick, Classic Rolls
Beef(+Meal), Smokey Rolls Beef(+Meal), Fillaa on Toast Duo Combo, Little
Cheeseburger/Chicken Burger/Mix Duo, Toasts Duo Combo, Chicken Fillaaa(+Meal),
Chicken Nugget Meal, Chilli Lime/Classic Old Skool/Supreme(+Meal), Little
Wrap Fillaaa Meal, Quarter Pounder(+Meal), Southwest(+Meal), Little
Cheeseburger/Chicken Burger, Little Cheeseburger/Chicken Burger KidKit,
Nuggets KidKit, Chicken Nuggets 6pcs, Coleslaw, Fillaaa Popcorn, Messy Fries,
Toast, all 12 sauces (BBQ/BBT Mayo/BBT Ranch/BBT/Cheese Dip/Fillaaa/Honey
Mustard/K&M/Not So Ranch/Sweet Chili/XL Fillaaa).

**One duplicate to resolve:** "3.5 KD Deal" exists as **3 separate Foodics
products** (SKUs `BB8300255`, `BB2202120`, `bb2202105`) under the identical
name. I can't tell which is the live one from the DB alone — do all three
need the same weight, or is only one of them actually sellable today?

## Bucket 2 — One clean rename (9 rows)

Your PDF says **"SUUUBER"**; the real Foodics catalog says **"SUUUBERT"**
(with a trailing T) — confirmed across every one of these:
SUUUBER BLIND BOX Chicken/Beef → SUUUBERT BLIND BOX, SUUUBER Chicken
Deal/Deal → SUUUBERT Chicken Deal/Deal, SUUUBER BEEF(+COMBO) → SUUUBERT
BEEF(+COMBO), SUUUBER CHICKEN(+COMBO) → SUUUBERT CHICKEN(+COMBO). All 9
resolve cleanly once renamed — ready to enter.

Also a near-match, safe to auto-resolve: **"Spicy Chicken Nuggets 6pcs"**
(PDF) → real item is just **"Spicy Chicken Nuggets"** (no pack-size in the
Foodics name).

## Bucket 3 — Resolves to an item + modifier combo, not a separate item (6 rows)

"Westcoast Meal Caramalized Onion" / "Westcoast Meal Red Onion" and
"Westcoast Burger Caramalized Onion" / "Westcoast Burger Red Onion" aren't
4 separate Foodics products — there's only **one** "Westcoast Meal" and
**one** "Westcoast Burger". The onion type is a modifier choice (I found
"Caramelized Onions" / "Raw Onion" / "No Onion" as real modifier options).
So: **base item weight + onion modifier weight = your PDF's two variants.**
This needs the modifier's own weight worked out from the two PDF numbers
(e.g. Westcoast Meal: 710g "Caramalized Onion" vs 663g "Red Onion" — a 47g
gap between the two onion choices, once the shared base is set).

Likely the same pattern for **"Super Duper Deal Mix"** / **"Super Duper
Deal Chicken"** — only one "Super Duper Deal" product exists; Mix vs Chicken
is presumably a modifier choice too, but I haven't found that modifier group
yet to confirm the mechanism — **can you confirm this one**, since I don't
want to guess at a group I haven't actually located?

## Bucket 4 — Genuinely blocked: no size dimension exists in Foodics at all (43 rows)

This is the one that needs your call before I do anything. Your PDF gives
per-size weights (Regular / Medium / Subeer, or per-ml) for fries and every
bottled/canned drink. I checked thoroughly — as currently synced from
Foodics, **none of that size distinction exists anywhere**:

- "Curly Fries" / "French Fries" / "Not So Curly Fries" each exist as
  exactly **one** Foodics product, with **one** weight slot. Their only
  linked modifiers are seasoning (Chilli Lime / Salt / Salt N' Vinegar) —
  nothing size-related. Confirmed by checking the actual linked-modifier
  list on the real "Curly Fries" product directly, not inferred.
- "Pepsi" / "Mirinda" / "7up" / "Mountain Dew" / "Pepsi Zero" / "Aquafina
  Water" don't exist as standalone products at all. The only things with
  those names are (a) modifier options inside "Choice Of Drink" — flat, no
  size — or (b) items prefixed **"SM -"**, which are inventory/stock SKUs,
  not something a customer can actually order (see Bucket 6).
- I checked whether Foodics' "Price Tags" feature might be the missing size
  mechanism — it isn't; that feature is for per-channel pricing (Talabat vs.
  in-store, etc.), not size variants. Ruled out, not guessed.

So this isn't a naming problem — **the size dimension your sheet is built
around doesn't exist in what's been synced from Foodics.** Three
possibilities, and I need you to tell me which is true:
1. Foodics' console *does* have size variants for these (separate products
   or modifiers) that simply haven't been added yet, and someone needs to
   add them there before a sync can pick them up.
2. Size is chosen some other way at the till (a manual note, a quantity
   field) that was never meant to be a catalog-level distinction — in which
   case the practical fix is picking **one** representative weight per item
   (e.g. the size you actually pack most often) rather than three.
3. This sheet was prepared for a different ordering setup than what's live
   in Foodics today, and needs to be re-derived against the real catalog.

Affected: all Curly/French/Not So Curly Fries size rows, all Chilli Lime
fries variants, and every branded-drink-by-ml row (Mirinda/Pepsi/Mountain
Dew/7up/Pepsi Zero at 150/330/500ml, Kinza at 185/360ml, the milkshake
12oz/22oz pairs, the 8/12/16/24oz cup-drink rows).

## Bucket 5 — Structural mismatch, needs confirmation (7 rows)

- **"Kid Kit Blind Box Nuggets" / "Chicken Burgers" / "Nuggets Cheese
  Burger"** — only **one** generic "Kid Kit Blind Box" product exists in
  Foodics. Is one flat weight meant to cover all 3 PDF variants, or are the
  3 flavors chosen via a modifier I haven't located?
- **"Filaaa On Toast With drinks"** — the closest real item,
  "Filaaa on Toast with Fries and Drink" (SKU `BB7001022`), is currently
  **inactive** in Foodics. Still the right target, or has it been replaced
  by something else?
- **"Chicken Nuggets 20pcs"** — no matching product or size variant found
  anywhere (only a flat "Chicken Nuggets" and an inactive "Chicken nuggets
  6pcs"). Does this size exist in Foodics under a different name, or not at
  all yet?

## Bucket 6 — Ignore entirely (not real order-line items)

Anything prefixed **"SM -"** (e.g. `SM - BBT Pepsi Can`, `SM - BBT Westcoast
Raw Onion`, `SM - BBT Chicken Nuggets (6 PCS`) is an inventory/stock SKU,
not something that appears on a customer order. Weighing these would be
wasted effort — they'll never show up on a real order line for the tablet
to check.

## The 4 generic "Modifiers" on the PDF's last page

| PDF item | PDF weight | Real Foodics modifier | Currently configured |
|---|---|---|---|
| Extra Cheese | 11g | `Extra` → Extra Cheese | **10g** (already set — close to your sheet, good sanity check) |
| Extra Sauce | 14g | `Extra` → Extra Sauce | **15g** (already set — also close) |
| Extra Patty 55g | 38g | `Extra` → Extra Patty | not configured |
| Extra Subeer Patty | 93g | `Extra` → SUUUBERT BEEF PATTY *or* SUUUBERT SQUARED BREADED CHICKEN PATTY | not configured — **which one is "Subeer Patty"? Beef or the breaded chicken one, or both need their own weight?** |

Worth noting: the two that are already configured (Extra Cheese, Extra
Sauce) are close to what your sheet says — a good sign the manually-entered
values so far are trustworthy, not stale test data.

## The duplicate-modifier problem — confirmed, and quantified

BBT has **836 modifier rows in the database, but only 326 truly distinct
(group, option) combinations** — a 61% duplication rate. This is Foodics'
own catalog behavior (documented in this codebase's sync code), not
something wrong with the sync: Foodics duplicates a shared modifier group's
options once per product that offers them. "Your Choice Of Drink → Arwa
Water" alone exists as **22 separate rows**.

This mainly affects the *workflow* of entering weights, not this
reconciliation directly — the portal already has a "bulk-apply to all
variants in a group" feature built for exactly this. Once Bucket 4 is
resolved, the drink weights should be entered once per group via that
bulk-apply path, not 22 times by hand.

## What I need from you before I write anything

1. **3.5 KD Deal** — one weight for all 3 SKUs, or is only one currently live?
2. **Bucket 4 (the big one)** — which of the 3 possibilities above is true for fries/drink sizing?
3. **Super Duper Deal** — confirm Mix vs Chicken is a modifier choice (and point me at it if so).
4. **Kid Kit Blind Box** — one flat weight for all 3 flavors, or a modifier I haven't found?
5. **Extra Subeer Patty** — beef patty, the breaded chicken patty, or both?
6. Once these are answered: do you want me writing directly to the database, or would you rather enter them through the portal yourself using this document as the source list? Either works — writing directly is faster but touches real production data, so I'd rather you say which you prefer.
