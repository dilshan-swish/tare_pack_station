import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/modifier_pairing.dart';
import '../logic/weight_evaluator.dart';
import '../models/menu_item.dart';
import '../models/order.dart';
import 'menu_index_provider.dart';
import 'settings_controller.dart';
import 'weight_model_controller.dart';

/// Finds every reason [order] cannot be reliably weight-checked yet: an
/// unknown menu item, one with no weight set, or a selected modifier with no
/// weight set. A [LinkedHashSet]-backed dedupe means an identical message
/// (e.g. the same unweighed option repeated across a quantity > 1 line) only
/// appears once, in first-seen order. Empty means the order is fully
/// configured and safe to weigh.
///
/// [combinationIndex] matters here too: a modifier that's only ever meant to be
/// used together with others (e.g. a combo-size choice whose own weight is
/// deliberately left unset because it only makes sense combined with a
/// fries + drink choice — see ModifierCombinationWeight) must not be flagged
/// as unconfigured on its own when its combination partners are also
/// selected and the combination itself has a weight.
Set<String> findUnconfiguredWeightMessages(
  Order order,
  Map<String, MenuItem> menuIndex, {
  ModifierCombinationIndex? combinationIndex,
}) {
  final combinations = combinationIndex ?? ModifierCombinationIndex.empty;
  final unconfigured = <String>{};
  for (final line in order.items) {
    final mi = menuIndex[line.menuItemId];
    if (mi == null) {
      // Not yet in the locally-synced menu — most commonly a product added
      // in Foodics whose catalog sync hasn't reached head office yet. Prefer
      // the name Foodics' own order line reported, so staff see exactly
      // which item is missing rather than an unidentifiable "Unknown item".
      unconfigured.add(line.menuItemName != null
          ? '${line.menuItemName} (not in synced menu yet)'
          : 'Unknown item');
      continue;
    }
    if (!mi.isWeightConfigured) {
      unconfigured.add(mi.name);
      continue;
    }
    for (final modId
        in unresolvedModifierIds(mi, line.selectedModifierIds, combinations)) {
      final mod = mi.modifierById(modId);
      final optionName = mod?.name ?? line.selectedModifierNames[modId];
      unconfigured.add(optionName != null
          ? '${mi.name}: $optionName not weighed yet'
          : '${mi.name} (option not weighed yet)');
    }
  }
  return unconfigured;
}

/// True when [order] has at least one item/modifier with no weight configured
/// yet — used to visually flag a queue card before staff even open it.
bool orderHasUnconfiguredWeight(
  Order order,
  Map<String, MenuItem> menuIndex, {
  ModifierCombinationIndex? combinationIndex,
}) =>
    findUnconfiguredWeightMessages(order, menuIndex, combinationIndex: combinationIndex)
        .isNotEmpty;

/// Shared evaluator instance.
final weightEvaluatorProvider =
    Provider<WeightEvaluator>((ref) => const WeightEvaluator());

/// Expected + (optional) evaluation for an order, using the current menu data
/// and tolerance settings. [evaluation] is null when the order has no measured
/// weight yet.
class OrderMath {
  final ExpectedWeight expected;
  final WeightEvaluation? evaluation;

  /// The explicit Min/Max acceptance range, when the order's items carry one
  /// (BBT standards). Null means the tolerance model is in use.
  final WeightRange? range;

  /// Display names of any order lines whose weight is not configured (or whose
  /// menu item is unknown). When non-empty the order cannot be weight-checked
  /// and the UI shows a warning instead of a computed verdict.
  final List<String> unconfiguredItems;

  const OrderMath({
    required this.expected,
    this.evaluation,
    this.range,
    this.unconfiguredItems = const [],
  });

  /// True when every line has a usable weight, so the check is reliable.
  bool get isFullyConfigured => unconfiguredItems.isEmpty;
}

/// Computes [OrderMath] for [order] against the shared measured weight
/// [measuredGrams] (the weight currently on the scale). When null — an empty
/// scale — no evaluation is produced and the order reads as "waiting".
OrderMath computeOrderMath(
  WidgetRef ref,
  Order order, {
  required double? measuredGrams,
}) {
  final evaluator = ref.read(weightEvaluatorProvider);
  final menuIndex = ref.read(menuIndexProvider);
  final combinationIndex = ref.read(modifierCombinationIndexProvider);
  final tolerance = ref.read(settingsProvider).tolerance;

  // An unweighed item/modifier makes the expected weight unreliable, so the
  // UI warns rather than computing a (wrong) verdict from an incomplete total.
  final unconfigured =
      findUnconfiguredWeightMessages(order, menuIndex, combinationIndex: combinationIndex);

  final statisticalExpected =
      evaluator.expectedFor(order, menuIndex, combinationIndex: combinationIndex);
  // Prefer an explicit measured Min/Max range (e.g. BBT standards) above
  // everything else — a real measured standard beats any formula. The
  // optional ML model (see docs/AI_MODEL_CONTRACT.md) only ever competes with
  // the STATISTICAL fallback below, and only once every item/modifier is
  // actually configured — it's a refinement of the tolerance formula, never
  // a way to paper over genuinely missing weight data.
  final range = evaluator.rangeFor(order, menuIndex, combinationIndex: combinationIndex);

  var expected = statisticalExpected;
  if (range == null && unconfigured.isEmpty) {
    final prediction = ref.read(weightModelProvider.notifier).predict(
        _modelFeatures(order, menuIndex, statisticalExpected, combinationIndex));
    if (prediction != null) {
      expected = ExpectedWeight(
          grams: prediction.grams, combinedStdDev: prediction.stdDevGrams);
    }
  }

  WeightEvaluation? evaluation;
  if (measuredGrams != null) {
    evaluation = range != null
        ? evaluator.evaluateRange(measuredGrams: measuredGrams, range: range)
        : evaluator.evaluate(
            measuredGrams: measuredGrams,
            expected: expected,
            tolerance: tolerance,
          );
  }
  return OrderMath(
    expected: expected,
    evaluation: evaluation,
    range: range,
    unconfiguredItems: unconfigured.toList(),
  );
}

/// Builds the fixed 6-feature vector documented in docs/AI_MODEL_CONTRACT.md
/// — deliberately small and vocabulary-free (no per-item/modifier ids) so the
/// same model shape works for every brand.
List<double> _modelFeatures(
  Order order,
  Map<String, MenuItem> menuIndex,
  ExpectedWeight statisticalExpected,
  ModifierCombinationIndex combinationIndex,
) {
  var itemCount = 0.0;
  var modifierCount = 0.0;
  var sumBaseWeight = 0.0;
  var sumModifierWeight = 0.0;
  var sumPackagingWeight = 0.0;

  for (final line in order.items) {
    final menuItem = menuIndex[line.menuItemId];
    if (menuItem == null) continue;
    itemCount += 1;
    sumBaseWeight += menuItem.baseWeightGrams;
    sumPackagingWeight += menuItem.packagingWeightGrams;
    modifierCount += line.selectedModifierIds.length;
    for (final slot
        in resolveSelectedModifiers(menuItem, line.selectedModifierIds, combinationIndex)) {
      sumModifierWeight += slot.weightG;
    }
  }

  return [
    itemCount,
    modifierCount,
    sumBaseWeight,
    sumModifierWeight,
    sumPackagingWeight,
    statisticalExpected.grams,
  ];
}
