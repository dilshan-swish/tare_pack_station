import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tare_pack_station/data/order_repository.dart';
import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/screens/order_detail_screen.dart';
import 'package:tare_pack_station/state/headoffice_menu_controller.dart';
import 'package:tare_pack_station/state/orders_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';
import 'package:tare_pack_station/state/weight_providers.dart';
import 'package:tare_pack_station/theme/app_theme.dart';
import 'package:tare_pack_station/weight/manual_weight_source.dart';

/// Regression test for a real report: the "Likely missing" hint took ~900ms
/// to appear after a stable reading, because the UI gated it on
/// `_settledStatus` — a debounce that exists purely to protect
/// auto-dispatch and the giant Force-Dispatch button from a bag still
/// bouncing on the platter, bundled in only for implementation convenience.
/// A pure information hint that commits to nothing carries none of that
/// risk, and should reflect a stable reading immediately.
///
/// Uses the same real-world shape as the report that caught this: three
/// separate order lines (no modifiers) plus a brand-level bag-packaging
/// range, one line missing entirely.

class _FakeOrderRepository extends OrderRepository {
  final List<Order> orders;
  const _FakeOrderRepository(this.orders);
  @override
  Future<List<Order>> fetchOrders() async => orders;
}

class _FixedMenu extends HeadOfficeMenuController {
  final HeadOfficeMenuState fixed;
  _FixedMenu(this.fixed);
  @override
  HeadOfficeMenuState build() => fixed;
}

const _menu = HeadOfficeMenuState(
  items: [
    MenuItem(id: 'mi_beef', name: 'SUUUBER™ BEEF', baseWeightGrams: 240),
    MenuItem(id: 'mi_fries', name: 'Fries', baseWeightGrams: 100),
    MenuItem(id: 'mi_sauce', name: 'K&M Sauce', baseWeightGrams: 87),
  ],
  bagIdealWeightGrams: 75,
  bagMinWeightGrams: 65,
  bagMaxWeightGrams: 90,
);
// Expected = 240 + 100 + 87 + 75 (bag) = 502g.
final _order = Order(
  id: 'order_kmsauce',
  orderNumber: 250,
  customerName: 'Test Customer',
  readyInMinutes: 0,
  dasherInMinutes: 0,
  items: const [
    OrderItem(menuItemId: 'mi_beef'),
    OrderItem(menuItemId: 'mi_fries'),
    OrderItem(menuItemId: 'mi_sauce'),
  ],
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets(
      'a missing-item hint appears the instant a stable under-weight reading '
      'lands — it never waits for the ~900ms settle debounce', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final manualSource = ManualWeightSource();
    addTearDown(manualSource.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          orderRepositoryProvider.overrideWithValue(_FakeOrderRepository([_order])),
          headOfficeMenuProvider.overrideWith(() => _FixedMenu(_menu)),
          weightSourceProvider.overrideWithValue(manualSource),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const OrderDetailScreen(orderId: 'order_kmsauce'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('LIKELY MISSING'), findsNothing,
        reason: 'nothing is missing yet — no reading at all');

    // 502 (expected) − 87 (K&M Sauce) = 415 — the sauce line missing
    // entirely, exactly as reported.
    manualSource.setGrams(415, stable: true);

    // A single short pump — nowhere near the app's own 900ms settle hold —
    // is enough for the reading to reach the widget tree. If this were still
    // gated on the debounce, NOTHING below would be found yet.
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('LIKELY MISSING'), findsOneWidget,
        reason: 'must be visible well before the 900ms settle hold elapses');
    expect(find.textContaining('K&M Sauce'), findsWidgets,
        reason: 'must name the actual missing line, not just flag a gap');

    // Let the settle timer harmlessly finish out so the test doesn't leave a
    // pending Timer behind.
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets(
      'a correctly packed bag never shows the missing-item hint', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final manualSource = ManualWeightSource();
    addTearDown(manualSource.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          orderRepositoryProvider.overrideWithValue(_FakeOrderRepository([_order])),
          headOfficeMenuProvider.overrideWith(() => _FixedMenu(_menu)),
          weightSourceProvider.overrideWithValue(manualSource),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const OrderDetailScreen(orderId: 'order_kmsauce'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    manualSource.setGrams(502, stable: true); // dead on target
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('LIKELY MISSING'), findsNothing);

    // On-weight golden-path auto-dispatch fires once settled — let that (and
    // its own success-flash timer) fully play out so no Timer is left
    // pending when the test tears down.
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 1100));
  });
}
