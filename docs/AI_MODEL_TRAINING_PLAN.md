# AI weight model — training pipeline plan

Status: **proposal, not yet built.** This document is the plan discussed before any
of it is implemented — expect it to change as decisions get made.

---

## 1. The question you asked first: do we still need per-item/modifier weights?

**Short answer: less over time, but not zero, and not yet.** Here's the precise
reasoning, since "yes" or "no" alone would be misleading.

A model that predicts an order's total weight from its item + modifier
composition is, mathematically, solving a big system of equations: every real
weighed order is one equation (`sum of this order's components = measured
weight`), and the "unknowns" are each component's true weight. With enough
orders that share components in different combinations, that system becomes
solvable — the model genuinely can *learn* Regular Fries' weight from data
alone, never having been told it by a human. That's exactly the mechanism
behind training a linear regression over one-hot-encoded components, and it's
real, not a simplification.

The catch is **identifiability**. If "SUUUBER™ Chicken" only ever appears in
one fixed combo, always with the exact same two modifiers, no amount of data
volume lets the model tell "the item's weight" apart from "its modifiers'
weight" — every equation involving it looks the same. Collinearity, not a data
volume problem. Two things fix it: (a) items that legitimately appear
standalone *and* in combos, or with different modifier choices, become fully
learnable fast; (b) for everything else, a **manually-entered weight acts as a
prior** the model starts from and refines, rather than a value it's forced to
treat as gospel forever.

So the honest plan: keep the manual weight fields as the fallback/starting
point they already are, but stop treating them as the only source of truth.
The model uses them as a prior when data is thin, and lets real measurements
pull the estimate toward reality as evidence accumulates — which also directly
answers your last question ("at the end of the day, when I have a larger
dataset it should be accurate"): this is precisely what that design gets you,
by construction, not as a hoped-for side effect.

---

## 2. Model choice — the actual research, not just a pick

Four real candidates, compared against what this data actually looks like:
a **modest number of rows per brand** (hundreds to low thousands of orders,
not millions), a **strictly additive physical process** (total weight really
is the sum of parts, plus noise — this isn't a pattern the model has to
discover, it's a fact about physics we already know), and a need for
**per-component uncertainty**, not just a point estimate.

| Approach | Fit for this problem |
|---|---|
| **Ridge / regularized linear regression over per-component one-hot features** | **Recommended.** Bakes in the additive-physics assumption instead of making the model rediscover it, so it needs far less data than a general-purpose model to get accurate. Coefficients *are* each component's learned weight — directly interpretable, and reusable elsewhere (see §5). Refitting is seconds, not hours, on this data size — no GPU, no long training runs. |
| **Gradient-boosted trees (XGBoost/LightGBM)** | Would find nonlinear interactions on its own, but that's not the problem here — the known nonlinear cases (a combo-size choice affecting two things at once) are *already* handled explicitly by `ModifierCombinationWeights`. Without that inductive bias, trees need much more data to reach the same accuracy, don't compose additively for combinations they've never seen, and lose the clean "this number is that component's weight" interpretability. Worth revisiting only if the dataset gets much larger and interactions turn out messier than expected. |
| **A small neural net** | Same problem as trees, worse: needs the most data of any option here, and modern in-context reasons to prefer it (representation learning on unstructured input) don't apply — this input is already fully structured. Would be solving a harder problem than the one that exists. |
| **Hierarchical/Bayesian shrinkage on top of the linear model** | Not a competing choice — a refinement of the first one. Instead of shrinking every coefficient toward zero (plain Ridge), shrink a thin-data component (e.g. "Regular Fries when paired with Fillaa on Toast") toward the *pooled* average across all its pairings, and shrink that in turn toward the manually-entered prior. This is the actual mechanism that makes "confident with more data, cautious with little" happen automatically, component by component, rather than a single global regularization strength. Worth building once the plain version works — see the phased plan in §7. |

**The recommendation**: Ridge regression over one-hot component features,
with shrinkage toward a manually-entered prior, refined later toward
per-component pooled shrinkage. Not a trend chase — the reasoning above is
specific to this data shape, and it's the same reasoning that makes this the
standard approach for exactly this class of problem (decomposing a measured
total into additive, partially-shared components) in fields that have dealt
with it for decades — retail/inventory costing, lab-instrument calibration,
that kind of thing.

---

## 3. How the model actually sees your example

Every feature here is a real database ID, never a name — `MenuItem` and
`Modifier` are separate tables with their own primary keys
(`Entities.cs:73`, `Entities.cs:100`), so "Regular Fries" existing as both a
standalone item and a modifier option under a combo is already safe: two
different rows, two different ID spaces, and the export's own `item:`/
`modifier:` string prefix disambiguates them a second time on top of that.
No naming collision is possible, by construction.

The part worth being precise about: the export's existing `Key` for a plain
modifier (`WeighEventsController.cs:611-620`) is `modifier:<ModifierId>` —
the *same string* every time that modifier is chosen, regardless of which
item it's attached to. `LineIndex` says which order line a component came
from, not which item that line was. So today, on its own, this key does
**not** capture your exact requirement — Regular Fries under two different
combos currently looks identical to a model reading only this field.

The fix is a feature the training script builds, not a change to the
export: join each modifier component to the item component sharing its
`LineIndex`, and fit **two** features for it, not one —

```
Toasts Duo Combo            → item:<ToastsDuoComboId>
  + Regular Fries            → modifier:<RegularFriesId>                (pooled, general estimate)
                             → item:<ToastsDuoComboId>|modifier:<RegularFriesId>   (specific to this pairing)

Fillaa on Toast Duo Combo    → item:<FillaaOnToastId>
  + Regular Fries            → modifier:<RegularFriesId>                (same pooled feature as above)
                             → item:<FillaaOnToastId>|modifier:<RegularFriesId>    (different pairing, own estimate)
```

The plain `modifier:<id>` feature is what lets a thin pairing (seen only a
few times) borrow strength from every other order that ever used that
modifier, instead of overfitting to two data points. The composite
`item|modifier` feature is what lets a well-supported pairing — like Regular
Fries under a combo you sell constantly — earn its own precise, different
number. Ridge's regularization is what decides, per pairing, how much weight
each one gets as evidence accumulates — exactly the mechanism in §2, applied
here.

`ModifierCombinationWeights` stays doing what it already does: the
multi-way case where a single choice (say, a combo's size pick) moves two
modifiers' weights at once. That's a genuine interaction the pairwise
scheme above doesn't reach, and it's already handled today by explicit
configuration — this pipeline doesn't replace that, it covers the simpler
one-modifier-under-one-item case automatically instead of requiring it to
be hand-configured too.

---

## 4. Missing-item detection — not a second model

It's tempting to read "the AI must detect what's missing" as "train a
classifier that outputs *which* item is missing." Don't build that — it needs
its own labeled dataset of *confirmed* missing items, which barely exists (see
below), and this codebase already has a working, deterministic layer that
answers the question without one.

That layer is `WeightInferenceEngine.analyze()` (`lib/ai/discrepancy_engine.dart`),
already shipping today. It builds one hypothesis per component actually in the
order — "what if *this* item were missing," "what if *this* modifier were
missing" — one at a time, alongside "extra item," "wrong order," and "just
normal variation." Each hypothesis gets a Gaussian likelihood score against
the leftover residual, combined with a learned prior per hypothesis type
(how common a missing item is versus an extra one, versus a mix-up) — those
priors are themselves a small trained artifact, `DiscrepancyModelConfig`,
already produced today by `tool/train_discrepancy_model.dart`. Every
hypothesis, across every category, is then ranked on one shared probability
scale and the top few (plural — up to `maxSuggestions`) above a confidence
floor come back as the answer.

What that engine currently reads for each component's mean and uncertainty
is a manually-typed number — `MenuItem.baseWeightGrams`/`baseWeightStdDev`,
`Modifier.weightGrams`/`weightStdDev` — flat and context-blind. **The
regression model from §2–3 doesn't add a second detection system; it fills
those same two inputs with learned numbers instead** — the item+modifier
composite mean, and a real fit-based uncertainty that shrinks as data grows.
No change to the detection logic itself.

One real limitation worth being explicit about: it only tests removing one
component at a time, never two-at-once combinations — a missing item and a
missing modifier occurring together would surface as whichever single one
fits best, not the true pair. Deliberate for now (a single miss is far more
common), revisit only if it turns out to matter in practice.

**Evaluating it** does need labels, and there's a real source already
sitting in the database: `WeighEvents.OverrideReason` — when staff pick "Item
left off scale" or similar before dispatching an off-weight order, that's a
human-confirmed signal. It's noisy (staff don't always pick the precise
reason) but it's real, free, and already being collected. Precision/recall for
the missing-item detector gets computed against this, not against a
purpose-built labeling effort.

---

## 5. The full pipeline, end to end

```
WeighEvents (SQL Server)            Uploaded historical data (optional)
  measured weight +                   CSV/JSON, same shape, for
  full item/modifier composition      backfilling pre-system data
        │                                    │
        └──────────────┬─────────────────────┘
                        ▼
              Feature encoding
     (item:id / modifier:id-per-item-context,
      reusing the existing training-export Key scheme)
                        │
                        ▼
           Training job (see §6 for where this runs)
       Ridge regression, shrinkage toward manual-entry prior
                        │
           ┌────────────┴────────────┐
           ▼                         ▼
  Learned per-component      Exported .tflite model
  weights (could also           (same format the
  refresh MenuItems/            tablet already
  Modifiers weight fields    downloads and runs —
  in the portal, as a          no change needed
  suggestion, not              on-device)
  an auto-overwrite)                │
                                     ▼
                       BrandWeightModels (SQL Server)
                    — the exact table + versioning + hash-
                      verification pipeline already built
                    and already working end to end today
                                     │
                                     ▼
                  Tablet downloads it via the existing
                  weight_model_controller.dart / WeightPredictor
                  path — genuinely no tablet-side changes needed
```

The reassuring part: everything from "published model" onward already exists
and already works. This plan is entirely about the upstream half — turning
real weighed orders into a properly-trained model, on a schedule you control,
instead of by hand.

---

## 6. Where training actually runs — a real decision, not a detail

The existing backend is 100% .NET, no Python anywhere. Two honest options:

**Option A — train natively in C#** (e.g. via the `Math.NET Numerics`
library, a mature .NET linear-algebra package). No new runtime on the server.
The blocker: the tablet's on-device model loader (`tflite_flutter`) expects a
real `.tflite` file, and hand-constructing that binary format from C# with no
existing tooling is a real, fragile undertaking — this is the one place a
from-scratch build gets genuinely risky.

**Option B — a small Python training service** (invoked as a subprocess or a
lightweight sidecar the API shells out to when a run starts, not a
user-facing thing). Training math is simple either way (a few dozen lines of
NumPy/scikit-learn), but exporting a valid `.tflite` file is a single,
well-tested library call (`tf.lite.TFLiteConverter`) instead of a fragile
reimplementation. The honest cost: Python has to be installed on the server
alongside the .NET runtime, which is a real addition to what's currently a
clean single-runtime deployment (see `docs/PRODUCTION_DEPLOYMENT_GUIDE.md`).

**Recommendation: Option B**, specifically *because* of the TFLite export
requirement — that's the one step where reusing mature, correct tooling
clearly beats a DIY reimplementation, and it's worth the one added
dependency. Worth confirming you're comfortable adding Python to the server
before this is locked in, since it's the one part of this plan that changes
your ops footprint.

---

## 7. The interactive training UI

One honest calibration first: **"epochs," "precision," and "recall" don't all
apply the way they do for a classifier.** A Ridge regression normally solves
in one shot (closed-form), not iteration by iteration — there's no natural
"epoch" to watch. Two ways to handle this, worth picking deliberately rather
than defaulting into it:

- Train it properly (closed-form or a few dozen iterations) and show a
  simpler, honest live view: rows processed, current MAE/RMSE/R² on a held-out
  split, and a before/after comparison against the last published model.
- Or deliberately train via iterative gradient descent instead of the direct
  solve — mathematically unnecessary at this data size, but it buys a real,
  meaningful "watch the loss curve descend, epoch by epoch" experience if
  that's genuinely what you want to see. A legitimate trade of a little
  elegance for the interactive experience you asked for — not a compromise,
  a choice.

**Precision/recall belong to the missing-item detector specifically**
(evaluated against `OverrideReason`-confirmed cases, per §4), shown as its own
panel, not force-fit onto the weight regression's own metrics.

**Concretely, a new Portal page**:
- **Start a run** — pick the data source (live `WeighEvents`, optionally
  filtered by brand/date range, or an uploaded CSV/JSON for backfilling), set
  the regularization strength, hit start.
- **Live progress** — pushed from the backend over SignalR (ASP.NET Core's
  built-in real-time layer, no new infrastructure) as the run progresses:
  iteration/row count, current MAE/RMSE/R², elapsed time, a live-updating
  chart.
- **Missing-item evaluation panel** — precision/recall/F1 against confirmed
  `OverrideReason` cases, shown per run.
- **Run history** — every past run with its final metrics, so you can compare
  run over run and actually see the "gets more accurate with more data"
  effect happen, rather than trust it blind.
- **Publish** — one action that takes a finished run's model, writes it into
  `BrandWeightModels` with a new version number, and from that moment every
  tablet picks it up through the exact mechanism already running today.

---

## 8. A realistic build order

This is a genuinely large initiative — sequencing it so each phase is
independently useful, rather than one big all-or-nothing build:

1. **Prove the math.** Native script (Python, not yet wired to the app),
   trained against a real export from `WeighEvents`, checked against a
   held-out split. No UI, no publishing — just confirm the approach's
   accuracy is good enough before building anything around it.
2. **Wire up publishing.** Turn the proven script into a real training job
   the API can trigger, producing a `.tflite` file and writing it into
   `BrandWeightModels` — reusing the existing delivery path end to end, by
   hand at first (run the script, upload the result), no live UI yet.
3. **Build the interactive UI.** The Portal page, SignalR live progress,
   run history, the publish button — once the underlying pipeline in steps
   1–2 is already trustworthy.
4. **Wire up the missing-item evaluation loop.** Precision/recall against
   `OverrideReason`, surfaced per run, closing the loop on "is this actually
   getting better."
5. **Only once all of that is solid**, revisit per-component hierarchical
   shrinkage (§2's refinement) — a real improvement, but one that's easy to
   add later and shouldn't block getting the first working version live.

Nothing above is started yet — this is the plan to react to before any of
it gets built.
