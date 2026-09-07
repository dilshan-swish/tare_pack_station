import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tare_pack_station/data/order_repository.dart';
import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/logic/modifier_pairing.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/modifier.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/screens/order_detail_screen.dart';
import 'package:tare_pack_station/state/menu_index_provider.dart';
import 'package:tare_pack_station/state/orders_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';
import 'package:tare_pack_station/theme/app_theme.dart';

class _FakeOrderRepository extends OrderRepository {
  final List<Order> orders;
  const _FakeOrderRepository(this.orders);

  @override
  Future<List<Order>> fetchOrders() async => orders;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // Regression test: an item with no base weight configured yet
  // (baseWeightGrams == 0, no explicit range) plus a mix of weighed and
  // unweighed modifiers must never show a fabricated total on the receipt —
  // summing only the known parts (silently treating the missing base weight
  // as 0g, and unweighed modifiers as contributing nothing) produced a
  // specific, confident-looking number for a line that's actually still
  // missing data, contradicting the "Weight not configured" banner shown for
  // the very same order.
  testWidgets(
      'receipt line for an unconfigured item reads "not weighed", never a '
      'fabricated partial sum', (tester) async {
    const menu = {
      'mi_unweighed': MenuItem(
        id: 'mi_unweighed',
        name: 'Toasts Duo Combo',
        baseWeightGrams: 0,
        availableModifiers: [
          Modifier(
              id: 'mod_fries_seasoning',
              name: 'Chilli Lime',
              weightGrams: 5),
          Modifier(
              id: 'mod_tenders_seasoning', name: 'Chilli Lime', weightGrams: null),
          Modifier(id: 'mod_drink', name: 'Arwa Water', weightGrams: 330),
          Modifier(
              id: 'mod_fries', name: 'Not So Curly Fries', weightGrams: null),
        ],
      ),
    };
    final order = Order(
      id: 'order_test_1',
      orderNumber: 100,
      customerName: 'Test Customer',
      readyInMinutes: 0,
      dasherInMinutes: 0,
      items: const [
        OrderItem(
          menuItemId: 'mi_unweighed',
          selectedModifierIds: [
            'mod_fries_seasoning',
            'mod_tenders_seasoning',
            'mod_drink',
            'mod_fries',
          ],
        ),
      ],
    );

    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          menuIndexProvider.overrideWithValue(menu),
          orderRepositoryProvider
              .overrideWithValue(_FakeOrderRepository([order])),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const OrderDetailScreen(orderId: 'order_test_1'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    expect(find.text('not weighed'), findsWidgets);
    expect(find.text('335g'), findsNothing);
  });

  // Regression test for a real report: the receipt used to show a combined
  // line total (item + every modifier summed) beside the item name, which
  // read as ambiguous ("is 1,295g the item alone, or a total?"). Per explicit
  // follow-up feedback, the number beside the item name must be the item's
  // OWN weight only — each modifier already shows its own weight on its own
  // line below, and the combined order total is shown once, prominently, in
  // the MEASURED/EXPECTED panel instead of being duplicated here.
  testWidgets(
      'a fully-weighed item shows its OWN weight beside its name, never a '
      'combined line total', (tester) async {
    const menu = {
      'mi_weighed': MenuItem(
        id: 'mi_weighed',
        name: 'Toasts Duo Combo',
        baseWeightGrams: 805,
        minWeightGrams: 795,
        maxWeightGrams: 815,
        availableModifiers: [
          Modifier(id: 'mod_fries_seasoning', name: 'Chilli Lime', weightGrams: 5),
          Modifier(id: 'mod_tenders_seasoning', name: 'Chilli Lime', weightGrams: 5),
          Modifier(id: 'mod_drink', name: 'Arwa Water', weightGrams: 330),
          Modifier(id: 'mod_fries', name: 'Not So Curly Fries', weightGrams: 150),
        ],
      ),
    };
    final order = Order(
      id: 'order_test_2',
      orderNumber: 100,
      customerName: 'Test Customer',
      readyInMinutes: 0,
      dasherInMinutes: 0,
      items: const [
        OrderItem(
          menuItemId: 'mi_weighed',
          selectedModifierIds: [
            'mod_fries_seasoning',
            'mod_tenders_seasoning',
            'mod_drink',
            'mod_fries',
          ],
        ),
      ],
    );

    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          menuIndexProvider.overrideWithValue(menu),
          orderRepositoryProvider
              .overrideWithValue(_FakeOrderRepository([order])),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const OrderDetailScreen(orderId: 'order_test_2'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    // The item's own weight (805g) shows beside its name — never the summed
    // line total (805 + 5 + 5 + 330 + 150 = 1,295g), which must not appear.
    expect(find.text('805g'), findsOneWidget);
    expect(find.text('1,295g'), findsNothing);
    expect(find.text('Item weight'), findsNothing);
    expect(find.text('not weighed'), findsNothing);
  });

  // Regression test for a real report: a modifier's receipt line showed its
  // unrelated standalone default (e.g. "French Fries 200g") even when a
  // combo-size choice on the SAME line overrode it to a different real weight
  // (147g for Medium) — the number shown didn't match what was actually
  // counted toward the order's own expected/target weight above it.
  testWidgets(
      'a modifier line shows its combination-overridden weight, not its '
      'unrelated standalone default', (tester) async {
    const menu = {
      'mi_combo_meal': MenuItem(
        id: 'mi_combo_meal',
        name: 'Smokey Rolls Beef Meal',
        baseWeightGrams: 702,
        minWeightGrams: 693,
        maxWeightGrams: 710,
        availableModifiers: [
          // Deliberately no weight of its own — a combo-size chip is a label,
          // not a physical component (same real case as MEDIUM on BBT's menu).
          Modifier(id: 'mod_medium', name: 'MEDIUM', weightGrams: null),
          Modifier(id: 'mod_french_fries', name: 'French Fries', weightGrams: 200),
          Modifier(id: 'mod_salt', name: 'Salt', weightGrams: 2),
        ],
      ),
    };
    final combinationIndex = ModifierCombinationIndex([
      ModifierCombinationWeight(
        modifierIds: const ['mod_medium', 'mod_french_fries'],
        weightG: 147,
        anchorModifierId: 'mod_medium',
      ),
    ]);
    final order = Order(
      id: 'order_test_3',
      orderNumber: 100,
      customerName: 'Test Customer',
      readyInMinutes: 0,
      dasherInMinutes: 0,
      items: const [
        OrderItem(
          menuItemId: 'mi_combo_meal',
          selectedModifierIds: ['mod_medium', 'mod_french_fries', 'mod_salt'],
        ),
      ],
    );

    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          menuIndexProvider.overrideWithValue(menu),
          modifierCombinationIndexProvider.overrideWithValue(combinationIndex),
          orderRepositoryProvider
              .overrideWithValue(_FakeOrderRepository([order])),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const OrderDetailScreen(orderId: 'order_test_3'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    // The combination-overridden weight (147g) shows, labelled with which
    // combo-size choice it's conditioned on — never the unrelated 200g
    // standalone default.
    expect(find.textContaining('French Fries'), findsOneWidget);
    expect(find.text('147g'), findsOneWidget);
    expect(find.text('200g'), findsNothing);
    // MEDIUM still gets its own row (nothing selected silently disappears),
    // even though it has no weight of its own and wasn't directly claimed.
    expect(find.text('MEDIUM'), findsOneWidget);
    expect(find.text('Salt'), findsOneWidget);
    expect(find.text('2g'), findsOneWidget);
  });
}
