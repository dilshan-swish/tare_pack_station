import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/logic/modifier_pairing.dart';
import 'package:tare_pack_station/logic/weight_evaluator.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/modifier.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/state/order_math.dart';

// Modeled on the real BBT case that motivated this feature: a "Hot Little
// Wrap Fillaaa Meal" whose customer picks a fries TYPE ("Curly Fries"), a
// DRINK type ("Sprite"), and a combo SIZE ("Medium") independently — but a
// combo-size choice can change BOTH the fries portion AND the drink portion
// at once (a real 3-way interaction), which no 2-only pairing could
// represent without silently resolving only one of the two.
void main() {
  const curlyFries = Modifier(
    id: 'mod_curly_fries', name: 'Curly Fries', weightGrams: 190,
    minWeightGrams: 180, maxWeightGrams: 200);
  const sprite = Modifier(
    id: 'mod_sprite', name: 'Sprite', weightGrams: 330);
  const mediumSize = Modifier(
    // Deliberately no weight of its own — it only ever makes sense combined
    // with a fries + drink choice, exactly like BBT's real "MEDIUM" combo-
    // size option (left unweighed on its own in the real portal).
    id: 'mod_medium', name: 'MEDIUM', weightGrams: null);
  const saltSeasoning = Modifier(id: 'mod_salt', name: 'Salt', weightGrams: 2);
  const wrap = MenuItem(
    id: 'mi_wrap_meal',
    name: 'Hot Little Wrap Fillaaa Meal',
    baseWeightGrams: 201,
    minWeightGrams: 198,
    maxWeightGrams: 205,
    availableModifiers: [curlyFries, sprite, mediumSize, saltSeasoning],
  );
  final menuIndex = {wrap.id: wrap};

  // A 2-way combination (fries + size) — for cases where drink size doesn't
  // vary, or a standalone fries-only combo.
  final pairIndex = ModifierCombinationIndex([
    ModifierCombinationWeight(
      modifierIds: const ['mod_curly_fries', 'mod_medium'],
      weightG: 145, minWeightG: 141, maxWeightG: 149,
    ),
  ]);

  // The full 3-way combination: size affects fries AND drink together.
  final threeWayIndex = ModifierCombinationIndex([
    ModifierCombinationWeight(
      modifierIds: const ['mod_curly_fries', 'mod_sprite', 'mod_medium'],
      weightG: 410, minWeightG: 402, maxWeightG: 418,
    ),
  ]);

  Order orderWith(List<String> modifierIds) => Order(
        id: 'wrap-order',
        customerName: 'Test',
        items: [
          OrderItem(menuItemId: wrap.id, selectedModifierIds: modifierIds),
        ],
        readyInMinutes: 5,
        dasherInMinutes: 5,
      );

  group('resolveSelectedModifiers — 2-way (pair) combinations', () {
    test('with no combination configured, sums each modifier independently (unchanged behavior)', () {
      final slots = resolveSelectedModifiers(
        wrap, ['mod_curly_fries', 'mod_salt'], ModifierCombinationIndex.empty);
      expect(slots, hasLength(2));
      expect(slots.map((s) => s.weightG), containsAll([190.0, 2.0]));
    });

    test('a modifier with no weight and no combination contributes nothing', () {
      final slots = resolveSelectedModifiers(
        wrap, ['mod_medium'], ModifierCombinationIndex.empty);
      expect(slots, isEmpty);
    });

    test('a matched pair contributes ONE combined slot, not two independent ones', () {
      final slots = resolveSelectedModifiers(
        wrap, ['mod_curly_fries', 'mod_medium'], pairIndex);
      expect(slots, hasLength(1),
          reason: 'must not double-count: the combination replaces both individual weights');
      expect(slots.single.weightG, 145);
      expect(slots.single.ids, containsAll(['mod_curly_fries', 'mod_medium']));
      expect(slots.single.isCombination, isTrue);
    });

    test('order of selection does not matter for matching', () {
      final slots = resolveSelectedModifiers(
        wrap, ['mod_medium', 'mod_curly_fries'], pairIndex);
      expect(slots, hasLength(1));
      expect(slots.single.weightG, 145);
    });

    test('only one half of a pair selected falls back to that one\'s own weight', () {
      final slots = resolveSelectedModifiers(wrap, ['mod_curly_fries'], pairIndex);
      expect(slots, hasLength(1));
      expect(slots.single.weightG, 190);
      expect(slots.single.isCombination, isFalse);
    });
  });

  group('resolveSelectedModifiers — 3-way combination (the case that broke pairwise-only)', () {
    test('MEDIUM + Curly Fries + Sprite together resolve to ONE 3-member slot', () {
      final slots = resolveSelectedModifiers(
        wrap, ['mod_curly_fries', 'mod_sprite', 'mod_medium'], threeWayIndex);
      expect(slots, hasLength(1),
          reason: 'a single 3-way slot must cover all three, not a pair plus a leftover');
      expect(slots.single.weightG, 410);
      expect(slots.single.ids, containsAll(['mod_curly_fries', 'mod_sprite', 'mod_medium']));
    });

    test('a larger (3-way) match wins over any smaller (2-way) match on the same ids', () {
      // An index with BOTH a 2-way (fries+size) and the 3-way (fries+drink+size)
      // configured — selecting all three must use the 3-way, not the 2-way
      // plus drink priced separately (which would be the old, wrong behavior).
      final mixedIndex = ModifierCombinationIndex([
        ModifierCombinationWeight(
          modifierIds: const ['mod_curly_fries', 'mod_medium'], weightG: 145),
        ModifierCombinationWeight(
          modifierIds: const ['mod_curly_fries', 'mod_sprite', 'mod_medium'], weightG: 410),
      ]);
      final slots = resolveSelectedModifiers(
        wrap, ['mod_curly_fries', 'mod_sprite', 'mod_medium'], mixedIndex);
      expect(slots, hasLength(1));
      expect(slots.single.weightG, 410);
      expect(slots.single.ids, hasLength(3));
    });

    test('dropping the drink falls back to the 2-way fries+size combination', () {
      final mixedIndex = ModifierCombinationIndex([
        ModifierCombinationWeight(
          modifierIds: const ['mod_curly_fries', 'mod_medium'], weightG: 145),
        ModifierCombinationWeight(
          modifierIds: const ['mod_curly_fries', 'mod_sprite', 'mod_medium'], weightG: 410),
      ]);
      final slots = resolveSelectedModifiers(
        wrap, ['mod_curly_fries', 'mod_medium'], mixedIndex);
      expect(slots, hasLength(1));
      expect(slots.single.weightG, 145);
      expect(slots.single.ids, hasLength(2));
    });
  });

  group('resolveSelectedModifiers — anchored pairs (shared anchor, e.g. combo size '
      'independently affecting fries AND drinks — the portal\'s "Combine modifiers" tool)', () {
    // Two INDEPENDENT anchored pairs sharing the same anchor (MEDIUM): fries
    // depends on size, and — completely separately — drink depends on size.
    // Unlike a single fused 3-way row, neither pair needs the other selected.
    final anchoredIndex = ModifierCombinationIndex([
      ModifierCombinationWeight(
        modifierIds: const ['mod_curly_fries', 'mod_medium'],
        weightG: 145, minWeightG: 141, maxWeightG: 149,
        anchorModifierId: 'mod_medium',
      ),
      ModifierCombinationWeight(
        modifierIds: const ['mod_sprite', 'mod_medium'],
        weightG: 210, minWeightG: 205, maxWeightG: 215,
        anchorModifierId: 'mod_medium',
      ),
    ]);

    test('MEDIUM anchors fries and drink independently — both apply simultaneously', () {
      final slots = resolveSelectedModifiers(
        wrap, ['mod_curly_fries', 'mod_sprite', 'mod_medium'], anchoredIndex);
      expect(slots, hasLength(2),
          reason: 'two independent overrides, not one fused 3-way slot');
      final byWeight = slots.map((s) => s.weightG).toList()..sort();
      expect(byWeight, [145, 210]);
      expect(slots.every((s) => s.isCombination), isTrue);
      // Each slot represents only its own dependent, not the shared anchor —
      // so the two overrides can never be mistaken for double-claiming MEDIUM.
      expect(slots.every((s) => s.ids.length == 1), isTrue);
    });

    test('the shared anchor\'s own configured weight is added exactly once, never doubled', () {
      // A hypothetical where MEDIUM itself DOES carry its own weight — proves
      // the shared anchor is not double-counted just because two dependents
      // key off it (145 + 210 + 5, not +5 twice or +10).
      const mediumWithOwnWeight = Modifier(id: 'mod_medium', name: 'MEDIUM', weightGrams: 5);
      final wrapVariant = MenuItem(
        id: wrap.id, name: wrap.name,
        baseWeightGrams: wrap.baseWeightGrams,
        minWeightGrams: wrap.minWeightGrams, maxWeightGrams: wrap.maxWeightGrams,
        availableModifiers: [curlyFries, sprite, mediumWithOwnWeight, saltSeasoning],
      );
      final slots = resolveSelectedModifiers(
        wrapVariant, ['mod_curly_fries', 'mod_sprite', 'mod_medium'], anchoredIndex);
      expect(slots, hasLength(3));
      final total = slots.fold<double>(0, (sum, s) => sum + s.weightG);
      expect(total, 145 + 210 + 5);
    });

    test('only one dependent selected applies only its own anchored pair', () {
      final slots = resolveSelectedModifiers(wrap, ['mod_curly_fries', 'mod_medium'], anchoredIndex);
      expect(slots, hasLength(1));
      expect(slots.single.weightG, 145);
    });

    test('dropping the drink still fully resolves fries+size — no fused-3-way partial-selection problem', () {
      // Unlike the fused 3-way combination (which needs ALL 3 selected to
      // match at all), each anchored pair only needs its own 2 members.
      final unresolved =
          unresolvedModifierIds(wrap, ['mod_curly_fries', 'mod_medium'], anchoredIndex);
      expect(unresolved, isEmpty);
    });

    test('a symmetric (unanchored) combo and an anchored combo can coexist on the same anchor', () {
      // Models an item that still has an OLD-style symmetric size+fries row
      // (from before anchoring existed) alongside a NEW anchored size+drink
      // row — must not conflict, and must not double- or under-count MEDIUM.
      final mixedOldAndNew = ModifierCombinationIndex([
        ModifierCombinationWeight(
          modifierIds: const ['mod_curly_fries', 'mod_medium'], weightG: 145),
        ModifierCombinationWeight(
          modifierIds: const ['mod_sprite', 'mod_medium'], weightG: 210,
          anchorModifierId: 'mod_medium'),
      ]);
      final slots = resolveSelectedModifiers(
        wrap, ['mod_curly_fries', 'mod_sprite', 'mod_medium'], mixedOldAndNew);
      expect(slots, hasLength(2));
      final total = slots.fold<double>(0, (sum, s) => sum + s.weightG);
      expect(total, 145 + 210);
    });

    test('the anchor alone, with no dependent selected, is genuinely unresolved', () {
      final unresolved = unresolvedModifierIds(wrap, ['mod_medium'], anchoredIndex);
      expect(unresolved, {'mod_medium'});
    });
  });

  group('WeightEvaluator with an anchored combinationIndex', () {
    const evaluator = WeightEvaluator();
    final anchoredIndex = ModifierCombinationIndex([
      ModifierCombinationWeight(
        modifierIds: const ['mod_curly_fries', 'mod_medium'],
        weightG: 145, minWeightG: 141, maxWeightG: 149,
        anchorModifierId: 'mod_medium',
      ),
      ModifierCombinationWeight(
        modifierIds: const ['mod_sprite', 'mod_medium'],
        weightG: 210, minWeightG: 205, maxWeightG: 215,
        anchorModifierId: 'mod_medium',
      ),
    ]);

    test('expectedFor sums both independent overrides, not one fused number', () {
      final expected = evaluator.expectedFor(
        orderWith(['mod_curly_fries', 'mod_sprite', 'mod_medium']), menuIndex,
        combinationIndex: anchoredIndex,
      );
      expect(expected.grams, 201 + 145 + 210); // 556
    });

    test('rangeFor sums both overrides\' own min/max independently', () {
      final range = evaluator.rangeFor(
        orderWith(['mod_curly_fries', 'mod_sprite', 'mod_medium']), menuIndex,
        combinationIndex: anchoredIndex,
      );
      expect(range, isNotNull);
      expect(range!.idealGrams, 556);
      expect(range.minGrams, 198 + 141 + 205); // 544
      expect(range.maxGrams, 205 + 149 + 215); // 569
    });
  });

  group('unresolvedModifierIds', () {
    test('an unweighed modifier with no combination partner selected is unresolved', () {
      final unresolved =
          unresolvedModifierIds(wrap, ['mod_medium'], ModifierCombinationIndex.empty);
      expect(unresolved, {'mod_medium'});
    });

    test('an unweighed modifier resolved by a 3-way combination is NOT unresolved', () {
      final unresolved = unresolvedModifierIds(
        wrap, ['mod_curly_fries', 'mod_sprite', 'mod_medium'], threeWayIndex);
      expect(unresolved, isEmpty);
    });

    test('same unweighed modifier without its full combination selected IS unresolved', () {
      final unresolved =
          unresolvedModifierIds(wrap, ['mod_medium', 'mod_curly_fries'], threeWayIndex);
      expect(unresolved, {'mod_medium'},
          reason: 'the 3-way combination needs the drink too — with only 2 of 3 selected, '
              'MEDIUM has no partner match and no weight of its own');
    });
  });

  group('WeightEvaluator with combinationIndex', () {
    const evaluator = WeightEvaluator();

    test('expectedFor uses the 3-way combined weight, not the sum of all four', () {
      final expected = evaluator.expectedFor(
        orderWith(['mod_curly_fries', 'mod_sprite', 'mod_medium']), menuIndex,
        combinationIndex: threeWayIndex,
      );
      // 201 (wrap base) + 410 (3-way combo) = 611 — NOT 201+190+330+410=1131.
      expect(expected.grams, 611);
    });

    test('expectedFor without a combinationIndex falls back to plain addition (regression safety)', () {
      final expected = evaluator.expectedFor(orderWith(['mod_curly_fries']), menuIndex);
      expect(expected.grams, 391); // 201 + 190
    });

    test('rangeFor sums the 3-way combination\'s own min/max, not each modifier\'s', () {
      final range = evaluator.rangeFor(
        orderWith(['mod_curly_fries', 'mod_sprite', 'mod_medium']), menuIndex,
        combinationIndex: threeWayIndex,
      );
      expect(range, isNotNull);
      expect(range!.idealGrams, 611); // 201 + 410
      expect(range.minGrams, 600); // 198 + 402
      expect(range.maxGrams, 623); // 205 + 418
    });
  });

  group('findUnconfiguredWeightMessages with combinationIndex', () {
    test('flags MEDIUM as unconfigured when no combination covers it', () {
      final messages = findUnconfiguredWeightMessages(
        orderWith(['mod_curly_fries', 'mod_sprite', 'mod_medium']), menuIndex);
      expect(messages, isNotEmpty);
      expect(messages.first, contains('MEDIUM'));
    });

    test('does NOT flag MEDIUM once the full 3-way combination is set', () {
      final messages = findUnconfiguredWeightMessages(
        orderWith(['mod_curly_fries', 'mod_sprite', 'mod_medium']), menuIndex,
        combinationIndex: threeWayIndex);
      expect(messages, isEmpty,
          reason: 'the 3-way combination fully resolves all three modifiers together');
    });

    test('still flags MEDIUM when only 2 of the 3 combination partners are selected', () {
      final messages = findUnconfiguredWeightMessages(
        orderWith(['mod_curly_fries', 'mod_medium']), menuIndex,
        combinationIndex: threeWayIndex);
      expect(messages, isNotEmpty);
      expect(messages.first, contains('MEDIUM'));
    });
  });
}
