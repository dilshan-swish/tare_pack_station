import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/modifier.dart';
import 'package:tare_pack_station/screens/settings_screen.dart';
import 'package:tare_pack_station/state/headoffice_menu_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';
import 'package:tare_pack_station/theme/app_theme.dart';

class _FixedMenuController extends HeadOfficeMenuController {
  final HeadOfficeMenuState fixture;
  _FixedMenuController(this.fixture);

  @override
  HeadOfficeMenuState build() => fixture;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  // Regression test for a real report: an item's own ideal/range weight was
  // configured in the portal (805g ideal, 795-815g range) and the Menu item
  // weights list correctly showed it as configured — but an order using one
  // of its still-unweighed modifiers was correctly blocked from a weight
  // check, which read as a bug ("it shows weighed here but not there") until
  // traced to incomplete modifier coverage. The list must surface that gap
  // directly instead of only after staff hit a blocked order.
  testWidgets(
      'an item with its own weight set but incomplete modifiers shows '
      '"Modifiers incomplete" and a weighed-count subtitle', (tester) async {
    const item = MenuItem(
      id: 'mi_204',
      name: 'Toasts Duo Combo',
      baseWeightGrams: 805,
      minWeightGrams: 795,
      maxWeightGrams: 815,
      availableModifiers: [
        Modifier(id: 'm1', name: 'Chilli Lime', weightGrams: 5),
        Modifier(id: 'm2', name: 'Arwa Water', weightGrams: 330),
        Modifier(id: 'm3', name: 'Not So Curly Fries', weightGrams: null),
        Modifier(id: 'm4', name: 'Salt', weightGrams: null),
      ],
    );
    final fixture = HeadOfficeMenuState(
      items: const [item],
      publishedVersion: 6,
      brandCode: 'BBT',
    );

    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          headOfficeMenuProvider
              .overrideWith(() => _FixedMenuController(fixture)),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: const SettingsScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Menu item weights'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text('Modifiers incomplete'), findsOneWidget);
    expect(find.textContaining('2 of 4 modifiers weighed'), findsOneWidget);
    // The item itself IS configured, so it must not also show "No weight".
    expect(find.text('No weight'), findsNothing);
  });
}
