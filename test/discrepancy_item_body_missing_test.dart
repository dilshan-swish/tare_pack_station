import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/ai/discrepancy.dart';
import 'package:tare_pack_station/ai/discrepancy_engine.dart';
import 'package:tare_pack_station/ai/discrepancy_model_config.dart';
import 'package:tare_pack_station/logic/weight_evaluator.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/modifier.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/models/tolerance_settings.dart';

/// Regression test for a real report: an order with ONE line — "Toasts Duo
/// Combo" (579g) + modifiers ORIGINAL(0g)/Regular Fries(0g)/SALT(3g)/
/// Coca-Cola(274g) + a 75g bag, target 931g. The worker left the toasts
/// themselves out of the bag but the drink, the fries seasoning, and the bag
/// stayed — measured 352g, exactly 579g (the item's own body) under target.
///
/// The model had no hypothesis for this at all: "whole item missing" tests
/// removing the item AND every one of its modifiers together (a residual of
/// 277g here — a poor fit, since the drink/salt never left), and "missing
/// modifier" only ever tests one add-on alone (max 274g, nowhere near
/// enough). A canned drink, a sauce cup, a seasoning packet are physically
/// separate objects from the food itself, so "just the food didn't make it
/// into the bag, everything else did" is a real, common failure mode that
/// simply had no matching hypothesis — fixed by adding one that tests each
/// line's own body alone whenever it has modifiers to distinguish it from.
void main() {
  const engine = WeightInferenceEngine(DiscrepancyModelConfig.fallback);
  const tol = ToleranceSettings.defaults;
  const bag = BagPackaging(idealGrams: 75, minGrams: 65, maxGrams: 90);

  const original = Modifier(id: 'mod_original', name: 'ORIGINAL', weightGrams: 0);
  const fries = Modifier(id: 'mod_fries', name: 'Regular Fries', weightGrams: 0);
  const salt = Modifier(id: 'mod_salt', name: 'SALT', weightGrams: 3);
  const cola = Modifier(id: 'mod_cola', name: 'Coca-Cola', weightGrams: 274);
  const combo = MenuItem(
    id: 'mi_toasts_combo',
    name: 'Toasts Duo Combo',
    baseWeightGrams: 579,
    availableModifiers: [original, fries, salt, cola],
  );
  const plainToast = MenuItem(id: 'mi_plain_toast', name: 'Toast', baseWeightGrams: 80);
  final menuIndex = {combo.id: combo, plainToast.id: plainToast};

  final order = Order(
    id: 'order_252',
    orderNumber: 252,
    customerName: 'Test Customer',
    readyInMinutes: 0,
    dasherInMinutes: 0,
    items: const [
      OrderItem(
        menuItemId: 'mi_toasts_combo',
        selectedModifierIds: ['mod_original', 'mod_fries', 'mod_salt', 'mod_cola'],
      ),
    ],
  );

  // Target = 579 + 0 + 0 + 3 + 274 + 75 (bag) = 931g, matching the real
  // report's own "Target 931g" exactly.
  const windowMin = 798.0;
  const windowMax = 965.0;

  test(
      'the food itself missing (add-ons and bag still present) is identified '
      'as "itself", not dismissed for lack of any matching hypothesis', () {
    final r = engine.analyze(
      order: order,
      measuredGrams: 352, // 931 - 579
      menuIndex: menuIndex,
      tolerance: tol,
      bagPackaging: bag,
      windowMinGrams: windowMin,
      windowMaxGrams: windowMax,
    );

    expect(r.deltaGrams, closeTo(-579, 0.01));
    expect(r.hasPredictions, isTrue);
    expect(r.top!.kind, PredictionKind.missingItem);
    expect(r.top!.refId, 'mi_toasts_combo');
    expect(r.top!.title, contains('itself'));
    expect(r.top!.confidence, greaterThan(0.85));
    expect(r.top!.suggestedReasonTag, 'Item left off scale');
  });

  test(
      'the whole line missing (add-ons gone too) still wins as the plain '
      '"Missing: <item>" hypothesis, not the new "itself" one', () {
    final r = engine.analyze(
      order: order,
      measuredGrams: 75, // only the bag remains
      menuIndex: menuIndex,
      tolerance: tol,
      bagPackaging: bag,
      windowMinGrams: windowMin,
      windowMaxGrams: windowMax,
    );

    expect(r.top!.kind, PredictionKind.missingItem);
    expect(r.top!.refId, 'mi_toasts_combo');
    expect(r.top!.title, isNot(contains('itself')));
    expect(r.top!.title, contains('Toasts Duo Combo'));
  });

  test('a single missing add-on (the food and bag both present) still wins '
      'as a modifier hypothesis, unaffected by the new one', () {
    final r = engine.analyze(
      order: order,
      measuredGrams: 657, // 931 - 274 (no Coca-Cola)
      menuIndex: menuIndex,
      tolerance: tol,
      bagPackaging: bag,
      windowMinGrams: windowMin,
      windowMaxGrams: windowMax,
    );

    expect(r.top!.kind, PredictionKind.missingModifier);
    expect(r.top!.refId, 'mod_cola');
    expect(r.top!.confidence, greaterThan(0.85));
  });

  test(
      'a line with no modifiers never gets a duplicate "itself" hypothesis '
      'alongside its own whole-item one', () {
    final plainOrder = Order(
      id: 'order_plain',
      customerName: 'Test',
      readyInMinutes: 0,
      dasherInMinutes: 0,
      items: const [OrderItem(menuItemId: 'mi_plain_toast')],
    );
    final r = engine.analyze(
      order: plainOrder,
      measuredGrams: 0, // the only item, entirely missing
      menuIndex: menuIndex,
      tolerance: tol,
    );

    final missingItemHypotheses =
        r.predictions.where((p) => p.kind == PredictionKind.missingItem && p.refId == 'mi_plain_toast');
    expect(missingItemHypotheses.length, 1,
        reason: 'a line with no add-ons is already just its own body — a '
            'second identical hypothesis would only dilute the ranking');
  });
}
