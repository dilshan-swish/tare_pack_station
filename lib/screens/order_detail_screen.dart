import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/discrepancy.dart';
import '../ai/discrepancy_providers.dart';
import '../logic/modifier_pairing.dart';
import '../logic/weight_evaluator.dart';
import '../models/menu_item.dart';
import '../models/order.dart';
import '../models/order_item.dart';
import '../models/order_status.dart';
import '../models/weight_reading.dart';
import '../state/headoffice_controller.dart';
import '../state/menu_index_provider.dart';
import '../state/order_math.dart';
import '../state/orders_controller.dart';
import '../state/scale_controller.dart';
import '../state/settings_controller.dart';
import '../state/weigh_event_queue_controller.dart';
import '../state/weight_providers.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import '../weight/serial_weight_source.dart';
import '../widgets/kitchen_stage_pill.dart';
import '../widgets/neo_chip.dart';
import '../widgets/pill_button.dart';
import '../widgets/scale_pill.dart';
import '../widgets/themed_scrollbar.dart';
import '../widgets/weight_gauge.dart';

/// Reasons offered when an off-weight order is sent.
const _underReasons = [
  'No free extra / sauce',
  'No napkins / utensils',
  'Item left off scale',
  'Fewer bags were used',
  'Item out of stock',
  'Weight should be correct',
];

const _overReasons = [
  'Extra portion added',
  'Double bagged',
  'Extra sauce / sides',
  'Packaging heavier than usual',
  'Wrong item packed',
  'Weight should be correct',
];

/// Reason recorded when a heavier bag is quick-accepted through the giant
/// "Force Dispatch" action instead of an audited reason chip — kept distinct
/// from [_overReasons] so head office can separate an unaudited quick-accept
/// from a cause staff actually diagnosed, per-brand, for portion-control
/// review at the end of the day.
String _forceDispatchReason(double varianceGrams) =>
    'Force dispatched — not audited (+${varianceGrams.round()}g over)';

/// Reason recorded when an order that briefly read under-weight reaches the
/// expected range after the worker adds the missing item back into the bag —
/// distinct from a first-try pass, so head office can tell the two apart.
const _correctedReason = 'Corrected — item added after under-weight alert';

/// How long a (status, stable) reading must hold before it's treated as
/// "settled" — long enough that a bag bouncing on the platter as it's set
/// down (which often swings through several verdicts before resting) never
/// triggers an auto-action on a transient value, short enough that the
/// "zero-tap" flow still feels instant once the bag is actually still.
const _settleHold = Duration(milliseconds: 900);

/// How long the full-screen success flash shows before auto-returning home.
const _successFlashDuration = Duration(milliseconds: 1000);

/// Order detail / weigh-check — the clean "SmartScale" split: a receipt-style
/// summary on the left and a status panel on the right, on one scroll, no header.
class OrderDetailScreen extends ConsumerStatefulWidget {
  final String orderId;
  const OrderDetailScreen({super.key, required this.orderId});

  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen> {
  String? _selectedReason;
  final ScrollController _scroll = ScrollController();

  // --- "Zero-tap" auto-flow state ---------------------------------------
  //
  // The debounce: a bag settling on the platter routinely swings through
  // several verdicts before it rests, so nothing here reacts to the LIVE
  // eval.status directly. Instead every build re-arms a single [_settleTimer]
  // keyed off (status, stable); only once that key holds steady for
  // [_settleHold] does [_onSettled] fire, and only then do auto-dispatch, the
  // giant Force-Dispatch button, and the "Likely Missing" callout activate.
  Timer? _settleTimer;
  OrderStatus? _pendingSettleStatus;

  /// The confirmed, debounced verdict — drives the Force-Dispatch button and
  /// the "Likely Missing" callout. Null until something has actually settled.
  OrderStatus? _settledStatus;

  /// True once dispatch has actually started, so a stray extra frame (or a
  /// straggling settle timer) can never fire it twice.
  bool _autoActionInFlight = false;

  /// True if this weigh session was ever under-weight before reaching the
  /// expected range — tags the eventual dispatch as "Corrected" rather than a
  /// first-try pass, so head office can tell the two apart.
  bool _wasUnderThisSession = false;

  /// Shows the full-screen green success flash, then auto-returns home.
  bool _flashSuccess = false;

  /// Reveals the manual reason-picker + "Confirm & send" row underneath the
  /// giant Force-Dispatch button, for a worker who wants to log a specific
  /// reason instead of a quick unaudited accept.
  bool _showManualOverride = false;

  // --- Multi-bag accumulation ---------------------------------------------
  //
  // For orders split across bags that don't fit the platter together: each
  // bag is weighed one at a time, "More Bags" captures its stable reading
  // into this running total, and the math from then on evaluates against
  // capturedTotal + whatever's currently on the scale — so removing a
  // weighed bag to make room for the next one doesn't undercount it.
  final List<double> _capturedBags = [];

  /// True right after capturing a bag, until the scale reads empty again —
  /// suppresses auto-arming so the brief moment the just-captured bag is
  /// still physically on the platter is never double-counted as "settled".
  bool _awaitingBagRemoval = false;

  @override
  void dispose() {
    _scroll.dispose();
    _settleTimer?.cancel();
    super.dispose();
  }

  void _reweigh() {
    resetScale(ref);
    _settleTimer?.cancel();
    setState(() {
      _selectedReason = null;
      _pendingSettleStatus = null;
      _settledStatus = null;
      _wasUnderThisSession = false;
      _showManualOverride = false;
      _capturedBags.clear();
      _awaitingBagRemoval = false;
    });
  }

  /// The weight the app evaluates against: previously-captured bags plus
  /// whatever's currently on the scale. Identical to the raw reading when no
  /// bag has been captured yet, so single-bag orders are unaffected.
  double? _effectiveGrams(double? rawGrams) {
    if (_capturedBags.isEmpty) return rawGrams;
    final capturedTotal = _capturedBags.fold(0.0, (a, b) => a + b);
    return capturedTotal + (rawGrams ?? 0);
  }

  /// Captures the current stable reading as one more bag and waits for the
  /// scale to read empty again before the next bag can be weighed. Silently
  /// does nothing if there's no stable bag on the scale right now — the
  /// button itself is disabled in that case, but a stray tap (e.g. a queued
  /// event landing after the reading changed) must never corrupt the total.
  void _captureBag(double? rawGrams, bool stable) {
    if (rawGrams == null || !stable || _awaitingBagRemoval) return;
    setState(() {
      _capturedBags.add(rawGrams);
      _awaitingBagRemoval = true;
      // A fresh bag swap resets the settle state — the platter is about to
      // go empty then rise again, and none of that should count as "settled".
      _settleTimer?.cancel();
      _pendingSettleStatus = null;
      _settledStatus = null;
      // A single bag reading light before the rest are added is normal and
      // not a missing-item signal — only an under-weight reading against the
      // FINAL combined total should ever tag the eventual dispatch as
      // "Corrected". Tapping "More Bags" is the clearest point we can know
      // this was mid-sequence, not a genuine diagnosis.
      _wasUnderThisSession = false;
    });
  }

  void _undoLastBag() {
    if (_capturedBags.isEmpty) return;
    setState(() => _capturedBags.removeLast());
  }

  /// Watches the live (status, stable) pair every build and arms/re-arms the
  /// settle timer whenever it changes. A no-op when nothing has changed —
  /// safe to call on every rebuild, including ones the reading didn't cause.
  void _armAutoFlow({
    required OrderMath math,
    required WeightReading? reading,
    required bool serialNoReading,
    required Order? order,
  }) {
    final blocked = order == null ||
        order.status == OrderStatus.dispatched ||
        _autoActionInFlight ||
        math.unconfiguredItems.isNotEmpty ||
        serialNoReading ||
        _awaitingBagRemoval;

    final eval = math.evaluation;
    final stable = reading?.stable ?? false;
    final candidate = (!blocked && eval != null && stable) ? eval.status : null;

    // Only a single-bag order's under-weight reading is a genuine "missing
    // item" signal worth tagging "Corrected" once fixed. Mid multi-bag
    // sequence, every partial total short of the last bag reads under by
    // definition — that's expected, not an anomaly — so it must never trip
    // this flag (see the reset in _captureBag for the capture moment itself;
    // this guard also covers the gap between capturing one bag and the next
    // one landing on the scale).
    if (candidate == OrderStatus.under && _capturedBags.isEmpty) {
      _wasUnderThisSession = true;
    }

    if (candidate == _pendingSettleStatus) return;
    _settleTimer?.cancel();
    _pendingSettleStatus = candidate;
    if (candidate == null) {
      // A plain field write, not setState: this always runs from within
      // build() (see the call site), so the very next read of _settledStatus
      // later in this same build already sees the fresh value — calling
      // setState here would illegally request a rebuild mid-build.
      _settledStatus = null;
      return;
    }
    _settleTimer = Timer(_settleHold, () => _onSettled(candidate));
  }

  void _onSettled(OrderStatus status) {
    if (!mounted) return;
    setState(() => _settledStatus = status);
    if (status != OrderStatus.onWeight) return;

    // Re-validate against the freshest data at the moment the timer actually
    // fires, rather than trusting anything captured when it was scheduled.
    final order = ref.read(ordersProvider.notifier).orderById(widget.orderId);
    if (order == null || order.status == OrderStatus.dispatched) return;
    final grams = _effectiveGrams(ref.read(scaleGramsProvider));
    final math = computeOrderMath(ref, order, measuredGrams: grams);
    if (math.evaluation?.status != OrderStatus.onWeight) return;

    _completeDispatch(
      math,
      grams,
      _wasUnderThisSession ? _correctedReason : null,
    );
  }

  /// One-tap quick-accept for an overweight bag — no reason picker, the
  /// variance itself is the audit trail (see [_forceDispatchReason]).
  void _forceDispatch(OrderMath math, double? grams) {
    final eval = math.evaluation;
    if (eval == null) return;
    _completeDispatch(math, grams, _forceDispatchReason(eval.deltaGrams));
  }

  /// The single path every dispatch (manual, auto golden-path, and force-
  /// dispatch) funnels through: records the order, reports the weigh event,
  /// shows the success flash, then auto-returns home after a short delay.
  void _completeDispatch(OrderMath math, double? grams, String? reason) {
    if (_autoActionInFlight) return;
    _autoActionInFlight = true;
    _settleTimer?.cancel();

    final notifier = ref.read(ordersProvider.notifier);
    final order = notifier.orderById(widget.orderId);
    notifier.dispatch(widget.orderId, reason: reason);
    _postWeighEvent(math, grams, reason, order);

    if (!mounted) return;
    setState(() => _flashSuccess = true);
    Timer(_successFlashDuration, () {
      if (!mounted) return;
      Navigator.of(context).pop();
    });
  }

  /// Reports the completed weigh to head office (per-branch audit), including
  /// the order's own item/modifier composition — the raw material later
  /// exported for ML training (see `/api/weigh-events/export`). Guarded —
  /// and, if head office (or the network) is unreachable right now, queued
  /// locally by WeighEventQueueController rather than lost, so this weigh
  /// still shows up once connectivity returns.
  void _postWeighEvent(OrderMath math, double? grams, String? reason, Order? order) {
    if (ref.read(headOfficeApiProvider) == null) return;

    final eval = math.evaluation;
    final String verdict;
    if (math.unconfiguredItems.isNotEmpty) {
      verdict = 'unconfigured';
    } else {
      verdict = switch (eval?.status) {
        OrderStatus.onWeight => 'onweight',
        OrderStatus.under => 'under',
        OrderStatus.over => 'over',
        _ => 'unknown',
      };
    }

    double? expMin, expMax;
    if (math.range != null) {
      expMin = math.range!.minGrams;
      expMax = math.range!.maxGrams;
    } else if (eval != null) {
      expMin = eval.expectedGrams - eval.toleranceGrams;
      expMax = eval.expectedGrams + eval.toleranceGrams;
    }

    unawaited(ref.read(weighEventQueueProvider.notifier).sendOrQueue({
      'branchId': 0,
      'foodicsOrderId': widget.orderId,
      'orderLabel': order?.displayTitle,
      'expectedMinG': expMin,
      'expectedMaxG': expMax,
      'measuredG': grams,
      'verdict': verdict,
      'overrideReason': reason,
      'itemMissing': null,
      'weighedAt': DateTime.now().toUtc().toIso8601String(),
      'items': order == null ? null : _weighedItemsPayload(order),
      // Exactly which item(s)/modifier(s) this order couldn't be weight-checked
      // against — the same messages already shown on this screen's own
      // warning banner (see findUnconfiguredWeightMessages). Sent only when
      // the order actually IS unconfigured, so head office can say precisely
      // "Chilli Lime for Fillaa on Toast Duo Combo isn't weighed yet" instead
      // of just an unexplained "unconfigured" verdict.
      'unconfiguredReasons':
          math.unconfiguredItems.isEmpty ? null : math.unconfiguredItems,
    }));
  }

  /// The order's item/modifier composition, in the shape the export/ML
  /// pipeline expects — one entry per line, each with the menu item's id +
  /// name and every selected modifier's id + name. Never throws: an unknown
  /// menu item (a stale/removed one) still contributes its id, just with a
  /// null name, so a data quirk here never blocks the weigh-event report.
  List<Map<String, dynamic>> _weighedItemsPayload(Order order) {
    final menuIndex = ref.read(menuIndexProvider);
    return [
      for (final line in order.items)
        {
          'menuItemId': line.menuItemId,
          'name': menuIndex[line.menuItemId]?.name ?? line.menuItemName,
          'modifiers': [
            for (final modId in line.selectedModifierIds)
              {
                'modifierId': modId,
                'name': menuIndex[line.menuItemId]?.modifierById(modId)?.name ??
                    line.selectedModifierNames[modId],
              },
          ],
        },
    ];
  }

  Order? _findOrder(List<Order>? orders) {
    if (orders == null) return null;
    for (final o in orders) {
      if (o.id == widget.orderId) return o;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(
      ordersProvider.select((async) => _findOrder(async.value)),
    );

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pad = constraints.maxWidth < 500 ? 16.0 : 24.0;
            if (order == null) return _OrderMissing(pad: pad);

            final menuIndex = ref.watch(menuIndexProvider);
            final combinationIndex = ref.watch(modifierCombinationIndexProvider);
            final tolerance = ref.watch(settingsProvider).tolerance;
            final reading = ref.watch(scaleReadingProvider);
            final rawGrams = ref.watch(scaleGramsProvider);
            final source = ref.watch(weightSourceProvider);

            // The just-captured bag has been lifted off once the platter
            // reads empty again — safe to arm the next bag's settle logic.
            if (_awaitingBagRemoval && rawGrams == null) {
              _awaitingBagRemoval = false;
            }
            final grams = _effectiveGrams(rawGrams);
            final serialNoReading = source is SerialWeightSource && reading == null;

            final math = computeOrderMath(ref, order, measuredGrams: grams);
            ref.watch(discrepancyEngineProvider);
            final discrepancy = analyzeDiscrepancy(ref, order, grams);
            final isWide = constraints.maxWidth > 720;

            _armAutoFlow(
              math: math,
              reading: reading,
              serialNoReading: serialNoReading,
              order: order,
            );

            final range = math.range;
            final double lo, hi, ideal;
            if (range != null) {
              lo = range.minGrams;
              hi = range.maxGrams;
              ideal = range.idealGrams;
            } else {
              final window = tolerance.toleranceGrams(
                expectedGrams: math.expected.grams,
                combinedStdDev: math.expected.combinedStdDev,
              );
              ideal = math.expected.grams;
              lo = ideal - window;
              hi = ideal + window;
            }

            final receipt = _ReceiptCard(
              order: order,
              menuIndex: menuIndex,
              combinationIndex: combinationIndex,
              gaugeLo: lo,
              gaugeHi: hi,
              gaugeIdeal: ideal,
              measuredGrams: grams,
              weightsConfigured: math.isFullyConfigured,
              onReweigh: _reweigh,
              capturedBags: List<double>.unmodifiable(_capturedBags),
              awaitingBagRemoval: _awaitingBagRemoval,
              canCaptureBag: !_awaitingBagRemoval &&
                  rawGrams != null &&
                  (reading?.stable ?? false),
              onCaptureBag: () => _captureBag(rawGrams, reading?.stable ?? false),
              onUndoBag: _capturedBags.isEmpty ? null : _undoLastBag,
            );

            final status = _StatusCard(
              order: order,
              math: math,
              discrepancy: discrepancy,
              reading: reading,
              hasBag: grams != null,
              measuredGrams: grams,
              idealGrams: ideal,
              expectedLo: lo,
              expectedHi: hi,
              serialNoReading: serialNoReading,
              selectedReason: _selectedReason,
              unconfiguredItems: math.unconfiguredItems,
              settledStatus: _settledStatus,
              showManualOverride: _showManualOverride,
              onReasonSelected: (r) => setState(() => _selectedReason = r),
              onReweigh: _reweigh,
              onDispatch: () => _completeDispatch(math, grams,
                  (math.evaluation?.status.isOffWeight ?? false) ? _selectedReason : null),
              onForceDispatch: () => _forceDispatch(math, grams),
              onToggleManualOverride: () =>
                  setState(() => _showManualOverride = !_showManualOverride),
              onClose: () => Navigator.of(context).pop(),
            );

            final body = isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: receipt),
                      const SizedBox(width: 20),
                      Expanded(flex: 6, child: status),
                    ],
                  )
                : Column(
                    children: [
                      receipt,
                      const SizedBox(height: 18),
                      status,
                    ],
                  );

            return Stack(
              children: [
                ThemedScrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: EdgeInsets.fromLTRB(pad, pad, pad, 96),
                    child: body,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 18,
                  child: Center(
                    child: SafeArea(top: false, child: const ScalePill()),
                  ),
                ),
                if (_flashSuccess)
                  Positioned.fill(child: _SuccessFlash(order: order)),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Left: the receipt (cream "paper" with a torn zig-zag top edge).
// ---------------------------------------------------------------------------

class _ReceiptCard extends StatelessWidget {
  final Order order;
  final Map<String, MenuItem> menuIndex;
  final ModifierCombinationIndex combinationIndex;
  final double gaugeLo;
  final double gaugeHi;
  final double gaugeIdeal;
  final double? measuredGrams;
  final bool weightsConfigured;
  final VoidCallback onReweigh;

  /// Each bag's own captured weight so far, oldest first (e.g. [320, 410]) —
  /// empty for a plain single-bag order.
  final List<double> capturedBags;

  /// True right after "More Bags" is tapped, until the just-captured bag is
  /// physically lifted off the scale — the button shows a "remove it first"
  /// prompt instead of accepting another tap in the meantime.
  final bool awaitingBagRemoval;

  /// Whether there's a stable bag on the scale right now worth capturing.
  final bool canCaptureBag;
  final VoidCallback onCaptureBag;
  final VoidCallback? onUndoBag;

  const _ReceiptCard({
    required this.order,
    required this.menuIndex,
    required this.combinationIndex,
    required this.gaugeLo,
    required this.gaugeHi,
    required this.gaugeIdeal,
    required this.measuredGrams,
    required this.weightsConfigured,
    required this.onReweigh,
    required this.capturedBags,
    required this.awaitingBagRemoval,
    required this.canCaptureBag,
    required this.onCaptureBag,
    required this.onUndoBag,
  });

  @override
  Widget build(BuildContext context) {
    double packaging = 0;
    final lines = <Widget>[];
    for (var i = 0; i < order.items.length; i++) {
      final line = order.items[i];
      final item = menuIndex[line.menuItemId];
      if (item == null) {
        // Not yet in the locally-synced menu (e.g. added in Foodics but the
        // catalog sync hasn't reached head office yet). Still show the line
        // — using the name Foodics' own order reported — rather than
        // silently dropping it, which would make the receipt undercount
        // against the order's own "N items" stat above.
        lines.add(_unresolvedItemLine(line));
      } else {
        packaging += item.packagingWeightGrams;
        lines.add(_itemLine(item, line));
      }
      if (i != order.items.length - 1) lines.add(const _DashedLine());
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(order.displayTitle,
                          style: AppTextStyles.display(size: 22)),
                      KitchenStagePill(stage: order.kitchenStage),
                    ],
                  ),
                  if (order.displaySubtitle != null)
                    Text(order.displaySubtitle!,
                        style: AppTextStyles.body(
                            size: 13.5, color: AppColors.muted)),
                ],
              ),
            ),
            if (order.displayCheck != null) ...[
              const SizedBox(width: 10),
              Text(order.displayCheck!,
                  style: AppTextStyles.mono(size: 13, color: AppColors.muted)),
            ],
          ],
        ),
        if (order.receivedAt != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.schedule, size: 14, color: AppColors.muted),
              const SizedBox(width: 5),
              Flexible(
                child: Text('Received ${formatReceivedAt(order.receivedAt!)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body(
                        size: 12.5,
                        weight: FontWeight.w600,
                        color: AppColors.muted)),
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            _StatCell(icon: Icons.lunch_dining, label: '${order.itemCount} items'),
            _StatCell(
                icon: Icons.timer_outlined,
                label: 'Ready ${order.readyInMinutes}m'),
            _StatCell(
                icon: Icons.two_wheeler,
                label: 'Dasher ${order.dasherInMinutes}m'),
          ],
        ),
        const SizedBox(height: 18),
        if (weightsConfigured)
          WeightGauge(
            loGrams: gaugeLo,
            hiGrams: gaugeHi,
            idealGrams: gaugeIdeal,
            measuredGrams: measuredGrams,
          )
        else
          _InlineNotice(
            icon: Icons.scale_outlined,
            text: 'Weight check unavailable — some items have no weight set.',
          ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: PillButton(
                label: 'Re-Weigh',
                icon: Icons.refresh,
                variant: PillButtonVariant.outline,
                padding: const EdgeInsets.symmetric(vertical: 13),
                onPressed: onReweigh,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PillButton(
                label: awaitingBagRemoval ? 'Remove bag, then next' : 'More Bags',
                icon: awaitingBagRemoval
                    ? Icons.hourglass_bottom
                    : Icons.add_shopping_cart,
                variant: PillButtonVariant.outline,
                padding: const EdgeInsets.symmetric(vertical: 13),
                onPressed: canCaptureBag ? onCaptureBag : null,
              ),
            ),
          ],
        ),
        if (capturedBags.isNotEmpty) ...[
          const SizedBox(height: 12),
          _CapturedBagsSummary(bags: capturedBags, onUndoLast: onUndoBag),
        ],
        const SizedBox(height: 16),
        const _DashedLine(),
        ...lines,
        const _DashedLine(),
        _weightRow('Bag and extras', packaging, subtitle: 'Packaging weight'),
      ],
    );

    return PhysicalShape(
      clipper: _ReceiptClipper(),
      color: AppColors.cream,
      elevation: 2.5,
      shadowColor: AppColors.ink.withValues(alpha: 0.25),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 32, 22, 22),
        child: content,
      ),
    );
  }

  Widget _itemLine(MenuItem item, OrderItem line) {
    // The headline beside the item name is the item's OWN weight, not a
    // running total with its modifiers — each modifier already shows its own
    // weight on its own line below, and the order's combined expected total
    // is shown once, prominently, in the MEASURED/EXPECTED panel. Showing a
    // silently-summed figure here instead would print one number that looks
    // like "the item" but is actually item+modifiers, with no way to tell
    // them apart.
    //
    // Each modifier's own line shows what it ACTUALLY contributes to that
    // total — which is a combination override when one applies (e.g. "French
    // Fries (MEDIUM) 147g", not its unrelated standalone 200g default),
    // exactly what resolveSelectedModifiers feeds the expected-weight
    // calculation itself. A modifier that only ever makes sense combined with
    // others (a combo-size choice with no weight of its own) still gets its
    // own row, with "—", never silently dropped just because it produced no
    // slot.
    final slots = resolveSelectedModifiers(item, line.selectedModifierIds, combinationIndex);
    final slotByOwnId = <String, ResolvedModifierSlot>{
      for (final s in slots)
        if (s.ids.length == 1) s.ids.first: s,
    };
    // A symmetric (non-anchored) combination can fuse 2-4 modifiers into one
    // slot — render that as ONE row, at the position of whichever member was
    // selected first, and skip its other members entirely rather than also
    // printing them as separate (misleadingly redundant) rows.
    final multiSlotByFirstId = <String, ResolvedModifierSlot>{};
    final coveredByMultiSlot = <String>{};
    for (final s in slots) {
      if (s.ids.length <= 1) continue;
      multiSlotByFirstId[s.ids.first] = s;
      coveredByMultiSlot.addAll(s.ids.skip(1));
    }

    final mods = <Widget>[];
    for (final modId in line.selectedModifierIds) {
      if (coveredByMultiSlot.contains(modId)) continue;
      final slot = multiSlotByFirstId[modId] ?? slotByOwnId[modId];
      if (slot != null) {
        mods.add(_modLine(slot.label, slot.weightG));
      } else {
        mods.add(_modLine(
          item.modifierById(modId)?.name ??
              line.selectedModifierNames[modId] ??
              'Option',
          null,
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _weightRow(
            '1 × ${item.name}',
            item.isWeightConfigured ? item.baseWeightGrams : null,
            bold: true,
          ),
          ...mods,
        ],
      ),
    );
  }

  /// A line for an item whose id doesn't resolve in the synced menu — shown
  /// with whatever name Foodics' own order line reported (falling back to
  /// "Unknown item" only if even that is missing) so the receipt's item
  /// count always matches the order's own "N items" stat, and staff can see
  /// exactly which item to go configure instead of a silently missing row.
  Widget _unresolvedItemLine(OrderItem line) {
    final mods = <Widget>[
      for (final modId in line.selectedModifierIds)
        _modLine(line.selectedModifierNames[modId] ?? 'Option', null),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _weightRow('1 × ${line.menuItemName ?? 'Unknown item'}', null,
              bold: true),
          ...mods,
        ],
      ),
    );
  }

  /// One sub-line under an item: a name and its own weight (or "—" when it
  /// isn't weighed yet). Used for each of the item's selected modifiers.
  Widget _modLine(String name, double? grams) {
    final weighed = grams != null;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          const Text('• ', style: TextStyle(color: AppColors.muted, height: 1)),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body(size: 13, color: AppColors.muted)),
          ),
          const SizedBox(width: 8),
          Text(
            weighed ? formatGrams(grams) : '—',
            style: AppTextStyles.mono(
              size: 11.5,
              weight: FontWeight.w600,
              color: weighed ? AppColors.muted : AppColors.underText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _weightRow(String label, double? grams,
      {bool bold = false, String? subtitle}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: AppTextStyles.body(
                      size: 15.5,
                      weight: bold ? FontWeight.w700 : FontWeight.w600)),
              if (subtitle != null)
                Text(subtitle,
                    style: AppTextStyles.body(size: 12.5, color: AppColors.muted)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(
          grams != null ? formatGrams(grams) : 'not weighed',
          style: AppTextStyles.mono(
            size: 15.5,
            weight: FontWeight.w700,
            color: grams != null ? AppColors.ink : AppColors.underText,
          ),
        ),
      ],
    );
  }
}

/// The running total across bags weighed one at a time — "Bag 1: 320g ·
/// Bag 2: 410g" plus a bold combined total, with an undo for a mis-tap.
class _CapturedBagsSummary extends StatelessWidget {
  final List<double> bags;
  final VoidCallback? onUndoLast;
  const _CapturedBagsSummary({required this.bags, required this.onUndoLast});

  @override
  Widget build(BuildContext context) {
    final total = bags.fold(0.0, (a, b) => a + b);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.page,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line, width: AppShapes.borderWidth),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (var i = 0; i < bags.length; i++)
                  Text('Bag ${i + 1}: ${formatGrams(bags[i])}',
                      style: AppTextStyles.mono(size: 12.5, color: AppColors.muted)),
                Text('· Total ${formatGrams(total)}',
                    style: AppTextStyles.mono(
                        size: 12.5, weight: FontWeight.w700, color: AppColors.ink)),
              ],
            ),
          ),
          if (onUndoLast != null)
            IconButton(
              onPressed: onUndoLast,
              icon: const Icon(Icons.undo, size: 18),
              tooltip: 'Undo last bag',
              splashRadius: 18,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

/// Clips the receipt with a torn zig-zag along the top edge.
class _ReceiptClipper extends CustomClipper<Path> {
  static const double tooth = 9;
  static const double toothW = 15;

  @override
  Path getClip(Size size) {
    final p = Path()..moveTo(0, tooth);
    double x = 0;
    bool peak = true;
    while (x < size.width) {
      final nx = (x + toothW).clamp(0.0, size.width);
      p.lineTo(nx, peak ? 0 : tooth);
      x = nx;
      peak = !peak;
    }
    p.lineTo(size.width, size.height);
    p.lineTo(0, size.height);
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _StatCell extends StatelessWidget {
  final IconData icon;
  final String label;
  const _StatCell({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 20, color: AppColors.muted),
          const SizedBox(height: 5),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body(
                  size: 12.5, weight: FontWeight.w600, color: AppColors.muted)),
        ],
      ),
    );
  }
}

class _DashedLine extends StatelessWidget {
  const _DashedLine();
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const dashW = 5.0;
        const gap = 4.0;
        final count = (constraints.maxWidth / (dashW + gap)).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(
            count.clamp(1, 999),
            (_) => Container(
                width: dashW,
                height: 1.5,
                color: AppColors.ink.withValues(alpha: 0.18)),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Right: status panel.
// ---------------------------------------------------------------------------

class _StatusCard extends StatelessWidget {
  final Order order;
  final OrderMath math;
  final DiscrepancyResult discrepancy;
  final WeightReading? reading;
  final bool hasBag;
  final double? measuredGrams;
  final double idealGrams;
  final double expectedLo;
  final double expectedHi;
  final bool serialNoReading;
  final String? selectedReason;
  final List<String> unconfiguredItems;

  /// The debounced, confirmed verdict (null until a reading settles) — drives
  /// the giant Force-Dispatch button and the "Likely Missing" callout. Kept
  /// distinct from the live `math.evaluation?.status` so a bag still bouncing
  /// on the platter never flashes either into view.
  final OrderStatus? settledStatus;

  /// True once the worker has tapped through from the Force-Dispatch button
  /// to the manual reason-picker + Confirm & send row instead.
  final bool showManualOverride;
  final ValueChanged<String> onReasonSelected;
  final VoidCallback onReweigh;
  final VoidCallback onDispatch;
  final VoidCallback onForceDispatch;
  final VoidCallback onToggleManualOverride;
  final VoidCallback onClose;

  const _StatusCard({
    required this.order,
    required this.math,
    required this.discrepancy,
    required this.reading,
    required this.hasBag,
    required this.measuredGrams,
    required this.idealGrams,
    required this.expectedLo,
    required this.expectedHi,
    required this.serialNoReading,
    required this.selectedReason,
    required this.unconfiguredItems,
    required this.settledStatus,
    required this.showManualOverride,
    required this.onReasonSelected,
    required this.onReweigh,
    required this.onDispatch,
    required this.onForceDispatch,
    required this.onToggleManualOverride,
    required this.onClose,
  });

  bool get _dispatched => order.status == OrderStatus.dispatched;

  @override
  Widget build(BuildContext context) {
    final eval = math.evaluation;
    final unconfigured = unconfiguredItems.isNotEmpty && !_dispatched;
    final offWeight = eval?.status.isOffWeight ?? false;
    final stable = reading?.stable ?? false;
    final banner = unconfigured ? _unconfiguredBanner : _bannerSpec(eval);

    final canDispatch = _dispatched
        ? false
        : unconfigured
            ? true
            : (hasBag &&
                stable &&
                !serialNoReading &&
                (!offWeight || selectedReason != null));

    return Container(
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppShapes.cardRadius),
        border: Border.all(color: AppColors.line, width: AppShapes.borderWidth),
        boxShadow: AppShapes.softShadow(),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _banner(banner),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (serialNoReading && !unconfigured) ...[
                  const _InlineNotice(
                    icon: Icons.error_outline,
                    text: 'Scale not responding — connect a scale or switch to '
                        'Manual test mode in Settings.',
                    tone: _NoticeTone.bad,
                  ),
                  const SizedBox(height: 18),
                ],
                if (unconfigured)
                  ..._unconfiguredBody()
                else
                  ..._bodyForState(eval, offWeight),
                const SizedBox(height: 20),
                const _DashedLine(),
                const SizedBox(height: 16),
                _actions(canDispatch),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _bodyForState(WeightEvaluation? eval, bool offWeight) {
    if (_dispatched) {
      return [
        const _BigGlyph(
            icon: Icons.check_circle, tint: AppColors.okGreenText),
        const SizedBox(height: 12),
        Center(
          child: Text('Ready for pickup',
              style: AppTextStyles.display(size: 18)),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            order.overrideReason == null
                ? 'Weighed and confirmed.'
                : 'Confirmed · ${order.overrideReason}',
            textAlign: TextAlign.center,
            style: AppTextStyles.body(size: 14, color: AppColors.muted),
          ),
        ),
      ];
    }

    if (eval == null) {
      return [
        const _BigGlyph(icon: Icons.scale, tint: AppColors.green),
        const SizedBox(height: 12),
        Center(
          child: Text('Place the bag on the scale',
              style: AppTextStyles.display(size: 18)),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text('The check runs automatically once a bag is on the scale.',
              textAlign: TextAlign.center,
              style: AppTextStyles.body(size: 14, color: AppColors.muted)),
        ),
      ];
    }

    // There is a reading — always show measured vs expected.
    final widgets = <Widget>[
      _MeasuredExpected(
        measured: measuredGrams,
        ideal: idealGrams,
        lo: expectedLo,
        hi: expectedHi,
        status: eval.status,
      ),
    ];

    if (eval.status == OrderStatus.onWeight) {
      widgets.addAll([
        const SizedBox(height: 20),
        const _BigGlyph(
            icon: Icons.thumb_up_alt_rounded, tint: AppColors.okGreenText),
        const SizedBox(height: 10),
        Center(
          child: Text('Everything checks out',
              style: AppTextStyles.body(size: 15, weight: FontWeight.w700)),
        ),
      ]);
    } else {
      final under = eval.status == OrderStatus.under;
      final settled = settledStatus == eval.status;
      final topMissing = discrepancy.top;
      final showLikelyMissing =
          under && settled && (topMissing?.kind.isMissing ?? false);

      widgets.addAll([
        const SizedBox(height: 18),
        if (showLikelyMissing) ...[
          _LikelyMissingCallout(prediction: topMissing!),
          const SizedBox(height: 16),
        ],
        Text(under ? 'Why is the order lighter?' : 'Why is the order heavier?',
            style: AppTextStyles.body(size: 15, weight: FontWeight.w700)),
        const SizedBox(height: 12),
        _reasonPicker(eval, suggestedTag: discrepancy.top?.suggestedReasonTag),
        if (discrepancy.hasPredictions) ...[
          const SizedBox(height: 16),
          _AiInsightCard(result: discrepancy),
        ],
      ]);
    }
    return widgets;
  }

  Widget _banner(_BannerSpec spec) {
    return Container(
      color: spec.bg,
      padding: const EdgeInsets.fromLTRB(18, 16, 10, 16),
      child: Row(
        children: [
          Icon(spec.icon, size: 24, color: spec.fg),
          const SizedBox(width: 12),
          Expanded(
            child: Text(spec.title,
                style: AppTextStyles.body(
                    size: 16.5, weight: FontWeight.w700, color: spec.fg)),
          ),
          IconButton(
            onPressed: onClose,
            icon: Icon(Icons.close, color: spec.fg),
            tooltip: 'Close',
            splashRadius: 22,
          ),
        ],
      ),
    );
  }

  static const _BannerSpec _unconfiguredBanner = _BannerSpec(
    bg: AppColors.yellow,
    fg: AppColors.ink,
    icon: Icons.info_outline,
    title: 'Weight not configured',
  );

  _BannerSpec _bannerSpec(WeightEvaluation? eval) {
    if (_dispatched) {
      return const _BannerSpec(
        bg: AppColors.okGreenBg,
        fg: AppColors.okGreenText,
        icon: Icons.check_circle,
        title: 'Ready for pickup',
      );
    }
    if (eval == null) {
      return const _BannerSpec(
        bg: AppColors.white,
        fg: AppColors.ink,
        icon: Icons.scale,
        title: 'Waiting for a weight',
      );
    }
    switch (eval.status) {
      case OrderStatus.onWeight:
        return const _BannerSpec(
          bg: AppColors.okGreenBg,
          fg: AppColors.okGreenText,
          icon: Icons.check_circle,
          title: 'Order is at expected weight',
        );
      case OrderStatus.under:
        // Red — a missing item is a hard stop, distinct from a merely
        // heavier bag (see the "over" case below), per the brand's own
        // status-color spec (coral = under-weight).
        return const _BannerSpec(
          bg: AppColors.coral,
          fg: AppColors.white,
          icon: Icons.arrow_downward_rounded,
          title: 'The order is lighter than expected',
        );
      case OrderStatus.over:
        // Amber/orange — a heavier bag is usually a quick portion slip, not
        // a hard stop (see the Force-Dispatch action below).
        return const _BannerSpec(
          bg: AppColors.amber,
          fg: AppColors.ink,
          icon: Icons.arrow_upward_rounded,
          title: 'The order is heavier than expected',
        );
      case OrderStatus.pending:
      case OrderStatus.dispatched:
        return const _BannerSpec(
          bg: AppColors.white,
          fg: AppColors.ink,
          icon: Icons.scale,
          title: 'Waiting for a weight',
        );
    }
  }

  List<Widget> _unconfiguredBody() {
    return [
      const _BigGlyph(icon: Icons.scale_outlined, tint: AppColors.ink),
      const SizedBox(height: 12),
      Center(
        child: Text("This order can't be weight-checked",
            textAlign: TextAlign.center,
            style: AppTextStyles.display(size: 18)),
      ),
      const SizedBox(height: 8),
      Text("These items don't have a weight set yet:",
          style: AppTextStyles.body(size: 14, color: AppColors.muted)),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final name in unconfiguredItems)
            NeoChip(label: name, accent: AppColors.underText),
        ],
      ),
      const SizedBox(height: 12),
      const _InlineNotice(
        icon: Icons.info_outline,
        text: 'Set their weights in the head-office portal. You can still send '
            'this order after checking it manually.',
        tone: _NoticeTone.warn,
      ),
    ];
  }

  Widget _reasonPicker(WeightEvaluation eval, {String? suggestedTag}) {
    final reasons =
        eval.status == OrderStatus.under ? _underReasons : _overReasons;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final r in reasons)
          NeoChip(
            label: r == suggestedTag ? '★ $r' : r,
            selected: selectedReason == r,
            onTap: () => onReasonSelected(r),
          ),
      ],
    );
  }

  Widget _actions(bool canDispatch) {
    if (_dispatched) return const SizedBox.shrink();

    // Settled overweight: the giant one-tap Force-Dispatch action replaces
    // the normal row entirely — "instead of making them tap an Error button
    // and fill out a form". A small link underneath still reaches the
    // ordinary reason-picker for a worker who wants to log something specific.
    if (settledStatus == OrderStatus.over && !showManualOverride) {
      final variance = math.evaluation?.deltaGrams ?? 0;
      return Column(
        children: [
          _ForceDispatchButton(varianceGrams: variance, onTap: onForceDispatch),
          const SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: onToggleManualOverride,
              child: Text('Pick a specific reason instead',
                  style: AppTextStyles.body(
                      size: 13, weight: FontWeight.w600, color: AppColors.muted)),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (settledStatus == OrderStatus.over) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onToggleManualOverride,
              icon: const Icon(Icons.bolt, size: 16),
              label: const Text('Back to quick Force Dispatch'),
            ),
          ),
          const SizedBox(height: 4),
        ],
        Row(
          children: [
            Expanded(
              child: PillButton(
                label: 'Re-Weigh Order',
                variant: PillButtonVariant.outline,
                onPressed: onReweigh,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PillButton(
                label: 'Confirm & send',
                icon: Icons.check,
                onPressed: canDispatch ? onDispatch : null,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The giant one-tap "quick accept" action for a settled-overweight bag —
/// "the entire screen or a massive bottom bar transforms into a giant Force
/// Dispatch button". No reason picker: the variance itself is the record.
class _ForceDispatchButton extends StatelessWidget {
  final double varianceGrams;
  final VoidCallback onTap;
  const _ForceDispatchButton({required this.varianceGrams, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            color: AppColors.amber,
            borderRadius: BorderRadius.circular(AppShapes.pillRadius),
            border: Border.all(color: AppColors.ink, width: AppShapes.borderWidth),
            boxShadow: AppShapes.softShadow(),
          ),
          child: Column(
            children: [
              const Icon(Icons.bolt, size: 28, color: AppColors.ink),
              const SizedBox(height: 4),
              Text('Force Dispatch',
                  style: AppTextStyles.display(size: 18, color: AppColors.ink)),
              const SizedBox(height: 2),
              Text('+${varianceGrams.round()}g overweight — tap to send anyway',
                  style: AppTextStyles.body(
                      size: 13, weight: FontWeight.w600, color: AppColors.ink)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A blinking highlight naming the AI's best guess at the missing component —
/// "Likely Missing: Large Fries (-115g)" — only shown once a reading has
/// actually settled under-weight, so it never flickers into view mid-placement.
class _LikelyMissingCallout extends StatefulWidget {
  final Prediction prediction;
  const _LikelyMissingCallout({required this.prediction});

  @override
  State<_LikelyMissingCallout> createState() => _LikelyMissingCalloutState();
}

class _LikelyMissingCalloutState extends State<_LikelyMissingCallout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Color.lerp(AppColors.underBg, AppColors.coral, t * 0.35),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.coral,
              width: AppShapes.borderWidth + t,
            ),
          ),
          child: child,
        );
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.south, size: 22, color: AppColors.underText),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LIKELY MISSING',
                    style: AppTextStyles.mono(
                        size: 11,
                        weight: FontWeight.w700,
                        color: AppColors.underText,
                        letterSpacing: 1)),
                const SizedBox(height: 2),
                Text(widget.prediction.title,
                    style: AppTextStyles.body(
                        size: 16, weight: FontWeight.w700, color: AppColors.underText)),
                Text(widget.prediction.detail,
                    style: AppTextStyles.body(size: 13, color: AppColors.underText)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen green success flash — the "zero-tap" golden path's only
/// feedback before the app auto-returns home. Non-interactive: nothing to
/// tap, it just confirms what already happened and gets out of the way.
class _SuccessFlash extends StatelessWidget {
  final Order order;
  const _SuccessFlash({required this.order});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        builder: (context, t, child) {
          return Container(
            color: AppColors.green,
            alignment: Alignment.center,
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
            ),
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 96, color: AppColors.white),
            const SizedBox(height: 16),
            Text('Dispatched!',
                style: AppTextStyles.display(size: 26, color: AppColors.white)),
            const SizedBox(height: 6),
            Text(order.displayTitle,
                style: AppTextStyles.body(
                    size: 15, weight: FontWeight.w600, color: AppColors.white)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small pieces
// ---------------------------------------------------------------------------

class _MeasuredExpected extends StatelessWidget {
  final double? measured;
  final double ideal;
  final double lo;
  final double hi;
  final OrderStatus status;
  const _MeasuredExpected({
    required this.measured,
    required this.ideal,
    required this.lo,
    required this.hi,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final measuredColor = switch (status) {
      OrderStatus.under => AppColors.coral,
      OrderStatus.over => AppColors.amber,
      _ => AppColors.ink,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _bigStat('Measured',
              measured == null ? '—' : formatGrams(measured!), measuredColor),
        ),
        Expanded(
          child: _bigStat('Expected', formatGrams(ideal), AppColors.ink,
              sub: 'accept ${formatGrams(lo)}–${formatGrams(hi)}'),
        ),
      ],
    );
  }

  Widget _bigStat(String label, String value, Color color, {String? sub}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
            style: AppTextStyles.mono(
                size: 11,
                weight: FontWeight.w700,
                color: AppColors.muted,
                letterSpacing: 1)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value,
              maxLines: 1,
              style: AppTextStyles.mono(
                  size: 32, weight: FontWeight.w700, color: color)),
        ),
        if (sub != null)
          Text(sub, style: AppTextStyles.mono(size: 11.5, color: AppColors.muted)),
      ],
    );
  }
}

class _BigGlyph extends StatelessWidget {
  final IconData icon;
  final Color tint;
  const _BigGlyph({required this.icon, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 42, color: tint),
      ),
    );
  }
}

enum _NoticeTone { warn, bad, neutral }

class _InlineNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  final _NoticeTone tone;
  const _InlineNotice({
    required this.icon,
    required this.text,
    this.tone = _NoticeTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (tone) {
      _NoticeTone.bad => (AppColors.underBg, AppColors.underText),
      _NoticeTone.warn => (AppColors.yellow.withValues(alpha: 0.35), AppColors.ink),
      _NoticeTone.neutral => (AppColors.page, AppColors.ink),
    };
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line, width: AppShapes.borderWidth),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: AppTextStyles.body(
                    size: 13.5, weight: FontWeight.w600, color: fg)),
          ),
        ],
      ),
    );
  }
}

// --- AI weight-check insight (compact, light) ---

class _AiInsightCard extends StatelessWidget {
  final DiscrepancyResult result;
  const _AiInsightCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final preds = result.predictions;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.page,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line, width: AppShapes.borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 17, color: AppColors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text('AI weight-check',
                    style: AppTextStyles.body(size: 14, weight: FontWeight.w700)),
              ),
              if (result.modelVersion != '—')
                Text('model ${result.modelVersion}',
                    style: AppTextStyles.mono(size: 10.5, color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            result.wrongOrderSuspected
                ? 'Heads up — this may be the wrong bag.'
                : 'Most likely reasons for the gap:',
            style: AppTextStyles.body(size: 12.5, color: AppColors.muted),
          ),
          const SizedBox(height: 10),
          if (result.wrongOrderSuspected) ...[
            _mixUpAlert(preds),
            const SizedBox(height: 10),
          ],
          for (final p in preds) _PredictionRow(prediction: p),
        ],
      ),
    );
  }

  Widget _mixUpAlert(List<Prediction> preds) {
    Prediction? wrong;
    for (final p in preds) {
      if (p.kind == PredictionKind.wrongOrder) {
        wrong = p;
        break;
      }
    }
    final label = wrong?.relatedOrderLabel;
    return _InlineNotice(
      icon: Icons.swap_horiz,
      tone: _NoticeTone.bad,
      text: label == null
          ? 'Possible order mix-up — double-check the bag.'
          : 'Possible mix-up: matches $label. Check before sending.',
    );
  }
}

class _PredictionRow extends StatelessWidget {
  final Prediction prediction;
  const _PredictionRow({required this.prediction});

  @override
  Widget build(BuildContext context) {
    final style = _kindStyle(prediction.kind);
    final showBar = prediction.confidence > 0 &&
        prediction.kind != PredictionKind.inconclusive;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.line, width: AppShapes.borderWidth),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration:
                    BoxDecoration(color: style.bg, shape: BoxShape.circle),
                child: Icon(style.icon, size: 15, color: style.fg),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(prediction.title,
                        style: AppTextStyles.body(
                            size: 13.5, weight: FontWeight.w700)),
                    Text(prediction.detail,
                        style: AppTextStyles.body(
                            size: 12, color: AppColors.muted)),
                  ],
                ),
              ),
              if (showBar) ...[
                const SizedBox(width: 8),
                Text('${(prediction.confidence * 100).round()}%',
                    style:
                        AppTextStyles.mono(size: 13.5, weight: FontWeight.w700)),
              ],
            ],
          ),
          if (showBar) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: SizedBox(
                height: 6,
                child: ColoredBox(
                  color: AppColors.ink.withValues(alpha: 0.08),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: prediction.confidence.clamp(0.0, 1.0),
                    child: const ColoredBox(color: AppColors.green),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  _KindStyle _kindStyle(PredictionKind kind) {
    switch (kind) {
      case PredictionKind.missingItem:
      case PredictionKind.missingModifier:
        return const _KindStyle(
            Icons.south, AppColors.underBg, AppColors.underText);
      case PredictionKind.extraItem:
      case PredictionKind.extraModifier:
        return _KindStyle(
            Icons.north, AppColors.amber.withValues(alpha: 0.2), AppColors.ink);
      case PredictionKind.wrongOrder:
        return const _KindStyle(
            Icons.swap_horiz, AppColors.underBg, AppColors.underText);
      case PredictionKind.naturalVariation:
        return const _KindStyle(
            Icons.timelapse, AppColors.okGreenBg, AppColors.okGreenText);
      case PredictionKind.inconclusive:
        return _KindStyle(Icons.help_outline, AppColors.page, AppColors.muted);
    }
  }
}

class _KindStyle {
  final IconData icon;
  final Color bg;
  final Color fg;
  const _KindStyle(this.icon, this.bg, this.fg);
}

class _BannerSpec {
  final Color bg;
  final Color fg;
  final IconData icon;
  final String title;
  const _BannerSpec({
    required this.bg,
    required this.fg,
    required this.icon,
    required this.title,
  });
}

class _OrderMissing extends StatelessWidget {
  final double pad;
  const _OrderMissing({required this.pad});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PillButton(
            label: 'All orders',
            icon: Icons.arrow_back,
            variant: PillButtonVariant.outline,
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Expanded(
            child: Center(child: Text('This order is no longer available.')),
          ),
        ],
      ),
    );
  }
}
