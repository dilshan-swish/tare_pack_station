# Weight-prediction model contract (v1)

This is the exact interface a `.tflite` file must implement to be usable as
this app's weight-prediction model. It's enforced by convention, not by the
app (a model that doesn't match this shape will fail to run and the app
falls back to the built-in statistical formula automatically — see
`lib/ai/weight_predictor.dart`).

## Why a fixed, small contract

There's no real trained model yet — this exists so the *pipeline* (publish
from head office, download to the tablet, cache, run, fall back safely) can
be built and tested today, and so training a real model later has a concrete
target instead of a guess. It deliberately does NOT depend on a per-brand
vocabulary of item/modifier ids, so the same input shape works for every
brand without needing a companion vocabulary file shipped alongside the model.

## Input tensor: `float32[6]`

| Index | Meaning |
|---|---|
| 0 | Number of line items on the order |
| 1 | Total number of selected modifiers across all lines |
| 2 | Sum of each item's configured base weight (grams) |
| 3 | Sum of each selected modifier's configured weight (grams) |
| 4 | Sum of each item's configured packaging weight (grams) |
| 5 | The app's own statistical expected weight for this order (grams) — i.e. what `WeightEvaluator.expectedFor()` already computes |

Index 5 is deliberately included as a strong prior: a model that just learns
a small *correction* on top of the existing formula is far more robust than
one predicting a total weight from scratch, and can't make things wildly
worse even if poorly trained (worst case, it barely deviates from today's
already-shipped, tuned tolerance formula).

## Output tensor: `float32[2]`

| Index | Meaning |
|---|---|
| 0 | Predicted expected weight (grams) |
| 1 | Predicted standard deviation (grams) — used the same way `combinedStdDev` is today, i.e. multiplied by the tolerance settings' std-dev multiplier |

## Training data

Export via the portal's Dashboard → "Export weighed orders" (CSV), or
`GET /api/weigh-events/export`. Each row is one completed weigh: item/modifier
composition (`items_json`), the app's own expected range at the time, the
measured weight, and the verdict. Only rows with a real `measured_g` are
useful as training targets; `unconfigured` rows are still valuable — they're
exactly the cases where the app *couldn't* compute a reliable expected
weight, which is precisely what a trained model could improve on.

## Publishing

Upload the converted `.tflite` file from the portal (Brands → a brand →
"AI model"). Every tablet registered to that brand picks it up automatically
within about 20 seconds (the same poll that already checks for menu
updates), with zero app update needed. If inference on a downloaded model
ever throws (wrong shape, corrupted file, anything) the app silently falls
back to the statistical formula — a bad model can degrade accuracy, but it
can never crash the weigh-check flow or block dispatching an order.

## Converting a trained model to `.tflite`

- **TensorFlow / Keras**: `tf.lite.TFLiteConverter.from_keras_model(model).convert()`.
- **PyTorch**: export to ONNX first (`torch.onnx.export`), then convert
  ONNX → TFLite (e.g. via `onnx2tf` or `onnx-tf`).
- **scikit-learn**: convert to ONNX via `skl2onnx`, then ONNX → TFLite as above.

Whatever the training framework, the exported model's input/output tensors
must match the shapes above.
