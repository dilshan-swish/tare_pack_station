import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/modifier.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/state/order_math.dart';

void main() {
  group('findUnconfiguredWeightMessages / orderHasUnconfiguredWeight', () {
    final configuredItem = const MenuItem(
      id: 'mi_burger',
      name: 'Burger',
      baseWeightGrams: 200,
      availableModifiers: [
        Modifier(id: 'mod_cheese', name: 'Cheese', weightGrams: 20),
      ],
    );
    final unweighedItem = const MenuItem(id: 'mi_fries', name: 'Fries', baseWeightGrams: 0);

    Order orderWith(List<OrderItem> items) => Order(
          id: 'o1',
          customerName: 'Test',
          items: items,
          readyInMinutes: 0,
          dasherInMinutes: 0,
        );

    test('fully configured order -> no messages, not flagged', () {
      final order = orderWith([
        const OrderItem(menuItemId: 'mi_burger', selectedModifierIds: ['mod_cheese']),
      ]);
      final menuIndex = {'mi_burger': configuredItem};
      expect(findUnconfiguredWeightMessages(order, menuIndex), isEmpty);
      expect(orderHasUnconfiguredWeight(order, menuIndex), isFalse);
    });

    test('unknown menu item -> flagged as "Unknown item"', () {
      final order = orderWith([const OrderItem(menuItemId: 'mi_missing')]);
      final result = findUnconfiguredWeightMessages(order, const {});
      expect(result, contains('Unknown item'));
      expect(orderHasUnconfiguredWeight(order, const {}), isTrue);
    });

    test('item with no weight set -> flagged by name', () {
      final order = orderWith([const OrderItem(menuItemId: 'mi_fries')]);
      final menuIndex = {'mi_fries': unweighedItem};
      expect(findUnconfiguredWeightMessages(order, menuIndex), contains('Fries'));
      expect(orderHasUnconfiguredWeight(order, menuIndex), isTrue);
    });

    test('selected modifier with no matching weighed entry -> flagged with name',
        () {
      final order = orderWith([
        const OrderItem(
          menuItemId: 'mi_burger',
          selectedModifierIds: ['opt-unweighed'],
          selectedModifierNames: {'opt-unweighed': 'Extra Bacon'},
        ),
      ]);
      final menuIndex = {'mi_burger': configuredItem};
      final result = findUnconfiguredWeightMessages(order, menuIndex);
      expect(result, contains('Burger: Extra Bacon not weighed yet'));
      expect(orderHasUnconfiguredWeight(order, menuIndex), isTrue);
    });

    test(
        'a modifier linked to the item but not yet weighed is flagged too, '
        'not just an unlinked/unknown selection', () {
      final itemWithUnweighedMod = const MenuItem(
        id: 'mi_burger2',
        name: 'Burger',
        baseWeightGrams: 200,
        availableModifiers: [
          Modifier(id: 'mod_sprite', name: 'Sprite', weightGrams: null),
        ],
      );
      final order = orderWith([
        const OrderItem(
          menuItemId: 'mi_burger2',
          selectedModifierIds: ['mod_sprite'],
        ),
      ]);
      final menuIndex = {'mi_burger2': itemWithUnweighedMod};
      final result = findUnconfiguredWeightMessages(order, menuIndex);
      expect(result, contains('Burger: Sprite not weighed yet'));
      expect(orderHasUnconfiguredWeight(order, menuIndex), isTrue);
    });

    test('duplicate unconfigured lines across quantity are deduped', () {
      final order = orderWith([
        const OrderItem(menuItemId: 'mi_fries'),
        const OrderItem(menuItemId: 'mi_fries'),
      ]);
      final menuIndex = {'mi_fries': unweighedItem};
      final result = findUnconfiguredWeightMessages(order, menuIndex);
      expect(result.length, 1);
      expect(result, contains('Fries'));
    });

    test('empty order -> no messages', () {
      final order = orderWith(const []);
      expect(findUnconfiguredWeightMessages(order, const {}), isEmpty);
      expect(orderHasUnconfiguredWeight(order, const {}), isFalse);
    });
  });
}
