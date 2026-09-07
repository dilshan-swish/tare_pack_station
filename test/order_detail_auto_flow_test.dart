import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tare_pack_station/data/headoffice_api.dart';
import 'package:tare_pack_station/data/order_repository.dart';
import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/models/headoffice_settings.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/modifier.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/screens/order_detail_screen.dart';
import 'package:tare_pack_station/state/headoffice_controller.dart';
import 'package:tare_pack_station/state/menu_index_provider.dart';
import 'package:tare_pack_station/state/orders_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';
import 'package:tare_pack_station/state/weight_providers.dart';
import 'package:tare_pack_station/theme/app_theme.dart';
import 'package:tare_pack_station/weight/manual_weight_source.dart';

/// Covers the "zero-tap" auto-flow: golden-path auto-dispatch, the debounce
/// that guards it, the giant Force-Dispatch quick-accept for overweight bags,
/// the "Corrected" tag for a fixed under-weight order, and multi-bag
/// accumulation. Every test uses a single-item order with base weight 200g +
/// a 50g modifier (expected 250g, tolerance ±12.5g at the 5% default floor),
/// matching the values already proven in weigh_event_item_composition_test.

class _FakeOrderRepository extends OrderRepository {
  final List<Order> orders;
  const _FakeOrderRepository(this.orders);
  @override
  Future<List<Order>> fetchOrders() async => orders;
}

const _headOfficeSettings = HeadOfficeSettings(
  baseUrl: 'https://example.trycloudflare.com',
  deviceKey: 'dev_test_key',
);

const _menu = {
  'mi_a': MenuItem(
    id: 'mi_a',
    name: 'Toasts Duo Combo',
    baseWeightGrams: 200,
    availableModifiers: [
      Modifier(id: 'mod_sauce', name: 'Extra Chilli Sauce', weightGrams: 50),
    ],
  ),
};

// Expected weight = base(200) + modifier(50) = 250g; tolerance = max(0,
// 5%*250=12.5, 5) = 12.5g -> on-weight range [237.5, 262.5].
Order _order(String id) => Order(
      id: id,
      orderNumber: 42,
      customerName: 'Test Customer',
      readyInMinutes: 0,
      dasherInMinutes: 0,
      items: const [
        OrderItem(menuItemId: 'mi_a', selectedModifierIds: ['mod_sauce']),
      ],
    );

Future<
    ({
      ManualWeightSource source,
      http.Request? Function() captured,
    })> _pumpScreen(WidgetTester tester, String orderId) async {
  http.Request? captured;
  final client = MockClient((req) async {
    // Distinguish the actual weigh-event POST from OrdersController's own GET
    // to this same path (its recently-weighed lookup, used to reconcile
    // dispatched state) — both share a path, only the method differs.
    if (req.method == 'POST' && req.url.path.endsWith('/api/weigh-events')) {
      captured = req;
      return http.Response('{"eventId":1}', 200);
    }
    return http.Response('{}', 200);
  });

  final manualSource = ManualWeightSource();
  addTearDown(manualSource.dispose);

  tester.view.physicalSize = const Size(1024, 768);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        initialSettingsProvider.overrideWithValue(
          AppSettings.defaults().copyWith(headOffice: _headOfficeSettings),
        ),
        menuIndexProvider.overrideWithValue(_menu),
        orderRepositoryProvider.overrideWithValue(_FakeOrderRepository([_order(orderId)])),
        weightSourceProvider.overrideWithValue(manualSource),
        headOfficeApiProvider
            .overrideWithValue(HeadOfficeApi(_headOfficeSettings, client: client)),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: OrderDetailScreen(orderId: orderId),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));

  return (source: manualSource, captured: () => captured);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets(
      'golden path: an on-weight, stable reading auto-dispatches with zero '
      'taps once it settles — not before', (tester) async {
    final env = await _pumpScreen(tester, 'auto_golden');

    env.source.setGrams(250, stable: true); // base(200)+0 mod, exactly on target
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(env.captured(), isNull,
        reason: 'must not fire before the settle-hold completes');

    await tester.pump(const Duration(milliseconds: 700)); // now well past the hold
    expect(env.captured(), isNotNull,
        reason: 'golden path requires zero taps once settled');

    final body = jsonDecode(env.captured()!.body) as Map<String, dynamic>;
    expect(body['verdict'], 'onweight');
    expect(body['overrideReason'], isNull);

    await tester.pump(const Duration(milliseconds: 1100)); // drain the success flash
  });

  testWidgets(
      'debounce: changing verdict mid-hold restarts the settle window, so a '
      'bag that briefly overshoots before resting never mis-fires', (tester) async {
    final env = await _pumpScreen(tester, 'auto_debounce');

    env.source.setGrams(310, stable: true); // overshoots on the way down
    await tester.pump(const Duration(milliseconds: 300));
    env.source.setGrams(250, stable: true); // settles on-weight before over's hold completes
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(env.captured(), isNull,
        reason: 'the corrected reading needs its own full hold, not the '
            'time already spent counting down the overshoot');

    await tester.pump(const Duration(milliseconds: 700));
    expect(env.captured(), isNotNull);
    final body = jsonDecode(env.captured()!.body) as Map<String, dynamic>;
    expect(body['verdict'], 'onweight');

    await tester.pump(const Duration(milliseconds: 1100));
  });

  testWidgets(
      'overweight: never auto-dispatches, but the giant Force Dispatch button '
      'sends it in one tap with an unaudited-variance reason', (tester) async {
    final env = await _pumpScreen(tester, 'auto_over');

    env.source.setGrams(310, stable: true); // +60g over the 262.5g ceiling
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 700));
    expect(env.captured(), isNull, reason: 'overweight must never auto-dispatch');

    final forceButton = find.text('Force Dispatch');
    expect(forceButton, findsOneWidget);
    await tester.ensureVisible(forceButton);
    await tester.pump();
    await tester.tap(forceButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(env.captured(), isNotNull);
    final body = jsonDecode(env.captured()!.body) as Map<String, dynamic>;
    expect(body['verdict'], 'over');
    expect(body['overrideReason'], contains('Force dispatched'));
    expect(body['overrideReason'], contains('not audited'));

    await tester.pump(const Duration(milliseconds: 1100));
  });

  testWidgets(
      'underweight: never auto-dispatches on its own, but adding the missing '
      'weight auto-dispatches and tags the order "Corrected"', (tester) async {
    final env = await _pumpScreen(tester, 'auto_under');

    env.source.setGrams(130, stable: true); // well under the 237.5g floor
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 700));
    expect(env.captured(), isNull, reason: 'under-weight must never auto-dispatch');

    env.source.setGrams(250, stable: true); // the missing item is added back
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 700));

    expect(env.captured(), isNotNull);
    final body = jsonDecode(env.captured()!.body) as Map<String, dynamic>;
    expect(body['verdict'], 'onweight');
    expect(body['overrideReason'], contains('Corrected'));

    await tester.pump(const Duration(milliseconds: 1100));
  });

  testWidgets(
      'multi-bag: "More Bags" captures a stable reading, and the running '
      'total (not just the last bag) drives the on-weight verdict', (tester) async {
    final env = await _pumpScreen(tester, 'auto_multibag');

    // Bag 1 of 2 — well under on its own, as expected mid-sequence.
    env.source.setGrams(150, stable: true);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(env.captured(), isNull);

    final moreBags = find.text('More Bags');
    expect(moreBags, findsOneWidget);
    await tester.tap(moreBags);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Bag 1:'), findsOneWidget);

    // Bag 1 comes off the platter, bag 2 goes on.
    env.source.setGrams(0);
    await tester.pump(const Duration(milliseconds: 100));
    env.source.setGrams(100, stable: true); // 150 + 100 = 250, exactly on target
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 700));

    expect(env.captured(), isNotNull,
        reason: 'the accumulated total across both bags must drive the verdict');
    final body = jsonDecode(env.captured()!.body) as Map<String, dynamic>;
    expect(body['verdict'], 'onweight');
    expect((body['measuredG'] as num).toDouble(), closeTo(250, 0.01));
    expect(body['overrideReason'], isNull,
        reason: 'a normal multi-bag pass is not a "Corrected" under-weight fix');

    await tester.pump(const Duration(milliseconds: 1100));
  });
}
