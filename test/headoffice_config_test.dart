import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/data/headoffice_api.dart';
import 'package:tare_pack_station/state/headoffice_menu_controller.dart';

void main() {
  group('HeadOfficeMenuState.hasBrandBranch', () {
    // This gate is what lets live orders auto-follow the device's own
    // registered branch instead of a separately (and mismatchably) picked
    // brand/branch in Settings — it must require BOTH pieces.
    test('false by default (nothing loaded yet)', () {
      const state = HeadOfficeMenuState();
      expect(state.hasBrandBranch, isFalse);
    });

    test('false with a brand code but no Foodics branch id', () {
      const state = HeadOfficeMenuState(brandCode: 'BBT');
      expect(state.hasBrandBranch, isFalse);
    });

    test('false with a Foodics branch id but no brand code', () {
      const state = HeadOfficeMenuState(foodicsBranchId: 'a0005bb5-...');
      expect(state.hasBrandBranch, isFalse);
    });

    test('true once both are present', () {
      const state = HeadOfficeMenuState(
        brandCode: 'BBT',
        foodicsBranchId: 'a0005bb5-b7b0-4605-b590-f739968de578',
      );
      expect(state.hasBrandBranch, isTrue);
    });
  });

  group('parseHeadOfficeConfig', () {
    test('parses a full, well-formed config', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 4,
        'menuSyncedVersion': 12,
        'foodicsBranchId': 'a0005bb5-b7b0-4605-b590-f739968de578',
        'branchName': 'ARD-BBT',
        'items': [
          {
            'menuItemId': 10,
            'foodicsProductId': 'prod-fillaa',
            'name': 'Fillaa on Toast Duo Combo',
            'categoryName': 'Combos',
            'idealWeightG': 805,
            'minWeightG': 780,
            'maxWeightG': 830,
            'packagingWeightG': 20,
            'isConfigured': true,
            'isActive': true,
            'modifierIds': ['opt-curly-fries'],
          },
        ],
        'modifiers': [
          {
            'modifierId': 100,
            'foodicsModifierId': 'opt-curly-fries',
            'name': 'Curly Fries',
            'modifierGroupName': 'Choice of Fries',
            'weightG': 150,
            'isConfigured': true,
          },
        ],
      });

      expect(config, isNotNull);
      expect(config!.brandCode, 'BBT');
      expect(config.publishedVersion, 4);
      // Deliberately separate from publishedVersion — the automatic-sync
      // signal (see FoodicsAutoSyncHostedService), not the admin's Publish.
      expect(config.menuSyncedVersion, 12);
      expect(config.items, hasLength(1));
      final item = config.items.single;
      expect(item.id, 'prod-fillaa');
      expect(item.baseWeightGrams, 805);
      expect(item.minWeightGrams, 780);
      expect(item.maxWeightGrams, 830);
      expect(item.packagingWeightGrams, 20);
      // Only the options actually linked to this item via modifierIds.
      expect(item.availableModifiers, hasLength(1));
      expect(item.modifierById('opt-curly-fries')?.weightGrams, 150);
      expect(item.modifierById('opt-curly-fries')?.groupName, 'Choice of Fries');
      // The device's own branch — lets live orders be fetched automatically
      // for exactly this branch, without a separately (and mismatchably)
      // picked brand/branch in Settings.
      expect(config.foodicsBranchId, 'a0005bb5-b7b0-4605-b590-f739968de578');
      // The friendly label — never the raw UUID above should be shown to staff.
      expect(config.branchName, 'ARD-BBT');
      expect(item.isActive, isTrue);
    });

    test('an inactive item still parses (and is still linked to its real, '
        'unweighed modifiers) — inactive means greyed out, not hidden', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {
            'foodicsProductId': 'prod-discontinued',
            'name': 'Discontinued Combo',
            'isActive': false,
            'modifierIds': ['opt-x'],
          },
        ],
        'modifiers': [
          {'foodicsModifierId': 'opt-x', 'name': 'Extra X', 'weightG': null},
        ],
      });

      expect(config, isNotNull);
      final item = config!.items.single;
      expect(item.isActive, isFalse);
      // Still shown, still carrying its real (if unweighed) modifier.
      expect(item.availableModifiers, hasLength(1));
      expect(item.modifierById('opt-x'), isNotNull);
    });

    test('an item with no isActive key defaults to active (backwards compatible)',
        () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {'foodicsProductId': 'prod-1', 'name': 'Item 1'},
        ],
      });
      expect(config, isNotNull);
      expect(config!.items.single.isActive, isTrue);
    });

    test('menuSyncedVersion defaults to 0 when absent (an older head-office '
        'build that predates automatic sync)', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': const [],
      });
      expect(config, isNotNull);
      expect(config!.menuSyncedVersion, 0);
    });

    test('branchName/foodicsBranchId are null when the branch has never been '
        'linked to a Foodics branch', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
      });
      expect(config, isNotNull);
      expect(config!.foodicsBranchId, isNull);
      expect(config.branchName, isNull);
    });

    test(
        'a modifier is only visible on the item whose modifierIds actually '
        'link to it — not on every item (no cross-item duplicate leakage)',
        () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {
            'foodicsProductId': 'prod-a',
            'name': 'Item A',
            'idealWeightG': 100,
            'modifierIds': ['opt-a'],
          },
          {
            'foodicsProductId': 'prod-b',
            'name': 'Item B',
            'idealWeightG': 100,
            'modifierIds': ['opt-b'],
          },
        ],
        'modifiers': [
          {'foodicsModifierId': 'opt-a', 'name': 'Extra A', 'weightG': 10},
          {'foodicsModifierId': 'opt-b', 'name': 'Extra B', 'weightG': 20},
        ],
      });

      expect(config, isNotNull);
      final itemA =
          config!.items.firstWhere((i) => i.id == 'prod-a');
      final itemB = config.items.firstWhere((i) => i.id == 'prod-b');

      expect(itemA.availableModifiers, hasLength(1));
      expect(itemA.modifierById('opt-a'), isNotNull);
      expect(itemA.modifierById('opt-b'), isNull);

      expect(itemB.availableModifiers, hasLength(1));
      expect(itemB.modifierById('opt-b'), isNotNull);
      expect(itemB.modifierById('opt-a'), isNull);
    });

    test('an item with no modifierIds has no modifiers, even if the brand '
        'has some configured', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {'foodicsProductId': 'prod-1', 'name': 'Item 1', 'idealWeightG': 100},
        ],
        'modifiers': [
          {'foodicsModifierId': 'opt-unrelated', 'name': 'Unrelated', 'weightG': 10},
        ],
      });

      expect(config, isNotNull);
      expect(config!.items.single.availableModifiers, isEmpty);
    });

    test('parses a modifier\'s optional Min/Max range', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {
            'foodicsProductId': 'prod-1',
            'name': 'Item 1',
            'modifierIds': ['opt-coleslaw'],
          },
        ],
        'modifiers': [
          {
            'foodicsModifierId': 'opt-coleslaw',
            'name': 'Coleslaw',
            'weightG': 60,
            'minWeightG': 55,
            'maxWeightG': 68,
          },
        ],
      });

      expect(config, isNotNull);
      final mod = config!.items.single.modifierById('opt-coleslaw');
      expect(mod, isNotNull);
      expect(mod!.weightGrams, 60);
      expect(mod.minWeightGrams, 55);
      expect(mod.maxWeightGrams, 68);
      expect(mod.hasRange, isTrue);
    });

    test('a modifier with only an ideal weight has no range (hasRange false)',
        () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {
            'foodicsProductId': 'prod-1',
            'name': 'Item 1',
            'modifierIds': ['opt-sauce'],
          },
        ],
        'modifiers': [
          {'foodicsModifierId': 'opt-sauce', 'name': 'Sauce', 'weightG': 20},
        ],
      });

      expect(config, isNotNull);
      final mod = config!.items.single.modifierById('opt-sauce');
      expect(mod, isNotNull);
      expect(mod!.hasRange, isFalse);
    });

    test(
        'a modifier with no weight yet is still linked (so it can be shown, '
        'e.g. in the item detail dialog) but its weight stays null, never 0',
        () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {
            'foodicsProductId': 'prod-1',
            'name': 'Item 1',
            'idealWeightG': 100,
            'modifierIds': ['opt-unweighed'],
          },
        ],
        'modifiers': [
          {
            'foodicsModifierId': 'opt-unweighed',
            'name': 'New Sauce',
            'weightG': null, // not yet configured in the portal
          },
        ],
      });

      expect(config, isNotNull);
      final item = config!.items.single;
      expect(item.availableModifiers, hasLength(1));
      final mod = item.modifierById('opt-unweighed');
      expect(mod, isNotNull);
      expect(mod!.name, 'New Sauce');
      // Never zeroed — the weight math (WeightEvaluator / order_math) treats
      // a null weight exactly like the modifier being absent.
      expect(mod.weightGrams, isNull);
    });

    test('items/modifiers missing entirely -> empty lists, no throw', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 0,
      });
      expect(config, isNotNull);
      expect(config!.items, isEmpty);
    });

    test('one malformed item is skipped, the rest still parse', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {'foodicsProductId': 'prod-good', 'name': 'Good Item', 'idealWeightG': 50},
          'not a map',
          {'name': 'Missing id'}, // no foodicsProductId
          <String, dynamic>{}, // empty
        ],
      });

      expect(config, isNotNull);
      expect(config!.items, hasLength(1));
      expect(config.items.single.id, 'prod-good');
    });

    test('one malformed modifier is skipped, the rest still parse', () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {
            'foodicsProductId': 'prod-1',
            'name': 'Item',
            'idealWeightG': 10,
            'modifierIds': ['opt-good'],
          },
        ],
        'modifiers': [
          'not a map',
          {'foodicsModifierId': '', 'name': 'Blank id', 'weightG': 5},
          {'name': 'Missing id', 'weightG': 5},
          {
            'foodicsModifierId': 'opt-good',
            'name': 'Good Option',
            'weightG': 25,
          },
        ],
      });

      expect(config, isNotNull);
      final item = config!.items.single;
      expect(item.availableModifiers, hasLength(1));
      expect(item.modifierById('opt-good')?.weightGrams, 25);
    });

    test('an id in modifierIds with no matching catalog entry at all is skipped',
        () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {
            'foodicsProductId': 'prod-1',
            'name': 'Item',
            'idealWeightG': 10,
            'modifierIds': ['opt-ghost', 'opt-good'],
          },
        ],
        'modifiers': [
          {'foodicsModifierId': 'opt-good', 'name': 'Good Option', 'weightG': 25},
        ],
      });

      expect(config, isNotNull);
      final item = config!.items.single;
      expect(item.availableModifiers, hasLength(1));
      expect(item.modifierById('opt-good'), isNotNull);
    });

    test('item with no idealWeightG defaults to 0 (flagged unconfigured elsewhere)',
        () {
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {'foodicsProductId': 'prod-new', 'name': 'Brand New Item'},
        ],
      });
      expect(config, isNotNull);
      final item = config!.items.single;
      expect(item.baseWeightGrams, 0);
      expect(item.isWeightConfigured, isFalse);
    });

    test('a negative modifier weight (e.g. "No Onion") parses through unchanged',
        () {
      // A removal modifier's weight is negative by design — it must not be
      // filtered out (only an actually-absent weightG should be), clamped to
      // zero, or otherwise mangled on the way from the portal to the scale.
      final config = parseHeadOfficeConfig({
        'brandId': 1,
        'code': 'BBT',
        'name': 'Bait Al Baraka',
        'publishedVersion': 1,
        'items': [
          {
            'foodicsProductId': 'prod-1',
            'name': 'Item 1',
            'idealWeightG': 200,
            'modifierIds': ['opt-no-onion'],
          },
        ],
        'modifiers': [
          {
            'foodicsModifierId': 'opt-no-onion',
            'name': 'No Onion',
            'weightG': -12,
          },
        ],
      });

      expect(config, isNotNull);
      final mod = config!.items.single.modifierById('opt-no-onion');
      expect(mod, isNotNull);
      expect(mod!.weightGrams, -12);
    });

    test('completely malformed top-level shape does not throw', () {
      expect(
        () => parseHeadOfficeConfig({'items': 'not a list', 'modifiers': 12345}),
        returnsNormally,
      );
    });
  });
}
