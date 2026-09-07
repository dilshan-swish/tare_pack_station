# TARE. — Pack Station Weight-Check App

A Flutter app for a tablet mounted at a food-pack station. Staff pick an order
from a queue, weigh the packed bag, and the app confirms whether the measured
weight matches the expected weight before the order is dispatched to a driver.

There is no physical scale yet, so weight entry is **manual** — but the weight
source is behind a swappable interface so a real RS-232/USB scale can be dropped
in later as a one-file change.

## Running

```bash
flutter pub get
flutter run -d chrome      # local preview (any browser)
flutter analyze            # no errors or warnings
flutter test               # weight-evaluation unit tests
```

The app targets an 8–10" tablet in landscape but is responsive down to phone
width (single-column) and up to desktop (three-column grid).

## The scale is a single shared weight

There is one physical scale at the station, so the measured weight is a single
shared value ("what is currently on the scale"), not a per-order field. It lives
in `scaleReadingProvider` (fed by the active `WeightSource`) and is shown on the
main queue screen. Every order's on/under/over verdict is derived live from that
one weight and the order's own expected weight, so as the weight changes, every
card updates in realtime. The order detail screen reads and writes the same
shared value, so it stays consistent across screens.

## Architecture

```
lib/
  models/        Plain data classes (Order, MenuItem, WeightReading, settings…)
  logic/         WeightEvaluator — pure expected-weight + tolerance math
  weight/        WeightSource interface + Manual / Serial (stub) implementations
  data/          OrderRepository (Mock), SettingsStore (shared_preferences), menu seed
  state/         Riverpod providers (settings, orders, weight source, evaluation)
  theme/         Brand colours, Google Fonts typography, neubrutalist shape tokens
  widgets/       NeoCard, StatusPill, PillButton, NeoChip, BrandHeader
  screens/       Orders queue, order detail / weigh-check, settings, menu editor
```

### Swapping in a real scale

`WeightSource` (`lib/weight/weight_source.dart`) is the single seam. Today
`ManualWeightSource` is wired up. `SerialStreamingWeightSource` and
`SerialPollingWeightSource` are stubbed with the exact read-loop shape
documented inline — search for `TODO: add usb_serial` to find the spots to
fill in when hardware arrives. All `usb_serial` use is guarded with `kIsWeb` /
platform checks so the app still builds and runs on web/desktop.

### Swapping in a real POS

`OrderRepository` (`lib/data/order_repository.dart`) is the seam for orders.
`MockOrderRepository` generates sample orders; an `ApiOrderRepository` can be
substituted by changing `orderRepositoryProvider` only.

## Tolerance

An order is on/under/over weight based on the largest of three floors:

```
tolerance = max( stdDevMultiplier × σ,  percentFloor% × expected,  absoluteGramFloor )
```

All three are editable in Settings, with a live formula preview. Changing them
re-evaluates every order immediately.
