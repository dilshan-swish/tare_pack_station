import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tare_pack_station/ai/discrepancy.dart';
import 'package:tare_pack_station/ai/discrepancy_providers.dart';
import 'package:tare_pack_station/data/order_repository.dart';
import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/models/order_status.dart';
import 'package:tare_pack_station/state/menu_index_provider.dart';
import 'package:tare_pack_station/state/orders_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';

class _FakeOrderRepository extends OrderRepository {
  final List<Order> orders;
  const _FakeOrderRepository(this.orders);

  @override
  Future<List<Order>> fetchOrders() async => orders;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Regression test for a real report: the AI weight-check's "wrong bag"
  // suggestion was matching against ANY other order, including ones already
  // dispatched — but a dispatched order's bag is already gone, so it can
  // never actually be the one sitting on the scale right now. Only orders
  // still on the main Orders Queue page (i.e. not yet dispatched) are
  // plausible candidates.
  testWidgets('a dispatched order is never suggested as a wrong-bag match',
      (tester) async {
    const menu = {
      'mi_a': MenuItem(id: 'mi_a', name: 'Item A', baseWeightGrams: 100),
      'mi_b': MenuItem(id: 'mi_b', name: 'Item B', baseWeightGrams: 450),
    };
    final selected = const Order(
      id: 'sel',
      orderNumber: 1,
      customerName: 'Alice',
      items: [OrderItem(menuItemId: 'mi_a')], // 100g
      readyInMinutes: 5,
      dasherInMinutes: 5,
    );
    final dispatchedMatch = const Order(
      id: 'dispatched_b',
      orderNumber: 2,
      customerName: 'Bob',
      items: [OrderItem(menuItemId: 'mi_b')], // 450g — matches the bag
      readyInMinutes: 5,
      dasherInMinutes: 5,
      status: OrderStatus.dispatched,
    );

    DiscrepancyResult? result;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          menuIndexProvider.overrideWithValue(menu),
          orderRepositoryProvider.overrideWithValue(
              _FakeOrderRepository([selected, dispatchedMatch])),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(ordersProvider);
              result = analyzeDiscrepancy(ref, selected, 450);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result, isNotNull);
    expect(
      result!.predictions.any((p) => p.kind == PredictionKind.wrongOrder),
      isFalse,
      reason: 'the only order that fits the weight is dispatched, so no '
          'wrong-order suggestion should ever surface',
    );
  });

  testWidgets(
      'a still-queued order IS suggested as a wrong-bag match when it fits',
      (tester) async {
    const menu = {
      'mi_a': MenuItem(id: 'mi_a', name: 'Item A', baseWeightGrams: 100),
      'mi_b': MenuItem(id: 'mi_b', name: 'Item B', baseWeightGrams: 450),
    };
    final selected = const Order(
      id: 'sel',
      orderNumber: 1,
      customerName: 'Alice',
      items: [OrderItem(menuItemId: 'mi_a')], // 100g
      readyInMinutes: 5,
      dasherInMinutes: 5,
    );
    final stillQueuedMatch = const Order(
      id: 'queued_b',
      orderNumber: 2,
      customerName: 'Bob',
      items: [OrderItem(menuItemId: 'mi_b')], // 450g — matches the bag
      readyInMinutes: 5,
      dasherInMinutes: 5,
    );

    DiscrepancyResult? result;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          menuIndexProvider.overrideWithValue(menu),
          orderRepositoryProvider.overrideWithValue(
              _FakeOrderRepository([selected, stillQueuedMatch])),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(ordersProvider);
              result = analyzeDiscrepancy(ref, selected, 450);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result, isNotNull);
    expect(
      result!.predictions.any((p) => p.kind == PredictionKind.wrongOrder),
      isTrue,
    );
  });
}
