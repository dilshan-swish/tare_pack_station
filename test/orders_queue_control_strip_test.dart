import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tare_pack_station/data/order_repository.dart';
import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/screens/orders_queue_screen.dart';
import 'package:tare_pack_station/state/headoffice_controller.dart';
import 'package:tare_pack_station/state/headoffice_menu_controller.dart';
import 'package:tare_pack_station/state/orders_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';
import 'package:tare_pack_station/theme/app_theme.dart';

class _CountingOrderRepository extends OrderRepository {
  int fetchCount = 0;
  @override
  Future<List<Order>> fetchOrders() async {
    fetchCount++;
    return const [];
  }
}

/// Skips the real timer/network setup the base controller does in `build()`
/// — this test only needs a fixed, already-resolved status/menu state.
class _FixedHeartbeat extends HeadOfficeHeartbeat {
  final HeadOfficeStatus fixed;
  _FixedHeartbeat(this.fixed);
  @override
  HeadOfficeStatus build() => fixed;
}

class _FixedMenu extends HeadOfficeMenuController {
  final HeadOfficeMenuState fixed;
  _FixedMenu(this.fixed);
  @override
  HeadOfficeMenuState build() => fixed;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> pumpAt(WidgetTester tester, Widget widget, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(widget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  const tabletLandscape = Size(1024, 768);
  const phone = Size(390, 844);

  testWidgets(
      'not configured: no HQ/branch/Sync Menu chips, but the Kuwait clock '
      'always shows, on both tablet and phone widths', (tester) async {
    for (final size in [tabletLandscape, phone]) {
      await pumpAt(
        tester,
        ProviderScope(
          overrides: [
            initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
            headOfficeHeartbeatProvider
                .overrideWith(() => _FixedHeartbeat(HeadOfficeStatus.notConfigured)),
            headOfficeMenuProvider.overrideWith(() => _FixedMenu(const HeadOfficeMenuState())),
          ],
          child: MaterialApp(theme: buildAppTheme(), home: const OrdersQueueScreen()),
        ),
        size,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('HQ'), findsNothing);
      expect(find.byIcon(Icons.restart_alt), findsNothing);
      expect(find.textContaining('KWT'), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
    }
  });

  testWidgets(
      'configured: shows a real branch label (never a raw id), HQ status, '
      'and a Sync Menu icon button, with no overflow at phone width',
      (tester) async {
    const menuState = HeadOfficeMenuState(
      brandCode: 'BBT',
      branchName: 'ARD-BBT',
      foodicsBranchId: 'b042368a-12b1-4e94-8566-6109e6f8fb04',
    );

    for (final size in [tabletLandscape, phone]) {
      await pumpAt(
        tester,
        ProviderScope(
          overrides: [
            initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
            headOfficeHeartbeatProvider
                .overrideWith(() => _FixedHeartbeat(HeadOfficeStatus.online)),
            headOfficeMenuProvider.overrideWith(() => _FixedMenu(menuState)),
          ],
          child: MaterialApp(theme: buildAppTheme(), home: const OrdersQueueScreen()),
        ),
        size,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('HQ'), findsOneWidget);
      expect(find.text('BBT · ARD-BBT'), findsOneWidget);
      expect(find.textContaining('b042368a'), findsNothing);
      // "Sync Menu" is now an icon-only button (no label text) to keep the
      // strip compact — a widget it should stay, but not with text anymore.
      expect(find.text('Sync Menu'), findsNothing);
      expect(find.byIcon(Icons.restart_alt), findsOneWidget);
      expect(find.textContaining('KWT'), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
    }
  });

  testWidgets(
      'branch chip prefers the Foodics localized name over the plain branch '
      'name', (tester) async {
    const withLocalized = HeadOfficeMenuState(
      brandCode: 'BBT',
      branchName: 'ARD-BBT',
      branchNameLocalized: 'Ardiya Branch',
      foodicsBranchId: 'b042368a-12b1-4e94-8566-6109e6f8fb04',
    );

    await pumpAt(
      tester,
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          headOfficeHeartbeatProvider
              .overrideWith(() => _FixedHeartbeat(HeadOfficeStatus.online)),
          headOfficeMenuProvider.overrideWith(() => _FixedMenu(withLocalized)),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: const OrdersQueueScreen()),
      ),
      tabletLandscape,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('BBT · Ardiya Branch'), findsOneWidget);
    expect(find.text('BBT · ARD-BBT'), findsNothing);
  });

  testWidgets('tapping the "synced" status chip triggers an immediate sync',
      (tester) async {
    final repo = _CountingOrderRepository();

    tester.view.physicalSize = tabletLandscape;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          orderRepositoryProvider.overrideWithValue(repo),
          headOfficeHeartbeatProvider
              .overrideWith(() => _FixedHeartbeat(HeadOfficeStatus.notConfigured)),
          headOfficeMenuProvider.overrideWith(() => _FixedMenu(const HeadOfficeMenuState())),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: const OrdersQueueScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    final before = repo.fetchCount;
    // No dedicated "Sync now" button anymore — the status chip itself is
    // the trigger. Match by icon since the exact "synced Xs ago" text is
    // time-dependent.
    final chip = find.ancestor(
      of: find.byIcon(Icons.check_circle_outline),
      matching: find.byType(InkWell),
    );
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(repo.fetchCount, greaterThan(before));
  });

  // Regression test for a real report: on a real tablet, the strip
  // intermittently rendered as several lines with one chip stranded, oddly
  // centered, between them — even though it structurally reflows as a plain
  // left-aligned Wrap. Verified here with an empty order list (so no card
  // icons collide with the strip's own icons) across the range of realistic
  // tablet widths: every chip must share one exact row (same vertical
  // center), and — separately, at a width deliberately too narrow to fit —
  // any wrapped-to-a-new-line chip must still start flush at the row's own
  // left edge, never centered.
  Future<void> pumpConnectedEmpty(WidgetTester tester, Size size) async {
    const menuState = HeadOfficeMenuState(
      brandCode: 'BBT',
      branchName: 'ARD-BBT',
      foodicsBranchId: 'foodics-branch-id',
    );
    await pumpAt(
      tester,
      ProviderScope(
        overrides: [
          initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
          orderRepositoryProvider.overrideWithValue(_CountingOrderRepository()),
          headOfficeHeartbeatProvider
              .overrideWith(() => _FixedHeartbeat(HeadOfficeStatus.online)),
          headOfficeMenuProvider.overrideWith(() => _FixedMenu(menuState)),
        ],
        child: MaterialApp(theme: buildAppTheme(), home: const OrdersQueueScreen()),
      ),
      size,
    );
  }

  List<double> stripIconCentersY(WidgetTester tester) => [
        tester.getCenter(find.byIcon(Icons.local_fire_department)).dy,
        tester.getCenter(find.byIcon(Icons.verified)).dy,
        tester.getCenter(find.byIcon(Icons.cloud_done)).dy,
        tester.getCenter(find.byIcon(Icons.check_circle_outline)).dy,
        tester.getCenter(find.byIcon(Icons.schedule)).dy,
        tester.getCenter(find.byIcon(Icons.restart_alt)).dy,
        tester.getCenter(find.byIcon(Icons.storefront)).dy,
      ];

  testWidgets(
      'every strip chip shares one line at realistic (and generously wide) '
      'tablet widths — the exact regression that was reported', (tester) async {
    // 1024 is the documented primary tablet target; 1280 and a very wide
    // desktop-class width are included because the actual bug (one chip
    // measuring itself as needing almost the whole row) reproduced even at
    // widths with enormous amounts of room to spare, so "plenty of width"
    // alone would not have caught it.
    for (final width in [1024.0, 1280.0, 1600.0]) {
      await pumpConnectedEmpty(tester, Size(width, 768));
      expect(tester.takeException(), isNull);

      final centersY = stripIconCentersY(tester);
      final reference = centersY.first;
      for (final y in centersY) {
        expect(y, closeTo(reference, 1.0),
            reason: 'at width $width, every chip should sit on the same '
                'line as the streak chip');
      }
    }
  });

  testWidgets(
      'no chip ever measures itself as needing anywhere near the full row '
      'width (the actual root cause: Center without widthFactor ballooning '
      'inside Wrap)', (tester) async {
    // Wide enough that nothing should legitimately need to wrap at all.
    await pumpConnectedEmpty(tester, const Size(1600, 800));
    expect(tester.takeException(), isNull);

    final wrapWidth = tester.getSize(find.byType(Wrap)).width;
    final tappableChipWidth =
        tester.getSize(find.byIcon(Icons.check_circle_outline)).width;
    // The real content is well under 200px; the bug made it balloon to
    // nearly the entire wrap width (over 1000px in the width this reproduced
    // at). A generous 300px ceiling catches the regression without being
    // sensitive to minor styling tweaks.
    expect(tappableChipWidth, lessThan(300));
    expect(tappableChipWidth, lessThan(wrapWidth * 0.3));
  });

  testWidgets(
      'when it genuinely does not fit, every wrapped line starts flush at '
      'the row\'s own left edge — never centered as a stray island',
      (tester) async {
    // Narrow enough that the 7-item strip cannot possibly fit on one line.
    await pumpConnectedEmpty(tester, const Size(430, 800));
    expect(tester.takeException(), isNull);

    final leftEdge = tester.getTopLeft(find.byIcon(Icons.local_fire_department)).dx;
    final centersY = stripIconCentersY(tester);
    final xs = [
      tester.getTopLeft(find.byIcon(Icons.local_fire_department)).dx,
      tester.getTopLeft(find.byIcon(Icons.verified)).dx,
      tester.getTopLeft(find.byIcon(Icons.cloud_done)).dx,
      tester.getTopLeft(find.byIcon(Icons.check_circle_outline)).dx,
      tester.getTopLeft(find.byIcon(Icons.schedule)).dx,
      tester.getTopLeft(find.byIcon(Icons.restart_alt)).dx,
      tester.getTopLeft(find.byIcon(Icons.storefront)).dx,
    ];

    // Group by (rounded) line, then confirm every line's leftmost item is
    // flush with the row's left edge — proving each line is left-aligned,
    // not centered, regardless of exactly which items end up sharing a line.
    final byLine = <int, List<double>>{};
    for (var i = 0; i < centersY.length; i++) {
      final line = centersY[i].round();
      byLine.putIfAbsent(line, () => []).add(xs[i]);
    }
    expect(byLine.length, greaterThan(1),
        reason: 'this width must actually force at least one wrap for the '
            'test to be meaningful');
    for (final entry in byLine.entries) {
      final lineLeftmost = entry.value.reduce((a, b) => a < b ? a : b);
      // A generous tolerance: different chip/button types have slightly
      // different icon-to-container-edge padding (a Chip's 15px icon with
      // 10px padding vs. NeoIconButton's 20px icon centered in a 46px
      // circle), so their ICONS won't land at the exact same x even when
      // both containers start flush-left. The original bug's offset was in
      // the hundreds of pixels — nowhere close to being masked by this.
      expect(lineLeftmost, closeTo(leftEdge, 12.0),
          reason: 'line at y=${entry.key} must start flush at the left '
              'edge, not centered');
    }
  });
}
