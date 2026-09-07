import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tare_pack_station/data/headoffice_api.dart';
import 'package:tare_pack_station/data/order_repository.dart';
import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/models/headoffice_settings.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/models/order_status.dart';
import 'package:tare_pack_station/state/headoffice_controller.dart';
import 'package:tare_pack_station/state/orders_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';

class _FakeOrderRepository extends OrderRepository {
  final List<Order> orders;
  const _FakeOrderRepository(this.orders);

  @override
  Future<List<Order>> fetchOrders() async => orders;
}

const _settings = HeadOfficeSettings(
  baseUrl: 'https://example.trycloudflare.com',
  deviceKey: 'dev_test_key',
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Foodics has no "already weighed" concept — it only knows its own POS/
  // delivery lifecycle. An order this device already weighed and dispatched
  // in a PREVIOUS app session (the in-memory dispatched-tracking is gone —
  // that's exactly what a fresh `ordersProvider.build()` simulates: a cold
  // start, a Settings change that rebuilds the order repository, or a
  // Retry) must not reappear as "Ready to weigh" just because Foodics still
  // lists it as open. Head office's own weigh-event history is the durable
  // record that prevents that.
  test(
      'an order already weighed in a previous session is dispatched on a '
      'fresh load, not shown as Ready to weigh again', () async {
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/weigh-events')) {
        return http.Response(
          jsonEncode([
            {
              'eventId': 1,
              'deviceId': 1,
              'foodicsOrderId': 'order-1',
              'expectedMinG': 100,
              'expectedMaxG': 110,
              'measuredG': 105,
              'verdict': 'onweight',
              'overrideReason': null,
              'itemMissing': null,
              'weighedAt': '2026-08-19T06:00:00Z',
            },
          ]),
          200,
        );
      }
      return http.Response('{}', 200);
    });

    // Exactly what a fresh Foodics fetch would produce for this order: no
    // memory of it ever being weighed, since Foodics has nothing to say
    // about that — status defaults to pending.
    const order = Order(
      id: 'order-1',
      customerName: 'Test Customer',
      items: [OrderItem(menuItemId: 'mi_x')],
      readyInMinutes: 0,
      dasherInMinutes: 0,
    );

    final container = ProviderContainer(overrides: [
      initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
      orderRepositoryProvider.overrideWithValue(const _FakeOrderRepository([order])),
      headOfficeApiProvider.overrideWithValue(HeadOfficeApi(_settings, client: client)),
    ]);
    addTearDown(container.dispose);

    final orders = await container.read(ordersProvider.future);

    expect(orders, hasLength(1));
    expect(orders.single.status, OrderStatus.dispatched,
        reason: 'head office already has a weigh-event for this order id');
  });

  test(
      'an order head office has never seen weighed stays Ready to weigh',
      () async {
    final client = MockClient((req) async => http.Response('[]', 200));

    const order = Order(
      id: 'order-2',
      customerName: 'Test Customer',
      items: [OrderItem(menuItemId: 'mi_x')],
      readyInMinutes: 0,
      dasherInMinutes: 0,
    );

    final container = ProviderContainer(overrides: [
      initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
      orderRepositoryProvider.overrideWithValue(const _FakeOrderRepository([order])),
      headOfficeApiProvider.overrideWithValue(HeadOfficeApi(_settings, client: client)),
    ]);
    addTearDown(container.dispose);

    final orders = await container.read(ordersProvider.future);

    expect(orders.single.status, OrderStatus.pending);
  });

  test(
      'if head office cannot be reached, orders still load (fail open, not '
      'closed)', () async {
    final client = MockClient((req) async {
      throw Exception('Could not resolve host');
    });

    const order = Order(
      id: 'order-3',
      customerName: 'Test Customer',
      items: [OrderItem(menuItemId: 'mi_x')],
      readyInMinutes: 0,
      dasherInMinutes: 0,
    );

    final container = ProviderContainer(overrides: [
      initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
      orderRepositoryProvider.overrideWithValue(const _FakeOrderRepository([order])),
      headOfficeApiProvider.overrideWithValue(HeadOfficeApi(_settings, client: client)),
    ]);
    addTearDown(container.dispose);

    final orders = await container.read(ordersProvider.future);

    expect(orders, hasLength(1));
    expect(orders.single.status, OrderStatus.pending);
  });

  // Regression test for a real report: a duplicate weigh-event appeared for
  // the same order a few minutes apart. Foodics has no "already weighed"
  // concept, so head office's own weigh-event history is normally what
  // prevents a re-weigh — but that's a network round trip, and if it fails at
  // exactly the moment the app restarts (a hiccup, or the exact moment a
  // build is installed), an already-dispatched order would revert to "Ready
  // to weigh" and could be weighed again, creating a duplicate. This
  // device's own local record of its recent dispatches (persisted via
  // SettingsStore, independent of any network call) is the safety net for
  // exactly that gap.
  test(
      'when head office is unreachable, this device\'s own local dispatch '
      'record still prevents a re-weigh (the duplicate-weigh-event bug)',
      () async {
    final client = MockClient((req) async {
      throw Exception('Could not resolve host');
    });

    const order = Order(
      id: 'order-4',
      customerName: 'Test Customer',
      items: [OrderItem(menuItemId: 'mi_x')],
      readyInMinutes: 0,
      dasherInMinutes: 0,
    );

    // Simulates this device having dispatched the order in an earlier
    // session (e.g. right before an app restart) — recorded locally, exactly
    // as `OrdersController.dispatch()` does.
    await SettingsStore().saveDispatchedOrder('order-4', overrideReason: null);

    final container = ProviderContainer(overrides: [
      initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
      orderRepositoryProvider.overrideWithValue(const _FakeOrderRepository([order])),
      headOfficeApiProvider.overrideWithValue(HeadOfficeApi(_settings, client: client)),
    ]);
    addTearDown(container.dispose);

    final orders = await container.read(ordersProvider.future);

    expect(orders.single.status, OrderStatus.dispatched,
        reason: 'the local cache alone must be enough to prevent a '
            're-weigh, even with head office completely unreachable');
  });
}
