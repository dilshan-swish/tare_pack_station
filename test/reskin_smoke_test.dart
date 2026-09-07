import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/screens/order_detail_screen.dart';
import 'package:tare_pack_station/screens/orders_queue_screen.dart';
import 'package:tare_pack_station/screens/settings_screen.dart';
import 'package:tare_pack_station/state/settings_controller.dart';
import 'package:tare_pack_station/theme/app_theme.dart';

/// Renders the re-skinned screens at common sizes and fails on ANY layout
/// overflow or build exception. Runs in the Dart test VM, so it does not need
/// the (currently policy-blocked) shader compiler.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false; // no network in tests
  });

  Widget wrap(Widget home) => ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: home),
      );

  Future<void> renderAt(
    WidgetTester tester,
    Widget home,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(wrap(home));
    await tester.pump(const Duration(milliseconds: 600)); // mock repo latency
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  }

  const tabletLandscape = Size(1024, 768);
  const tabletPortrait = Size(768, 1024);
  const phone = Size(390, 844);

  testWidgets('queue renders on tablet landscape', (t) async {
    await renderAt(t, const OrdersQueueScreen(), tabletLandscape);
  });

  testWidgets('queue renders on phone', (t) async {
    await renderAt(t, const OrdersQueueScreen(), phone);
  });

  testWidgets('order detail renders on tablet landscape', (t) async {
    await renderAt(
        t, const OrderDetailScreen(orderId: '8712318'), tabletLandscape);
  });

  testWidgets('order detail renders on tablet portrait', (t) async {
    await renderAt(
        t, const OrderDetailScreen(orderId: '8712318'), tabletPortrait);
  });

  testWidgets('order detail renders on phone', (t) async {
    await renderAt(t, const OrderDetailScreen(orderId: '8712318'), phone);
  });

  testWidgets('settings renders on tablet landscape', (t) async {
    await renderAt(t, const SettingsScreen(), tabletLandscape);
  });

  testWidgets('settings renders on tablet portrait', (t) async {
    await renderAt(t, const SettingsScreen(), tabletPortrait);
  });

  testWidgets('settings renders on phone', (t) async {
    await renderAt(t, const SettingsScreen(), phone);
  });

  testWidgets('switching to the Menu item weights tab renders cleanly',
      (t) async {
    await renderAt(t, const SettingsScreen(), tabletLandscape);
    await t.tap(find.text('Menu item weights'));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);
  });
}
