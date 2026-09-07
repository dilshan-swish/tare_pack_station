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
import 'package:tare_pack_station/screens/orders_queue_screen.dart';
import 'package:tare_pack_station/state/headoffice_controller.dart';
import 'package:tare_pack_station/state/headoffice_menu_controller.dart';
import 'package:tare_pack_station/state/orders_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';
import 'package:tare_pack_station/theme/app_colors.dart';
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

  // Lets staff tell, right from the queue, whether an order can actually be
  // weight-checked yet — a thin green border means every item/modifier on it
  // already has a configured weight; amber means at least one doesn't, so
  // opening it would just show "Weight not configured" instead of a real
  // check.
  testWidgets(
      'a fully-weighed order\'s card gets a thin green border, an order with '
      'an unconfigured item gets amber — never the other way around',
      (tester) async {
    const menu = HeadOfficeMenuState(
      items: [
        MenuItem(id: 'mi_ready', name: 'Ready Combo', baseWeightGrams: 500),
        MenuItem(id: 'mi_gap', name: 'Unweighed Combo', baseWeightGrams: 0),
      ],
    );

    final readyOrder = Order(
      id: 'order-ready',
      orderNumber: 10,
      customerName: 'Ready Customer',
      readyInMinutes: 0,
      dasherInMinutes: 0,
      items: const [OrderItem(menuItemId: 'mi_ready')],
    );
    final gapOrder = Order(
      id: 'order-gap',
      orderNumber: 11,
      customerName: 'Gap Customer',
      readyInMinutes: 0,
      dasherInMinutes: 0,
      items: const [OrderItem(menuItemId: 'mi_gap')],
    );

    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          orderRepositoryProvider
              .overrideWithValue(_FakeOrderRepository([readyOrder, gapOrder])),
          headOfficeMenuProvider.overrideWith(() => _FixedMenu(menu)),
          headOfficeHeartbeatProvider
              .overrideWith(() => _FixedHeartbeat(HeadOfficeStatus.notConfigured)),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: const OrdersQueueScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);

    Color borderColorFor(String titleText) {
      final decoratedBox = tester.widget<DecoratedBox>(
        find.ancestor(
          of: find.text(titleText),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = decoratedBox.decoration as BoxDecoration;
      return decoration.border!.top.color;
    }

    expect(borderColorFor('Order 10'), AppColors.green,
        reason: 'every item on this order has a configured weight');
    expect(borderColorFor('Order 11'), AppColors.amber,
        reason: 'this order has an item with no weight configured yet');
  });
}
