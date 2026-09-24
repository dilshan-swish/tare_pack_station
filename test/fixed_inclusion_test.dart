import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/ai/discrepancy.dart';
import 'package:tare_pack_station/ai/discrepancy_engine.dart';
import 'package:tare_pack_station/ai/discrepancy_model_config.dart';
import 'package:tare_pack_station/data/headoffice_api.dart';
import 'package:tare_pack_station/logic/modifier_pairing.dart';
import 'package:tare_pack_station/logic/weight_evaluator.dart';
import 'package:tare_pack_station/models/fixed_inclusion.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/modifier.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/models/order_status.dart';
import 'package:tare_pack_station/models/tolerance_settings.dart';
import 'package:tare_pack_station/state/order_math.dart';

// Built on the real BBT case that motivated fixed inclusions: "Chilli Lime
// Tenders Fillaaa" (MenuItemId 18 in head office, ideal 510g / 470-550g)
// always ships with a ranch dip (~87g) and a slaw (~88g). Neither is a
// Foodics modifier, so before this feature the only place their weight could
// live was folded into the item's own band — which is why a bag missing them
// still passed the weight check.
void main() {
  const cokeZero = Modifier(
    id: 'mod_coke_zero', name: 'Coca-Cola Zero', weightGrams: 265,
    minWeightGrams: 258, maxWeightGrams: 272);
  const notSoCurly = Modifier(
    // Zero by design: the fries are already inside the box, so they're never
    // separately missed — exactly how BBT configures this in the portal.
    id: 'mod_not_so_curly', name: 'Not So Curly Fries', weightGrams: 0,
    minWeightGrams: 0, maxWeightGrams: 0);

  const ranch = FixedInclusion(
    id: 1, name: 'Ranch', weightGrams: 87, minWeightGrams: 82, maxWeightGrams: 92);
  const slaw = FixedInclusion(
    id: 2, name: 'Slaw', weightGrams: 88, minWeightGrams: 83, maxWeightGrams: 93);

  const tenders = MenuItem(
    id: 'mi_chilli_lime_tenders',
    name: 'Chilli Lime Tenders Fillaaa',
    baseWeightGrams: 510,
    minWeightGrams: 470,
    maxWeightGrams: 550,
    availableModifiers: [cokeZero, notSoCurly],
    fixedInclusions: [ranch, slaw],
  );

  final menuIndex = {tenders.id: tenders};
  final order = Order(
    id: 'o1',
    customerName: 'Test',
    items: const [
      OrderItem(
        menuItemId: 'mi_chilli_lime_tenders',
        selectedModifierIds: ['mod_not_so_curly', 'mod_coke_zero'],
      ),
    ],
    readyInMinutes: 5,
    dasherInMinutes: 5,
  );

  const evaluator = WeightEvaluator();

  group('expected weight', () {
    test('adds every always-included component, though nothing selected them', () {
      final expected = evaluator.expectedFor(order, menuIndex);
      // 510 item + 0 fries + 265 drink + 87 ranch + 88 slaw
      expect(expected.grams, 950);
    });

    test('range sums each component own measured band', () {
      final range = evaluator.rangeFor(order, menuIndex)!;
      expect(range.idealGrams, 950);
      expect(range.minGrams, 470 + 0 + 258 + 82 + 83);
      expect(range.maxGrams, 550 + 0 + 272 + 92 + 93);
    });

    test('an inclusion with no measured band of its own is fixed at both ends', () {
      const noBand = FixedInclusion(id: 3, name: 'Sauce cup', weightGrams: 20);
      final item = tenders.copyWith(fixedInclusions: const [noBand]);
      final range = evaluator.rangeFor(order, {item.id: item})!;
      expect(range.minGrams, 470 + 0 + 258 + 20);
      expect(range.maxGrams, 550 + 0 + 272 + 20);
    });
  });

  group('missing component detection', () {
    // The whole point of the feature: with ranch and slaw declared, a bag
    // packed without them lands outside the accepted band instead of inside
    // it. 875g is the real-world "forgot both dips" weight for this order.
    test('a bag missing both dips now reads UNDER, where before it passed', () {
      final withInclusions = evaluator.rangeFor(order, menuIndex)!;
      expect(
        evaluator.evaluateRange(measuredGrams: 775, range: withInclusions).status,
        OrderStatus.under,
      );

      // Same order, same bag, with the dips NOT declared — the old behavior.
      final blind = tenders.copyWith(fixedInclusions: const []);
      final blindRange = evaluator.rangeFor(order, {blind.id: blind})!;
      expect(
        evaluator.evaluateRange(measuredGrams: 775, range: blindRange).status,
        OrderStatus.onWeight,
        reason: 'without the inclusions declared the omission is invisible — '
            'this is the bug the feature exists to fix',
      );
    });

    test('a correctly packed bag still reads on weight', () {
      final range = evaluator.rangeFor(order, menuIndex)!;
      expect(
        evaluator.evaluateRange(measuredGrams: 950, range: range).status,
        OrderStatus.onWeight,
      );
    });

    test('the engine names the specific dip that is missing', () {
      // 950 expected, 863 measured — short by exactly one ranch.
      final result = const WeightInferenceEngine(DiscrepancyModelConfig.fallback).analyze(
        order: order,
        measuredGrams: 863,
        menuIndex: menuIndex,
        tolerance: const ToleranceSettings(),
      );
      expect(
        result.predictions.any((p) =>
            p.kind == PredictionKind.missingModifier &&
            p.title.toLowerCase().contains('ranch')),
        isTrue,
        reason: 'predictions were: '
            '${result.predictions.map((p) => '${p.kind}/${p.title}').toList()}',
      );
    });
  });

  group('declared but not yet weighed', () {
    const unweighed = FixedInclusion(id: 9, name: 'Ranch', weightGrams: null);
    final pending = tenders.copyWith(fixedInclusions: const [unweighed]);
    final pendingIndex = {pending.id: pending};

    test('never counts as 0g — it is left out of the total entirely', () {
      // 510 + 0 + 265, with nothing invented for the unweighed dip.
      expect(evaluator.expectedFor(order, pendingIndex).grams, 775);
    });

    test('blocks the check the same way an unweighed modifier does', () {
      final messages = findUnconfiguredWeightMessages(order, pendingIndex);
      expect(messages, hasLength(1));
      expect(messages.single, contains('Ranch'));
      expect(messages.single, contains('always included'));
      expect(orderHasUnconfiguredWeight(order, pendingIndex), isTrue);
    });

    test('a fully weighed item reports nothing unconfigured', () {
      expect(findUnconfiguredWeightMessages(order, menuIndex), isEmpty);
    });
  });

  group('plumbing', () {
    test('resolved slot ids are namespaced so they cannot collide with modifiers', () {
      final slots = resolveFixedInclusions(tenders);
      expect(slots.map((s) => s.ids.single), ['inclusion:1', 'inclusion:2']);
      expect(slots.map((s) => s.label), ['Ranch', 'Slaw']);
    });

    test('survives the round trip through the on-disk menu cache', () {
      final restored =
          MenuItem.fromJson(jsonDecode(jsonEncode(tenders.toJson())) as Map<String, dynamic>);
      expect(restored.fixedInclusions, hasLength(2));
      expect(restored.fixedInclusions.first.name, 'Ranch');
      expect(restored.fixedInclusions.first.weightGrams, 87);
      expect(restored.fixedInclusions.first.minWeightGrams, 82);
      expect(restored.fixedInclusions.last.name, 'Slaw');
    });

    test('parses inclusions out of a head-office config payload', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'BBT',
        'publishedVersion': 26,
        'modifiers': [],
        'items': [
          {
            'foodicsProductId': 'a0128dc0-d97a-44b5-a0ee-4dcc8a536799',
            'name': 'Chilli Lime Tenders Fillaaa',
            'idealWeightG': 510,
            'minWeightG': 470,
            'maxWeightG': 550,
            'modifierIds': <String>[],
            'inclusions': [
              {
                'inclusionId': 4,
                'name': 'Ranch',
                'idealWeightG': 87,
                'minWeightG': 82,
                'maxWeightG': 92,
              },
              // No weight yet — kept, so the tablet can say what's pending
              // rather than silently pretending the item is fully configured.
              {'inclusionId': 5, 'name': 'Slaw', 'idealWeightG': null},
              // Unusable: nothing could be shown or explained to staff.
              {'inclusionId': 6, 'idealWeightG': 50},
            ],
          },
        ],
      })!;

      final item = config.items.single;
      expect(item.fixedInclusions, hasLength(2));
      expect(item.fixedInclusions.first.name, 'Ranch');
      expect(item.fixedInclusions.first.weightGrams, 87);
      expect(item.fixedInclusions.last.name, 'Slaw');
      expect(item.fixedInclusions.last.isWeightConfigured, isFalse);
    });

    test('an item with no inclusions field is unaffected', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'BBT',
        'publishedVersion': 1,
        'modifiers': [],
        'items': [
          {'foodicsProductId': 'p1', 'name': 'Toast', 'idealWeightG': 80, 'modifierIds': <String>[]},
        ],
      })!;
      expect(config.items.single.fixedInclusions, isEmpty);
    });
  });
}
