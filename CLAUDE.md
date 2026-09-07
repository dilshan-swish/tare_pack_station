# TARE. — Pack Station Weight-Check App
### Build brief for Claude Code — paste this whole file as your first message, or save it as `CLAUDE.md` in the project root so Claude Code reads it automatically.

---

## 0. What this app is

A Flutter app for a tablet mounted at a food-pack station. Staff pick an order from a queue, weigh the packed bag on a scale, and the app tells them whether the measured weight matches the expected weight for that order — before it's dispatched to a driver.

**Current phase: no physical scale yet.** Build the whole app now with a **manual weight entry** input standing in for the scale, but architect the weight source as a swappable interface so that plugging in the real scale later (RS‑232/USB, either continuously streaming or poll/response) is a one-file change, not a rewrite. Details on that in section 4.

---

## 1. Design system — match this exactly, no substitutions

This app has an existing visual identity from an approved brochure. Do not default to Material 3 defaults, generic blue, or rounded Material cards — recreate this specific look.

**Colors**
```
green       #2F8F5B   — primary background
green-dark  #256B45   — pressed/dark accents
cream       #F6F1E3   — card surfaces
ink         #161B14   — text, borders, primary buttons (near-black, not pure black)
coral       #E8604C   — "under weight" state
amber       #F3A93B   — "over weight" state
ok-green    #DFF2E6 bg / #1C5C39 text — "on weight" state
```

**Typography** (use the `google_fonts` package, do not bundle font files)
- Display / headings: **Archivo Black** — bold, blocky, used sparingly for titles.
- Body / UI text: **Inter** — weights 400/500/600/700.
- Data / weight readouts: **Space Mono** — every gram value, every code-like figure uses this. This is a signature detail, don't skip it.

**Shape language**
- Cards: cream background, **2.5px solid ink border**, **20px border radius**, **hard offset drop shadow** (`7px 7px 0` in ink at ~90% opacity) — not a soft blurred Material shadow. This "neubrutalist" hard-shadow look is the whole visual signature of the app. Recreate it with a `Container` using `BoxShadow(offset: Offset(7,7), blurRadius: 0, color: ink.withOpacity(0.9))` plus a 2.5px border.
- Pills/badges/buttons: fully rounded (`BorderRadius.circular(999)`), 2px ink border where they sit on cream, solid ink fill where they sit on green.
- Status pills reuse this pattern:
  - On weight → cream `#DFF2E6` bg, `#1C5C39` text, ✓ prefix
  - Under → `#FBE1DC` bg, `#8A2F1F` text, ↓ prefix
  - Over → amber bg, ink text, ↑ prefix

**Reference screens to recreate faithfully** (I'll attach the original mockup images — use them as ground truth for layout, spacing, and copy tone):
1. Orders queue — grid of order cards (customer name, order #, item count, "ready in" / "dasher in" timers, a status pill).
2. Order detail / weigh-check — big MEASURED vs EXPECTED number panel, a status banner, a reason-picker (chip buttons) that appears only when the order is off-weight, "Re-weigh order" and "Confirm and dispatch" actions.

---

## 2. Screens to build

1. **Orders Queue** — responsive grid of order cards pulled from a mock/local order list (see §6 for POS API stubbing). Tapping a card opens Order Detail.
2. **Order Detail / Weigh-Check** — shows the order's items, the MEASURED vs EXPECTED comparison, live status (on/under/over), reason chips when off-weight, Confirm & Dispatch (disabled until a reason is picked if off-weight), Re-weigh.
3. **Settings** — see §5, full spec below.
4. **Menu Item Weight Manager** (part of Settings) — add/edit menu items and their weighed data: base item weight, list of optional modifiers with their own weights, packaging weight. In test mode, "weighing" an item means typing a number, not placing it on a scale — make that explicit in the UI copy.

---

## 3. Data model

```dart
class Order {
  final String id;
  final String customerName;
  final List<OrderItem> items;
  final int readyInMinutes;
  final int dasherInMinutes;
  final OrderStatus status; // pending, onWeight, under, over, dispatched
}

class OrderItem {
  final String menuItemId;
  final List<String> selectedModifierIds;
}

class MenuItem {
  final String id;
  final String name;
  final double baseWeightGrams;
  final double baseWeightStdDev;
  final List<Modifier> availableModifiers;
  final double packagingWeightGrams;
}

class Modifier {
  final String id;
  final String name;
  final double weightGrams;
  final double weightStdDev;
}

class WeightReading {
  final double grams;
  final bool stable;       // true = settled reading, false = still moving
  final DateTime timestamp;
  final WeightSourceType source; // manual, serialStreaming, serialPolling
}
```

---

## 4. Weight source abstraction — build this even though only one implementation is used right now

```dart
abstract class WeightSource {
  Stream<WeightReading> get readings;
  Future<void> connect();
  Future<void> disconnect();
  bool get isConnected;
}
```

Implement now:
- **`ManualWeightSource`** — the only one wired up today. UI: a numeric input (with +/- stepper buttons and a "Simulate stable reading" toggle) that emits a `WeightReading` whenever changed. Always mark it clearly as a stand-in, e.g. a small "TEST MODE — manual entry" badge near the input, in the same amber/ink pill style as the rest of the UI.

Stub only (do not wire to real hardware yet, but write the class shape so swapping in Settings is trivial later):
- **`SerialStreamingWeightSource`** — for scale protocols that push data continuously (e.g. the "8217 Mettler‑Toledo WO" continuous stream). Would use the `usb_serial` package.
- **`SerialPollingWeightSource`** — for protocols that only answer a request (send a poll command, e.g. `W\r`, then read one response). Same package, different read loop: listen passively for ~2s, and if nothing arrives, send the poll command and listen again.

Wrap all real hardware calls (once implemented) in try/catch; `usb_serial` is Android-only, so guard any reference to it with `if (!kIsWeb)` and provide a graceful "not supported on this platform" fallback so the app still builds and runs on web/desktop for local preview.

A `Settings` toggle selects which `WeightSource` implementation is active (see §5). Default to Manual for now.

---

## 5. Settings panel — build this fully now

- **Weight source mode**: Manual (test) / Serial – Streaming / Serial – Polling. Serial options should be visibly present but can show a "connect a scale to use this" empty state, since there's no hardware yet.
- **Serial connection settings** (only relevant/shown when a serial mode is picked): baud rate, parity, data bits, stop bits, protocol name — these map directly to the scale's own setup menu (values like 9600 / Even / 7 / 1 / "8217 Mettler‑Toledo"), stored so they're ready to use the moment hardware is connected.
- **Tolerance settings**: editable numeric fields for
  - standard-deviation multiplier (default 2)
  - percentage-of-expected floor (default 5%)
  - absolute gram floor (default ~5g, matching a real scale's readability — make this configurable since different scales resolve differently)
  - Show the computed formula live as the person adjusts these, same monospace formula-box styling as the brochure.
- **Menu item weight manager**: list, add, edit, delete menu items and their modifiers/packaging weight (§2.4).
- Persist all settings locally (see §7 packages) so they survive an app restart.

---

## 6. POS order data — stub it, but structure it like a real integration

Don't hard-code a fixed order list in the UI. Create an `OrderRepository` interface with a `MockOrderRepository` implementation that generates a handful of realistic sample orders (matching the tone of the reference screenshots: customer first name + last initial, 2-4 items with modifiers, staggered ready/dasher timers). Structure it so a future `ApiOrderRepository` (hitting a real POS's REST API) can be swapped in without touching UI code — same pattern as the weight source.

---

## 7. Packages to add

```
flutter pub add flutter_riverpod        # state management
flutter pub add google_fonts            # Archivo Black / Inter / Space Mono
flutter pub add shared_preferences      # persist settings locally
flutter pub add uuid                    # generate ids for mock orders/items
flutter pub add intl                    # number/date formatting
flutter pub add usb_serial              # future real-scale connection (guard with kIsWeb / Platform checks; not used in test mode)
flutter pub add http                    # future POS API calls (mocked for now)

flutter pub add -d flutter_lints        # dev dependency, catches issues early
```

If `usb_serial` causes any pub resolution issues on your Flutter version, it's safe to skip adding it for now and stub the two serial `WeightSource` classes as empty shells that throw `UnimplementedError` — just leave a `// TODO: add usb_serial when the physical scale is available` comment so it's obvious what to do later.

---

## 8. Responsiveness — tablet is the primary target, not an afterthought

This app is built for an 8–10" tablet mounted at a pack station, mostly in landscape, but must not break on other sizes.

- Use `LayoutBuilder` / `MediaQuery` breakpoints rather than fixed pixel widths anywhere.
- Orders Queue: `GridView` with `SliverGridDelegateWithMaxCrossAxisExtent` (not a fixed column count) so the grid reflows naturally between phone and tablet widths.
- Order Detail: two-column layout (order summary | weigh-check panel) above ~700px width, single stacked column below it.
- Test explicitly at: 1024×768 (tablet landscape, primary), 768×1024 (tablet portrait), 390×844 (phone, secondary).
- Respect `MediaQuery` text scaling — don't hardcode text sizes that break with system font-size settings.
- All tap targets at least 44×44 logical pixels — this is used with wet/gloved hands at a pack station.

---

## 9. Exception handling — required, not optional

- Manual weight input: reject non-numeric input, negative numbers, and absurd values (e.g. >50kg) with an inline error, not a crash.
- Weight source disconnect (once real sources exist): show a clear "Scale not responding" state and block "Confirm and dispatch" until reconnected.
- Order repository failure (mock or real): show a retry-able error state on the Orders Queue, never a blank screen or an uncaught exception.
- Settings persistence failure: fall back to in-memory defaults for that session rather than crashing on startup.
- Dispatching an off-weight order: require a reason to be selected before the "Confirm and dispatch" button becomes enabled.
- Wrap every `Future`/`Stream` interaction with hardware or storage in try/catch, and surface failures as user-readable state, never as a raw stack trace in the UI.

---

## 10. Definition of done

- `flutter analyze` returns no errors or warnings.
- `flutter run -d chrome` launches successfully and every screen is reachable and usable with a mouse (for local preview).
- Manual test mode works end-to-end: pick an order, type a weight, see on/under/over, pick a reason if needed, confirm and dispatch.
- Settings panel changes are visibly reflected elsewhere (e.g. changing tolerance changes the on/under/over outcome for the same weight).
- Resizing the window between roughly 390px and 1280px wide never clips, overflows, or crashes.
- Visual style matches §1 exactly — cream cards with hard ink shadows on a green background, Archivo Black headings, Space Mono weight figures.
