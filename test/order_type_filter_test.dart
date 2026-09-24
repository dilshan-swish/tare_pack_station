import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tare_pack_station/data/order_repository.dart';
import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/models/foodics_order_type.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/screens/orders_queue_screen.dart';
import 'package:tare_pack_station/screens/settings_screen.dart';
import 'package:tare_pack_station/state/headoffice_controller.dart';
import 'package:tare_pack_station/state/headoffice_menu_controller.dart';
import 'package:tare_pack_station/state/orders_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';
import 'package:tare_pack_station/theme/app_theme.dart';

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

class _FixedHeartbeat extends HeadOfficeHeartbeat {
  final HeadOfficeStatus fixed;
  _FixedHeartbeat(this.fixed);
  @override
  HeadOfficeStatus build() => fixed;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  const menu = HeadOfficeMenuState(
    items: [MenuItem(id: 'mi_combo', name: 'Combo', baseWeightGrams: 500)],
  );

  final dineInOrder = Order(
    id: 'order-dinein',
    orderNumber: 20,
    customerName: 'Dine Customer',
    orderType: FoodicsOrderType.dineIn,
    readyInMinutes: 0,
    dasherInMinutes: 0,
    items: const [OrderItem(menuItemId: 'mi_combo')],
  );
  final driveThruOrder = Order(
    id: 'order-drivethru',
    orderNumber: 21,
    customerName: 'Drive Customer',
    orderType: FoodicsOrderType.driveThru,
    readyInMinutes: 0,
    dasherInMinutes: 0,
    items: const [OrderItem(menuItemId: 'mi_combo')],
  );
  final untypedOrder = Order(
    id: 'order-untyped',
    orderNumber: 22,
    customerName: 'Untyped Customer',
    readyInMinutes: 0,
    dasherInMinutes: 0,
    items: const [OrderItem(menuItemId: 'mi_combo')],
  );

  Future<void> pumpQueue(
    WidgetTester tester, {
    required List<Order> orders,
    required Set<FoodicsOrderType> enabledOrderTypes,
  }) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(
            AppSettings.defaults().copyWith(enabledOrderTypes: enabledOrderTypes),
          ),
          orderRepositoryProvider.overrideWithValue(_FakeOrderRepository(orders)),
          headOfficeMenuProvider.overrideWith(() => _FixedMenu(menu)),
          headOfficeHeartbeatProvider
              .overrideWith(() => _FixedHeartbeat(HeadOfficeStatus.notConfigured)),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: const OrdersQueueScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets(
      'disabling Drive Thru hides only the Drive Thru order — Dine In stays, '
      'and nothing crashes', (tester) async {
    await pumpQueue(
      tester,
      orders: [dineInOrder, driveThruOrder],
      enabledOrderTypes: {FoodicsOrderType.dineIn}, // Drive Thru off
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Order 20'), findsOneWidget);
    expect(find.text('Order 21'), findsNothing);
    // The hidden-count chip in the control strip should say exactly 1.
    expect(find.textContaining('1 hidden'), findsOneWidget);
  });

  testWidgets(
      'an order with no recognized type is never hidden, regardless of the '
      'filter (fail open, never a silent disappearance)', (tester) async {
    await pumpQueue(
      tester,
      orders: [driveThruOrder, untypedOrder],
      enabledOrderTypes: {}, // every real type off
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Order 21'), findsNothing, reason: 'Drive Thru is off');
    expect(find.text('Order 22'), findsOneWidget,
        reason: 'an order with no recognized type must never be hidden');
  });

  testWidgets(
      'hiding every enabled type shows the "hidden by filter" empty state, '
      'not the generic "all weighed" message', (tester) async {
    await pumpQueue(
      tester,
      orders: [dineInOrder, driveThruOrder],
      enabledOrderTypes: {}, // nothing enabled
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('hidden by your order-type filter'), findsOneWidget);
    expect(find.text('All orders have been weighed'), findsNothing);
  });

  testWidgets(
      'Settings: tapping a tile toggles it, and turning every type off shows '
      'the "everything hidden" warning', (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: const SettingsScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    // The section sits below several others in the General tab's scroll
    // view, so it needs scrolling into view before it's actually built —
    // exactly like a real person would need to scroll to reach it. Filtered
    // to the one vertical (down) Scrollable specifically: the tab row above
    // it, and every TextField's own internal EditableText, each contribute
    // their own (horizontal) Scrollable too.
    final scrollable = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    );

    // All four are on by default.
    for (final label in ['Dine In', 'Pick Up', 'Delivery', 'Drive Thru']) {
      await tester.scrollUntilVisible(find.text(label), 300, scrollable: scrollable);
      expect(find.text(label), findsOneWidget);
    }
    expect(find.textContaining('Every order type is hidden'), findsNothing);

    // Turn all four off, one tap at a time.
    for (final label in ['Dine In', 'Pick Up', 'Delivery', 'Drive Thru']) {
      await tester.scrollUntilVisible(find.text(label), 300, scrollable: scrollable);
      await tester.tap(find.text(label));
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Every order type is hidden'), findsOneWidget);

    // Turning one back on clears the warning.
    await tester.scrollUntilVisible(find.text('Dine In'), 300, scrollable: scrollable);
    await tester.tap(find.text('Dine In'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Every order type is hidden'), findsNothing);
  });
}
