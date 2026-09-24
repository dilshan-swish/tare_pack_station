import 'dart:math' as math;

import '../models/menu_item.dart';
import '../models/order.dart';
import '../models/order_status.dart';
import '../models/tolerance_settings.dart';
import 'modifier_pairing.dart';

/// The expected weight of an order, broken down for display.
class ExpectedWeight {
  /// Total expected grams (items + modifiers + packaging).
  final double grams;

  /// Combined standard deviation across every contributing component.
  final double combinedStdDev;

  const ExpectedWeight({required this.grams, required this.combinedStdDev});
}

/// One bag's worth of packaging (bag material, napkins, sauce cups) — a
/// property of how a brand packs, not of any one menu item (see
/// Brand.BagIdealWeightG on the backend). [WeightEvaluator] multiplies this
/// by however many bags an order actually took, rather than trying to
/// predict bag count from the order's contents. `none` (all fields null)
/// means the brand hasn't configured this yet, in which case both
/// [WeightEvaluator] methods fall back to their pre-existing behavior.
class BagPackaging {
  final double? idealGrams;
  final double? minGrams;
  final double? maxGrams;
  const BagPackaging({this.idealGrams, this.minGrams, this.maxGrams});
  static const none = BagPackaging();
  bool get isConfigured => idealGrams != null;
  bool get hasRange => minGrams != null && maxGrams != null;
}

/// An explicit measured acceptance range for an order (grams), summed from the
/// per-item Min/Max standards. Present only when every line has a range.
class WeightRange {
  final double idealGrams;
  final double minGrams;
  final double maxGrams;
  const WeightRange({
    required this.idealGrams,
    required this.minGrams,
    required this.maxGrams,
  });
}

/// The outcome of comparing a measured weight to the expected weight.
class WeightEvaluation {
  final OrderStatus status;

  /// measured - expected/ideal (negative = under, positive = over).
  final double deltaGrams;

  /// The tolerance window applied (grams). For range mode this is half the
  /// range width, so existing UI that shows a ± window still reads sensibly.
  final double toleranceGrams;

  final double expectedGrams;
  final double measuredGrams;

  /// Set when an explicit Min/Max range drove the verdict (BBT standards).
  final double? rangeMinGrams;
  final double? rangeMaxGrams;

  const WeightEvaluation({
    required this.status,
    required this.deltaGrams,
    required this.toleranceGrams,
    required this.expectedGrams,
    required this.measuredGrams,
    this.rangeMinGrams,
    this.rangeMaxGrams,
  });

  double get absDelta => deltaGrams.abs();

  bool get usesRange => rangeMinGrams != null && rangeMaxGrams != null;
}

/// Pure functions for expected-weight computation and tolerance evaluation.
/// Kept free of Flutter/Riverpod so it is trivially unit-testable.
class WeightEvaluator {
  const WeightEvaluator();

  /// Computes the expected weight for [order] using the menu data in
  /// [menuIndex] (menuItemId -> MenuItem). Unknown ids contribute zero so a
  /// stale order never throws. [combinationIndex] resolves any 2-4 modifiers
  /// that must be weighed together (see ModifierCombinationWeight); defaults
  /// to no overrides, so this is a no-op change for any order that doesn't
  /// use one.
  ExpectedWeight expectedFor(
    Order order,
    Map<String, MenuItem> menuIndex, {
    ModifierCombinationIndex? combinationIndex,
    BagPackaging bagPackaging = BagPackaging.none,
    int bagCount = 1,
  }) {
    final combinations = combinationIndex ?? ModifierCombinationIndex.empty;
    double total = 0;
    // Standard deviations combine in quadrature (independent variances add).
    double variance = 0;
    // Legacy per-item packaging sum — only used as a fallback below, for a
    // brand that hasn't configured a bag range in the portal yet.
    double perItemPackaging = 0;

    for (final line in order.items) {
      final menuItem = menuIndex[line.menuItemId];
      if (menuItem == null) continue;

      total += menuItem.baseWeightGrams;
      perItemPackaging += menuItem.packagingWeightGrams;
      variance += menuItem.baseWeightStdDev * menuItem.baseWeightStdDev;

      for (final slot in [
        ...resolveSelectedModifiers(menuItem, line.selectedModifierIds, combinations),
        // Always-included components (a dip, a slaw) — nobody selects them,
        // so they're never in the line's modifiers, but every order of this
        // item is expected to carry them. See FixedInclusion.
        ...resolveFixedInclusions(menuItem),
      ]) {
        total += slot.weightG;
        variance += slot.weightStdDev * slot.weightStdDev;
      }
    }

    if (bagPackaging.isConfigured) {
      total += bagPackaging.idealGrams! * bagCount;
      if (bagPackaging.hasRange) {
        // A rough stddev from the measured range (~4 sigma spans min..max),
        // scaled by bag count since each captured bag adds its own variance.
        final bagStdDev = (bagPackaging.maxGrams! - bagPackaging.minGrams!) / 4 * bagCount;
        variance += bagStdDev * bagStdDev;
      }
    } else {
      total += perItemPackaging;
    }

    return ExpectedWeight(grams: total, combinedStdDev: math.sqrt(variance));
  }

  /// The summed explicit acceptance range for [order], or null when any line's
  /// menu item lacks a Min/Max range (in which case the tolerance model is
  /// used instead). Ranges add across items and selected modifiers, so a
  /// multi-item order's window is the sum of each item's measured window.
  /// [combinationIndex] resolves any 2-4 modifiers that must be weighed
  /// together — see [expectedFor].
  WeightRange? rangeFor(
    Order order,
    Map<String, MenuItem> menuIndex, {
    ModifierCombinationIndex? combinationIndex,
    BagPackaging bagPackaging = BagPackaging.none,
    int bagCount = 1,
  }) {
    if (order.items.isEmpty) return null;
    final combinations = combinationIndex ?? ModifierCombinationIndex.empty;
    double ideal = 0, min = 0, max = 0;
    for (final line in order.items) {
      final mi = menuIndex[line.menuItemId];
      if (mi == null || !mi.hasRange) return null;
      ideal += mi.baseWeightGrams;
      min += mi.minWeightGrams!;
      max += mi.maxWeightGrams!;
      for (final slot in [
        ...resolveSelectedModifiers(mi, line.selectedModifierIds, combinations),
        ...resolveFixedInclusions(mi),
      ]) {
        ideal += slot.weightG;
        // A slot without its own range (a plain modifier with no measured
        // range, or a combination override that only set a combined weight)
        // contributes a fixed amount to both ends.
        min += slot.hasRange ? slot.minWeightG! : slot.weightG;
        max += slot.hasRange ? slot.maxWeightG! : slot.weightG;
      }
    }
    if (bagPackaging.isConfigured) {
      ideal += bagPackaging.idealGrams! * bagCount;
      if (bagPackaging.hasRange) {
        min += bagPackaging.minGrams! * bagCount;
        max += bagPackaging.maxGrams! * bagCount;
      } else {
        // No measured range for the bag yet — a fixed amount on both ends,
        // same convention as a plain modifier with no range above.
        min += bagPackaging.idealGrams! * bagCount;
        max += bagPackaging.idealGrams! * bagCount;
      }
    }
    return WeightRange(idealGrams: ideal, minGrams: min, maxGrams: max);
  }

  /// Verdict from an explicit Min/Max [range] — on-weight inside the range,
  /// otherwise under/over.
  WeightEvaluation evaluateRange({
    required double measuredGrams,
    required WeightRange range,
  }) {
    final OrderStatus status;
    if (measuredGrams < range.minGrams) {
      status = OrderStatus.under;
    } else if (measuredGrams > range.maxGrams) {
      status = OrderStatus.over;
    } else {
      status = OrderStatus.onWeight;
    }
    return WeightEvaluation(
      status: status,
      deltaGrams: measuredGrams - range.idealGrams,
      toleranceGrams: (range.maxGrams - range.minGrams) / 2,
      expectedGrams: range.idealGrams,
      measuredGrams: measuredGrams,
      rangeMinGrams: range.minGrams,
      rangeMaxGrams: range.maxGrams,
    );
  }

  /// Compares [measuredGrams] against [expected] using [tolerance].
  WeightEvaluation evaluate({
    required double measuredGrams,
    required ExpectedWeight expected,
    required ToleranceSettings tolerance,
  }) {
    final window = tolerance.toleranceGrams(
      expectedGrams: expected.grams,
      combinedStdDev: expected.combinedStdDev,
    );
    final delta = measuredGrams - expected.grams;

    final OrderStatus status;
    if (delta.abs() <= window) {
      status = OrderStatus.onWeight;
    } else if (delta < 0) {
      status = OrderStatus.under;
    } else {
      status = OrderStatus.over;
    }

    return WeightEvaluation(
      status: status,
      deltaGrams: delta,
      toleranceGrams: window,
      expectedGrams: expected.grams,
      measuredGrams: measuredGrams,
    );
  }
}
