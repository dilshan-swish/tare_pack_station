import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/weight_evaluator.dart';
import '../models/order.dart';
import '../models/order_status.dart';
import '../state/menu_index_provider.dart';
import '../state/orders_controller.dart';
import '../state/settings_controller.dart';
import 'discrepancy.dart';
import 'discrepancy_engine.dart';
import 'discrepancy_model_config.dart';

const _modelAsset = 'assets/models/discrepancy_model.json';
const _metricsAsset = 'assets/models/training_metrics.json';

/// Loads the trained model parameters from the bundled asset. Any failure
/// (missing asset, corrupt JSON) falls back to safe built-in defaults so the
/// feature degrades gracefully rather than breaking the screen.
final discrepancyConfigProvider =
    FutureProvider<DiscrepancyModelConfig>((ref) async {
  try {
    final raw = await rootBundle.loadString(_modelAsset);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return DiscrepancyModelConfig.fromJson(json);
  } catch (e) {
    debugPrint('discrepancyConfig load failed, using fallback: $e');
    return DiscrepancyModelConfig.fallback;
  }
});

/// Loads the saved training metrics for display in Settings. Null if absent.
final trainingMetricsProvider =
    FutureProvider<Map<String, dynamic>?>((ref) async {
  try {
    final raw = await rootBundle.loadString(_metricsAsset);
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (e) {
    debugPrint('trainingMetrics load failed: $e');
    return null;
  }
});

/// The active discrepancy engine. It is usable immediately (built-in defaults)
/// and upgrades to the trained model the moment the asset finishes loading.
/// Behind the [DiscrepancyEngine] interface so a different implementation can
/// be swapped in without touching the UI.
final discrepancyEngineProvider = Provider<DiscrepancyEngine>((ref) {
  final config = ref.watch(discrepancyConfigProvider).value ??
      DiscrepancyModelConfig.fallback;
  return WeightInferenceEngine(config);
});

/// Runs the model for [order] against the shared measured weight. Returns an
/// empty result when there is no reading or the order is on-weight. Wrapped so
/// an unexpected model error can never crash the detail screen.
DiscrepancyResult analyzeDiscrepancy(
  WidgetRef ref,
  Order order,
  double? measuredGrams,
) {
  if (measuredGrams == null) return DiscrepancyResult.none;
  try {
    final engine = ref.read(discrepancyEngineProvider);
    final menuIndex = ref.read(menuIndexProvider);
    final combinationIndex = ref.read(modifierCombinationIndexProvider);
    final tolerance = ref.read(settingsProvider).tolerance;
    // Only orders still sitting in the main queue (i.e. not yet dispatched)
    // are plausible "wrong bag" candidates — a dispatched order's bag is
    // already gone, so it can't be the one that ended up on the scale.
    final others = (ref.read(ordersProvider).value ?? const <Order>[])
        .where((o) => o.status != OrderStatus.dispatched)
        .toList();
    // Use the explicit Min/Max range (BBT standards) when present so the AI's
    // off-weight gate matches the on/under/over verdict shown on the card.
    final range =
        const WeightEvaluator().rangeFor(order, menuIndex, combinationIndex: combinationIndex);
    return engine.analyze(
      order: order,
      measuredGrams: measuredGrams,
      menuIndex: menuIndex,
      tolerance: tolerance,
      otherOrders: others,
      windowMinGrams: range?.minGrams,
      windowMaxGrams: range?.maxGrams,
      combinationIndex: combinationIndex,
    );
  } catch (e) {
    debugPrint('analyzeDiscrepancy failed: $e');
    return DiscrepancyResult.none;
  }
}
