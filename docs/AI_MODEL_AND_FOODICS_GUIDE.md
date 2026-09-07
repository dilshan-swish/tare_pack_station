# TARE — AI weight-check model & Foodics integration guide

This document covers the two features added on top of the pack-station app:

1. An **on-device AI model** that, when an order is off-weight, explains *what
   is likely missing or extra* — or warns that the **bag may be the wrong
   order**.
2. A **Foodics POS integration** that fetches live orders in realtime.

Both are built to be **swappable** and **safe** — nothing here breaks the
existing manual test-mode flow, and every failure path degrades gracefully.

---

## 1. The AI weight-check model

### What it does

On the **Order detail** screen, when the bag on the scale is outside the
tolerance window, an **AI weight-check** card appears with ranked, calibrated
explanations, e.g.:

- `Missing: Soft drink (large) — 100%` (order is under)
- `Extra item: Loaded fries — 68%` (order is over)
- `Might be #8712320 · Omar T. — 74%` + a **mix-up warning** (the weight
  matches a different queued order much better)

The model also nudges the matching **predefined reason tag** (marks it with a
★). It **never** auto-selects a reason or dispatches — staff always confirm.

### Why it is a calibrated statistical model, not a chatbot

The task is *precise and safety-relevant*: "which item is missing from this
bag?" The answer is fully determined by the **known weights** of each menu
component. A statistical model over those weights is:

- **Precise & honest** — it reasons over real gram distributions, so it can say
  "100% this is the missing drink" or "I can't tell confidently — check by
  hand." A language model would guess and could mislead staff.
- **Instant & offline** — runs on the tablet in microseconds, no network, no
  API cost, no delay. Ideal for a busy pack station.
- **Auditable** — every number is explainable.

Concretely: each menu item/modifier has a weight `~ Normal(mean, sd)`. Given the
gap between measured and expected weight, the model scores every possible cause
(missing item, missing add-on, extra item, extra add-on, mixed-up order, or
normal pack variation) with a **Gaussian likelihood**, combines it with trained
**priors**, and produces probabilities via a temperature-calibrated softmax.
Explanations that don't actually shrink the gap, or that fall below a
confidence floor, are hidden — if nothing fits, it says so.

### Files

| File | Role |
| --- | --- |
| `lib/ai/discrepancy.dart` | Result/Prediction data types |
| `lib/ai/discrepancy_model_config.dart` | Trained parameters (+ safe fallback) |
| `lib/ai/discrepancy_engine.dart` | The inference engine (pure Dart) |
| `lib/ai/discrepancy_providers.dart` | Loads the model asset, exposes the engine |
| `tool/train_discrepancy_model.dart` | Trainer / calibrator (CLI) |
| `assets/models/discrepancy_model.json` | **The saved trained model** (loaded at runtime) |
| `assets/models/training_metrics.json` | **Saved training metrics** (shown in Settings) |
| `assets/models/training_report.md` | Human-readable training report |
| `test/discrepancy_engine_test.dart` | Deterministic engine unit tests |

### Current metrics (held-out test set, v1.0.0)

| Metric | Value |
| --- | --- |
| Strict top-1 accuracy (right cause **and** right component) | **84.5%** |
| Class accuracy | **91.5%** |
| Top-3 hit rate | **94.3%** |
| Brier score (0 = perfectly calibrated) | **0.116** |

Remaining errors are mostly *inherent weight ambiguity* — two components of
near-identical weight cannot be told apart by weight alone; in those cases the
correct answer almost always still appears in the top 3. Changes smaller than
the tolerance window are treated as on-weight (nothing to detect) by design.
These metrics are visible in **Settings → AI weight-check model**.

### Retraining / updating the model (it's flexible)

The training is deterministic (fixed RNG seed) and uses the **same** inference
code the app ships, so metrics reflect real behaviour.

```bash
# from the project root
dart run tool/train_discrepancy_model.dart 1.1.0   # arg = new version string
```

This regenerates all three `assets/models/*` files. Then rebuild the app.

**Three ways to update the model, in increasing effort:**

1. **Recalibrate** — just rerun the trainer (above). Use this after you change
   menu weights so priors/noise re-fit.
2. **Hot-swap the file** — drop a new `discrepancy_model.json` into
   `assets/models/` (same schema) and rebuild. No code change. You could also
   point `discrepancyConfigProvider` at a **remote URL** to push model updates
   over the air.
3. **Swap the whole engine** — `DiscrepancyEngine` is an interface (like
   `WeightSource`/`OrderRepository`). Implement a new engine (e.g. a cloud
   model) and return it from `discrepancyEngineProvider`. The UI is untouched.

If the asset is ever missing or corrupt, the app falls back to safe built-in
defaults (`DiscrepancyModelConfig.fallback`) — the feature never crashes.

### Tuning knobs (in `discrepancy_model.json`)

- `priorMissing*/priorExtra*/priorWrongOrder/priorNaturalVariation` — how likely
  each cause is a priori.
- `scaleNoiseGrams` — measurement noise folded into every likelihood.
- `confidenceTemperature` — higher = less overconfident probabilities.
- `minConfidenceToShow` — hides weak guesses (raise it to be more conservative).
- `wrongOrderMarginGrams` — how much better another order must fit to flag a
  mix-up.
- `maxSuggestions` — how many ranked reasons to show.

---

## 2. Foodics POS integration

This is a **real, live-verified** integration against the Foodics v5 API
(`https://api.foodics.com/v5`), built and tested with the nine brand tokens.

### How to use it — 3 taps

**Settings → Foodics POS:**

1. Toggle **Use live Foodics orders** on.
2. **Brand** — pick from the nine bundled brands (Mishmash, Tabel, Yelo Pizza,
   Shawarma Shakir, Slice, Pattie Pattie, BBT, BUR, Chili Pepper). The token is
   resolved automatically — no pasting.
3. **Branch** — the dropdown loads that brand's branches live; pick the station.
4. **Sync menu from Foodics** — pulls the brand's products in as menu items
   (keyed by Foodics product id) with **plausible starter weights** auto-filled
   by product type (burger ≈250 g, drink ≈400 g, fries ≈150 g, sauce ≈30 g,
   combo ≈700 g, …) so you can trial immediately. Edit any of them in
   **Settings → Menu item weights**; re-syncing preserves weights you've
   changed and only adds/updates names. (`lib/data/dummy_weights.dart`.)
5. (Optional) **Poll interval** — default 10 s.

While the toggle is off *or* no brand/branch is chosen, the app shows built-in
sample orders, so it always works.

### Brands & tokens (security)

- Tokens live in **`assets/foodics/brands.json`** (bundled), generated from your
  `# FOODICS BRAND API KEYS.txt`. Both files are **git-ignored**.
- ⚠️ Bundling long-lived tokens in an app means anyone who extracts the APK can
  read that brand's orders/customers. For an internal, controlled tablet this is
  usually acceptable, but **rotate the tokens** if a device is lost, and keep the
  APK private. To rotate: replace the tokens in the keys file and regenerate
  `brands.json` (see the generator snippet in the repo history), then rebuild.

### What was learned from the live API (and handled)

| Reality | How the app handles it |
| --- | --- |
| Foodics sits behind **Cloudflare**, which blocks default HTTP clients (error 1010) | `FoodicsApi` sends a browser-like **User-Agent** — verified to pass |
| Auth is **Bearer token**, 90 req/min per token | 10 s polling = ~6 req/min, well under the limit |
| Order **status**: `1,2,3` = open/active, `4` = closed | Queue fetches `filter[status]=1,2,3` only — exactly the bags to check |
| Orders sortable by `created_at` (not `opened_at`) | Uses `sort=-created_at` (newest first) |
| `filter[...]` brackets must stay literal-ish; only `products`, `products.product`, `customer` are valid order includes (`products.modifiers` is **not**) | Query is built to match; live orders compared at **product** granularity |
| **Products carry no weight** | Weights are maintained in-app (menu manager); synced products keep their weights across re-syncs |
| Pagination: 50/page; orders capped at 10 pages | We only need page 1 of open orders per branch |

### Architecture

- **`lib/data/foodics_api.dart`** — resilient client: User-Agent, 12 s timeout,
  2 retries, clear 401/403/429 errors, pagination. Endpoints: `listBranches()`,
  `listOpenOrders(branchId)`, `listProducts()`.
- **`lib/data/foodics_order_repository.dart`** — `OrderRepository` impl. Realtime
  `watchOrders()` polls open orders; maps each Foodics order → `Order`
  (id = order number, customer = "First L.", line product ids × quantity).
  Transient poll errors are swallowed so the queue never flickers.
- **`lib/state/foodics_controller.dart`** — loads brands, resolves the active
  brand, loads branches live.
- **`orderRepositoryProvider`** — swaps to Foodics automatically when live; the
  mock otherwise. UI is unchanged either way.
- **Menu sync** — `SettingsController.syncFoodicsMenu()` fetches products and
  upserts them as menu items by product id, **preserving weighed data**.

Because synced menu items use the Foodics **product id** as their id, live order
lines line up with weighed data automatically — no manual id mapping needed.

### Notes / limitations

- **Modifiers on live orders**: the Foodics order API does not expose selected
  modifiers on order lines, so live orders are weight-checked at product level.
  (Manual/mock orders still support modifiers in full.)
- **Dispatch is local**: the provided tokens are read-only (`orders.list`), so
  "Confirm & dispatch" marks the order locally; it is not pushed back to
  Foodics. The order naturally leaves the queue once Foodics marks it closed.
- **Weights**: after syncing a brand's menu, enter each item's weighed data in
  **Settings → Menu item weights** so the checks and AI model work.

### Going live checklist

- [ ] Toggle on, pick **brand**, pick **branch**.
- [ ] **Sync menu from Foodics** for that brand.
- [ ] Enter weighed data for the items you pack.
- [ ] Confirm the queue fills with that branch's open orders within one poll.

---

## 3. Where things are saved

- **Trained model + metrics** — `assets/models/*.json` (bundled into the app).
- **All settings** (Foodics config, tolerance, weight source, menu) — persisted
  locally via `shared_preferences`, surviving restarts, with in-memory
  fallback if storage fails.
