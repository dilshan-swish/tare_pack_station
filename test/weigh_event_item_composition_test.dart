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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // Regression coverage for the weighed-orders CSV export: the export is only
  // as good as the composition data captured at dispatch time, so this proves
  // the actual HTTP payload sent to head office includes the order's item and
  // modifier ids/names — not just the aggregate expected/measured numbers
  // that were already being sent.
  testWidgets(
      'confirming a weigh sends the order\'s item/modifier composition to '
      'head office, not just the aggregate weight', (tester) async {
    const menu = {
      'mi_a': MenuItem(
        id: 'mi_a',
        name: 'Toasts Duo Combo',
        baseWeightGrams: 200,
        availableModifiers: [
          Modifier(id: 'mod_sauce', name: 'Extra Chilli Sauce', weightGrams: 50),
        ],
      ),
    };
    final order = Order(
      id: 'order_composition_test',
      orderNumber: 42,
      customerName: 'Test Customer',
      readyInMinutes: 0,
      dasherInMinutes: 0,
      items: const [
        OrderItem(menuItemId: 'mi_a', selectedModifierIds: ['mod_sauce']),
      ],
    );

    http.Request? captured;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/weigh-events')) {
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
          menuIndexProvider.overrideWithValue(menu),
          orderRepositoryProvider.overrideWithValue(_FakeOrderRepository([order])),
          weightSourceProvider.overrideWithValue(manualSource),
          headOfficeApiProvider
              .overrideWithValue(HeadOfficeApi(_headOfficeSettings, client: client)),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const OrderDetailScreen(orderId: 'order_composition_test'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    // 250g exactly matches base(200) + modifier(50) — comfortably on-weight
    // under any tolerance floor, so "Confirm & send" becomes enabled.
    manualSource.setGrams(250, stable: true);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);

    final confirmButton = find.text('Confirm & send');
    expect(confirmButton, findsOneWidget);
    await tester.tap(confirmButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    // Dispatch now shows a brief full-screen success flash before
    // auto-returning home (see _completeDispatch's _successFlashDuration) —
    // drain that timer so the test doesn't end with one still pending.
    await tester.pump(const Duration(milliseconds: 1100));

    expect(tester.takeException(), isNull);
    expect(captured, isNotNull,
        reason: 'dispatching must POST a weigh event to head office');

    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['verdict'], 'onweight');
    expect(body['orderLabel'], 'Order 42',
        reason: 'the portal must show a short label, never the raw order id');
    final items = body['items'] as List<dynamic>?;
    expect(items, isNotNull, reason: 'composition must be included');
    expect(items, hasLength(1));
    final item = items!.single as Map<String, dynamic>;
    expect(item['menuItemId'], 'mi_a');
    expect(item['name'], 'Toasts Duo Combo');
    final modifiers = item['modifiers'] as List<dynamic>;
    expect(modifiers, hasLength(1));
    final modifier = modifiers.single as Map<String, dynamic>;
    expect(modifier['modifierId'], 'mod_sauce');
    expect(modifier['name'], 'Extra Chilli Sauce');
  });

  // Regression coverage for the portal's order-breakdown modal: it can only
  // say exactly which item/modifier blocked the check if the tablet actually
  // sends that detail — this proves an order with a real unconfigured
  // modifier reports it by name in the weigh-event payload, not just the bare
  // "unconfigured" verdict with no explanation.
  testWidgets(
      'an order with an unweighed modifier reports which item/modifier by '
      'name, not just an unexplained "unconfigured" verdict', (tester) async {
    const menu = {
      'mi_b': MenuItem(
        id: 'mi_b',
        name: 'Fillaa on Toast Duo Combo',
        baseWeightGrams: 200,
        availableModifiers: [
          Modifier(id: 'mod_chilli', name: 'Chilli Lime', weightGrams: null),
        ],
      ),
    };
    final order = Order(
      id: 'order_unconfigured_test',
      orderNumber: 113,
      customerName: 'Test Customer',
      readyInMinutes: 0,
      dasherInMinutes: 0,
      items: const [
        OrderItem(menuItemId: 'mi_b', selectedModifierIds: ['mod_chilli']),
      ],
    );

    http.Request? captured;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/weigh-events')) {
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
          menuIndexProvider.overrideWithValue(menu),
          orderRepositoryProvider.overrideWithValue(_FakeOrderRepository([order])),
          weightSourceProvider.overrideWithValue(manualSource),
          headOfficeApiProvider
              .overrideWithValue(HeadOfficeApi(_headOfficeSettings, client: client)),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const OrderDetailScreen(orderId: 'order_unconfigured_test'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    manualSource.setGrams(250, stable: true);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);

    // An unconfigured order still lets staff confirm & send it manually
    // (see the reweigh/manual-check banner) — the button reads "Confirm &
    // send" the same as a fully-configured one either way.
    final confirmButton = find.text('Confirm & send');
    expect(confirmButton, findsOneWidget);
    await tester.tap(confirmButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    // Dispatch now shows a brief full-screen success flash before
    // auto-returning home (see _completeDispatch's _successFlashDuration) —
    // drain that timer so the test doesn't end with one still pending.
    await tester.pump(const Duration(milliseconds: 1100));

    expect(tester.takeException(), isNull);
    expect(captured, isNotNull);

    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['verdict'], 'unconfigured');
    final reasons = body['unconfiguredReasons'] as List<dynamic>?;
    expect(reasons, isNotNull,
        reason: 'head office needs to know WHICH item/modifier blocked the check');
    expect(reasons, hasLength(1));
    expect(reasons!.single, 'Fillaa on Toast Duo Combo: Chilli Lime not weighed yet');
  });

  // Regression coverage for a real bug: a product added in Foodics but not
  // yet pulled into head office's catalog (a sync gap) resolved to nothing in
  // menuIndex, so the screen showed a bare "Unknown item" AND silently
  // dropped the item's whole line from the receipt — even though the order's
  // own data (from Foodics) knows its real name. This proves the order's own
  // reported name is used everywhere instead: the receipt still shows the
  // line, the on-screen unconfigured chip names the item, and the reported
  // reason/composition sent to head office does too.
  testWidgets(
      'an item missing from the synced menu still shows its real name — '
      'never a bare "Unknown item" — using the order\'s own reported name',
      (tester) async {
    const menu = <String, MenuItem>{}; // Nothing synced yet for this brand.
    final order = Order(
      id: 'order_unsynced_item_test',
      orderNumber: 106,
      customerName: 'Test Customer',
      readyInMinutes: 0,
      dasherInMinutes: 0,
      items: const [
        OrderItem(menuItemId: 'prod_old_skool', menuItemName: 'Old Skool Deal'),
      ],
    );

    http.Request? captured;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/api/weigh-events')) {
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
          menuIndexProvider.overrideWithValue(menu),
          orderRepositoryProvider.overrideWithValue(_FakeOrderRepository([order])),
          weightSourceProvider.overrideWithValue(manualSource),
          headOfficeApiProvider
              .overrideWithValue(HeadOfficeApi(_headOfficeSettings, client: client)),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const OrderDetailScreen(orderId: 'order_unsynced_item_test'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    expect(find.text('Unknown item'), findsNothing,
        reason: 'a real name is known — the bare fallback must not show');
    // The receipt's own line for this item (not silently dropped).
    expect(find.textContaining('Old Skool Deal'), findsWidgets);
    // The unconfigured banner's chip, naming the specific missing item.
    expect(find.text('Old Skool Deal (not in synced menu yet)'), findsOneWidget);

    manualSource.setGrams(250, stable: true);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    final confirmButton = find.text('Confirm & send');
    expect(confirmButton, findsOneWidget);
    await tester.tap(confirmButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    // Dispatch now shows a brief full-screen success flash before
    // auto-returning home (see _completeDispatch's _successFlashDuration) —
    // drain that timer so the test doesn't end with one still pending.
    await tester.pump(const Duration(milliseconds: 1100));

    expect(tester.takeException(), isNull);
    expect(captured, isNotNull);

    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['verdict'], 'unconfigured');
    final reasons = body['unconfiguredReasons'] as List<dynamic>?;
    expect(reasons, isNotNull);
    expect(reasons!.single, 'Old Skool Deal (not in synced menu yet)');
    final items = body['items'] as List<dynamic>?;
    expect(items, hasLength(1));
    final item = items!.single as Map<String, dynamic>;
    expect(item['menuItemId'], 'prod_old_skool');
    expect(item['name'], 'Old Skool Deal',
        reason: 'the order\'s own reported name must reach head office too');
  });
}
