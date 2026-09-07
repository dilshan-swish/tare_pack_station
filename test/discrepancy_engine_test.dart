import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/ai/discrepancy.dart';
import 'package:tare_pack_station/ai/discrepancy_engine.dart';
import 'package:tare_pack_station/ai/discrepancy_model_config.dart';
import 'package:tare_pack_station/data/menu_repository.dart';
import 'package:tare_pack_station/logic/modifier_pairing.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/modifier.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/models/tolerance_settings.dart';

void main() {
  final menu = MenuSeed.items();
  final menuIndex = {for (final m in menu) m.id: m};
  const engine = WeightInferenceEngine(DiscrepancyModelConfig.fallback);
  const tol = ToleranceSettings.defaults;

  // Zinger (240+25) + soft drink (420+30) with no modifiers = 715 g.
  Order zingerAndDrink() => const Order(
        id: 'A',
        customerName: 'Test A',
        items: [
          OrderItem(menuItemId: 'mi_zinger'),
          OrderItem(menuItemId: 'mi_soft_drink'),
        ],
        readyInMinutes: 5,
        dasherInMinutes: 5,
      );

  test('on-weight order yields no predictions', () {
    final r = engine.analyze(
      order: zingerAndDrink(),
      measuredGrams: 715,
      menuIndex: menuIndex,
      tolerance: tol,
    );
    expect(r.predictions, isEmpty);
    expect(r.wrongOrderSuspected, isFalse);
  });

  test('missing whole item is identified with the right component', () {
    // Drop the soft drink (450 g) → measured 265 g.
    final r = engine.analyze(
      order: zingerAndDrink(),
      measuredGrams: 265,
      menuIndex: menuIndex,
      tolerance: tol,
    );
    expect(r.hasPredictions, isTrue);
    expect(r.top!.kind, PredictionKind.missingItem);
    expect(r.top!.refId, 'mi_soft_drink');
    expect(r.top!.confidence, greaterThan(0.3));
  });

  test('extra whole item is identified as over', () {
    // Zinger only (265 g) + an extra soft drink (450 g) → 715 g.
    final order = const Order(
      id: 'B',
      customerName: 'Test B',
      items: [OrderItem(menuItemId: 'mi_zinger')],
      readyInMinutes: 5,
      dasherInMinutes: 5,
    );
    final r = engine.analyze(
      order: order,
      measuredGrams: 715,
      menuIndex: menuIndex,
      tolerance: tol,
    );
    expect(r.top!.kind, PredictionKind.extraItem);
    expect(r.top!.refId, 'mi_soft_drink');
  });

  test('a bag matching another queued order flags a mix-up', () {
    final selected = const Order(
      id: 'A',
      customerName: 'Alice',
      items: [OrderItem(menuItemId: 'mi_zinger')], // 265 g
      readyInMinutes: 5,
      dasherInMinutes: 5,
    );
    final other = const Order(
      id: 'Z',
      customerName: 'Zoe',
      items: [OrderItem(menuItemId: 'mi_soft_drink')], // 450 g
      readyInMinutes: 5,
      dasherInMinutes: 5,
    );
    // The bag weighs 450 g — Zoe's order, not Alice's.
    final r = engine.analyze(
      order: selected,
      measuredGrams: 450,
      menuIndex: menuIndex,
      tolerance: tol,
      otherOrders: [selected, other],
    );
    expect(r.wrongOrderSuspected, isTrue);
    expect(r.top!.kind, PredictionKind.wrongOrder);
    expect(r.top!.relatedOrderId, 'Z');
  });

  // Regression test for a real report: the wrong-order suggestion showed the
  // other order's raw internal id (a Foodics UUID, e.g.
  // "#b042368a-12b1-4e94-8566-6109e6f8fb04") instead of a staff-readable
  // reference — the same "never show a raw id to a person" rule already
  // applied to branch ids elsewhere in the app.
  test('a mix-up suggestion never shows the other order\'s raw internal id', () {
    final selected = const Order(
      id: 'A',
      customerName: 'Alice',
      items: [OrderItem(menuItemId: 'mi_zinger')], // 265 g
      readyInMinutes: 5,
      dasherInMinutes: 5,
    );
    // A realistic Foodics-shaped UUID as the internal id, with a friendly
    // order number and an aggregator subtitle — exactly what must be shown
    // instead of the id.
    final other = const Order(
      id: 'b042368a-12b1-4e94-8566-6109e6f8fb04',
      orderNumber: 42,
      customerName: 'Zoe',
      aggregatorName: 'Keeta 2.0',
      aggregatorRef: '3635',
      items: [OrderItem(menuItemId: 'mi_soft_drink')], // 450 g
      readyInMinutes: 5,
      dasherInMinutes: 5,
    );
    final r = engine.analyze(
      order: selected,
      measuredGrams: 450,
      menuIndex: menuIndex,
      tolerance: tol,
      otherOrders: [selected, other],
    );
    final top = r.top!;
    expect(top.kind, PredictionKind.wrongOrder);
    expect(top.title, isNot(contains('b042368a-12b1-4e94-8566-6109e6f8fb04')));
    expect(top.relatedOrderLabel,
        isNot(contains('b042368a-12b1-4e94-8566-6109e6f8fb04')));
    expect(top.title, 'Might be Order 42 · Keeta 2.0 #3635');
    expect(top.relatedOrderLabel, 'Order 42 · Keeta 2.0 #3635');
    // The internal id is still carried (for any future navigation use) — it
    // just must never appear in anything shown to a person.
    expect(top.relatedOrderId, 'b042368a-12b1-4e94-8566-6109e6f8fb04');
  });

  test('unknown menu ids never throw', () {
    final order = const Order(
      id: 'C',
      customerName: 'Test C',
      items: [OrderItem(menuItemId: 'does_not_exist')],
      readyInMinutes: 5,
      dasherInMinutes: 5,
    );
    expect(
      () => engine.analyze(
        order: order,
        measuredGrams: 300,
        menuIndex: menuIndex,
        tolerance: tol,
      ),
      returnsNormally,
    );
  });

  // Regression coverage for a real bug class: 2-4 modifiers that must be
  // weighed TOGETHER (e.g. a combo-size choice affecting BOTH the fries
  // portion AND the drink portion at once — a real 3-way interaction — see
  // ModifierCombinationWeight) must not make the AI's "on weight" baseline
  // wrong by double-counting or ignoring the combination, which would
  // otherwise make it flag a perfectly correct order as having a missing or
  // extra component.
  test('a combination-resolved 3-way order with no real discrepancy is not flagged', () {
    const curlyFries = Modifier(
      id: 'mod_curly_fries', name: 'Curly Fries', weightGrams: 190);
    const sprite = Modifier(id: 'mod_sprite', name: 'Sprite', weightGrams: 330);
    const mediumSize = Modifier(id: 'mod_medium', name: 'MEDIUM', weightGrams: null);
    const wrap = MenuItem(
      id: 'mi_wrap_meal',
      name: 'Hot Little Wrap Fillaaa Meal',
      baseWeightGrams: 201,
      availableModifiers: [curlyFries, sprite, mediumSize],
    );
    final comboMenuIndex = {wrap.id: wrap};
    final combinationIndex = ModifierCombinationIndex([
      ModifierCombinationWeight(
        modifierIds: const ['mod_curly_fries', 'mod_sprite', 'mod_medium'],
        weightG: 410,
      ),
    ]);
    final order = Order(
      id: 'wrap-order',
      customerName: 'Test',
      items: const [
        OrderItem(
            menuItemId: 'mi_wrap_meal',
            selectedModifierIds: ['mod_curly_fries', 'mod_sprite', 'mod_medium']),
      ],
      readyInMinutes: 5,
      dasherInMinutes: 5,
    );
    // True expected weight is 201 + 410 (the 3-way combination) = 611 — NOT
    // 201+190+330+410=1131 — measuring exactly 611 must read as on-weight,
    // not as a phantom "missing"/"extra".
    final r = engine.analyze(
      order: order,
      measuredGrams: 611,
      menuIndex: comboMenuIndex,
      tolerance: tol,
      combinationIndex: combinationIndex,
    );
    expect(r.predictions, isEmpty);
    expect(r.wrongOrderSuspected, isFalse);
  });
}
