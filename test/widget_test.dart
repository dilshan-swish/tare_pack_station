import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/logic/weight_evaluator.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/modifier.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/models/order_status.dart';
import 'package:tare_pack_station/models/tolerance_settings.dart';

void main() {
  const evaluator = WeightEvaluator();

  final menu = <String, MenuItem>{
    'burger': const MenuItem(
      id: 'burger',
      name: 'Burger',
      baseWeightGrams: 200,
      baseWeightStdDev: 6,
      packagingWeightGrams: 20,
      availableModifiers: [
        Modifier(id: 'cheese', name: 'Cheese', weightGrams: 15, weightStdDev: 2),
      ],
    ),
  };

  Order orderWith(List<String> mods) => Order(
        id: 'o1',
        customerName: 'Test',
        items: [OrderItem(menuItemId: 'burger', selectedModifierIds: mods)],
        readyInMinutes: 5,
        dasherInMinutes: 5,
      );

  group('expectedFor', () {
    test('sums base + packaging + modifiers', () {
      final e = evaluator.expectedFor(orderWith(['cheese']), menu);
      expect(e.grams, 235); // 200 + 20 + 15
    });

    test('combines std devs in quadrature', () {
      final e = evaluator.expectedFor(orderWith(['cheese']), menu);
      // sqrt(6^2 + 2^2) = sqrt(40)
      expect(e.combinedStdDev, closeTo(6.324, 0.01));
    });

    test('ignores unknown modifier ids without throwing', () {
      final e = evaluator.expectedFor(orderWith(['ghost']), menu);
      expect(e.grams, 220);
    });
  });

  group('evaluate', () {
    final expected = evaluator.expectedFor(orderWith(['cheese']), menu);

    test('on weight when within tolerance window', () {
      final r = evaluator.evaluate(
        measuredGrams: 235,
        expected: expected,
        tolerance: ToleranceSettings.defaults,
      );
      expect(r.status, OrderStatus.onWeight);
      expect(r.deltaGrams, 0);
    });

    test('under when below tolerance', () {
      final r = evaluator.evaluate(
        measuredGrams: 200,
        expected: expected,
        tolerance: ToleranceSettings.defaults,
      );
      expect(r.status, OrderStatus.under);
      expect(r.deltaGrams, lessThan(0));
    });

    test('over when above tolerance', () {
      final r = evaluator.evaluate(
        measuredGrams: 280,
        expected: expected,
        tolerance: ToleranceSettings.defaults,
      );
      expect(r.status, OrderStatus.over);
      expect(r.deltaGrams, greaterThan(0));
    });
  });

  group('negative-weight modifiers (e.g. "No Onion", "No Cheese")', () {
    // A "removal" modifier represents weight taken OFF the base item, not
    // added — its configured weight is negative, and must simply subtract
    // via normal signed addition, not be clamped, filtered, or treated as
    // "unconfigured" for being negative.
    final menuWithRemoval = <String, MenuItem>{
      'burger': const MenuItem(
        id: 'burger',
        name: 'Burger',
        baseWeightGrams: 200,
        baseWeightStdDev: 6,
        packagingWeightGrams: 20,
        availableModifiers: [
          Modifier(id: 'cheese', name: 'Cheese', weightGrams: 15, weightStdDev: 2),
          Modifier(id: 'no_onion', name: 'No Onion', weightGrams: -12),
        ],
      ),
    };

    Order orderWithMods(List<String> mods) => Order(
          id: 'o2',
          customerName: 'Test',
          items: [OrderItem(menuItemId: 'burger', selectedModifierIds: mods)],
          readyInMinutes: 5,
          dasherInMinutes: 5,
        );

    test('expectedFor subtracts a negative modifier weight', () {
      final e = evaluator.expectedFor(
          orderWithMods(['no_onion']), menuWithRemoval);
      expect(e.grams, 208); // 200 + 20 - 12
    });

    test('expectedFor combines a positive and a negative modifier correctly',
        () {
      final e = evaluator.expectedFor(
          orderWithMods(['cheese', 'no_onion']), menuWithRemoval);
      expect(e.grams, 223); // 200 + 20 + 15 - 12
    });

    test('rangeFor shifts both min and max down by the removed weight', () {
      const withRange = MenuItem(
        id: 'burger2',
        name: 'Burger',
        baseWeightGrams: 220,
        minWeightGrams: 210,
        maxWeightGrams: 230,
        availableModifiers: [
          Modifier(id: 'no_onion', name: 'No Onion', weightGrams: -12),
        ],
      );
      final menu = {'burger2': withRange};
      final order = Order(
        id: 'o3',
        customerName: 'Test',
        items: [
          const OrderItem(menuItemId: 'burger2', selectedModifierIds: ['no_onion'])
        ],
        readyInMinutes: 5,
        dasherInMinutes: 5,
      );
      final range = evaluator.rangeFor(order, menu);
      expect(range, isNotNull);
      expect(range!.idealGrams, 208); // 220 - 12
      expect(range.minGrams, 198); // 210 - 12
      expect(range.maxGrams, 218); // 230 - 12
    });

    test('a negative-weight modifier is never treated as "extra" weight', () {
      final e = evaluator.expectedFor(
          orderWithMods(['no_onion']), menuWithRemoval);
      expect(e.grams, lessThan(220)); // strictly lighter than base+packaging
    });
  });

  group('linked-but-unweighed modifiers (e.g. a new "Sprite" not weighed yet)',
      () {
    // A modifier can be genuinely linked to an item (so it's worth showing
    // in the UI) without having a weight configured yet. That must never
    // contribute 0g to the math — it has to behave exactly like the
    // modifier being entirely absent from availableModifiers.
    final menuWithUnweighed = <String, MenuItem>{
      'burger': const MenuItem(
        id: 'burger',
        name: 'Burger',
        baseWeightGrams: 200,
        packagingWeightGrams: 20,
        availableModifiers: [
          Modifier(id: 'cheese', name: 'Cheese', weightGrams: 15),
          Modifier(id: 'sprite', name: 'Sprite', weightGrams: null),
        ],
      ),
    };

    Order orderWithMods(List<String> mods) => Order(
          id: 'o4',
          customerName: 'Test',
          items: [OrderItem(menuItemId: 'burger', selectedModifierIds: mods)],
          readyInMinutes: 5,
          dasherInMinutes: 5,
        );

    test('modifierById still finds it (for display) even though unweighed',
        () {
      expect(menuWithUnweighed['burger']!.modifierById('sprite'), isNotNull);
      expect(
          menuWithUnweighed['burger']!.modifierById('sprite')!.weightGrams,
          isNull);
    });

    test('expectedFor contributes nothing for the unweighed modifier', () {
      final e =
          evaluator.expectedFor(orderWithMods(['sprite']), menuWithUnweighed);
      expect(e.grams, 220); // base + packaging only, sprite contributes 0
    });

    test('expectedFor still adds the weighed modifier alongside an unweighed one',
        () {
      final e = evaluator.expectedFor(
          orderWithMods(['cheese', 'sprite']), menuWithUnweighed);
      expect(e.grams, 235); // 200 + 20 + 15, sprite contributes 0
    });

    test('rangeFor skips the unweighed modifier the same way', () {
      const withRange = MenuItem(
        id: 'burger3',
        name: 'Burger',
        baseWeightGrams: 220,
        minWeightGrams: 210,
        maxWeightGrams: 230,
        availableModifiers: [
          Modifier(id: 'sprite', name: 'Sprite', weightGrams: null),
        ],
      );
      final menu = {'burger3': withRange};
      final order = Order(
        id: 'o5',
        customerName: 'Test',
        items: [
          const OrderItem(menuItemId: 'burger3', selectedModifierIds: ['sprite'])
        ],
        readyInMinutes: 5,
        dasherInMinutes: 5,
      );
      final range = evaluator.rangeFor(order, menu);
      expect(range, isNotNull);
      expect(range!.idealGrams, 220);
      expect(range.minGrams, 210);
      expect(range.maxGrams, 230);
    });
  });

  group('tolerance window', () {
    test('takes the largest of the three floors', () {
      const t = ToleranceSettings(
        stdDevMultiplier: 2,
        percentFloor: 5,
        absoluteGramFloor: 5,
      );
      // expected 100g, stdDev 1 -> stddev floor 2, percent floor 5, abs 5 -> 5
      expect(t.toleranceGrams(expectedGrams: 100, combinedStdDev: 1), 5);
      // expected 1000g -> percent floor 50 dominates
      expect(t.toleranceGrams(expectedGrams: 1000, combinedStdDev: 1), 50);
      // large stdDev dominates
      expect(t.toleranceGrams(expectedGrams: 100, combinedStdDev: 40), 80);
    });
  });
}
