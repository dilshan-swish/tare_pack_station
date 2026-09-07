import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tare_pack_station/theme/app_colors.dart';
import 'package:tare_pack_station/widgets/weight_gauge.dart';

/// The bar itself is a purely visual, real-time indicator: no numbers or
/// markings on the bar, a fixed three-zone split (under / on-target / over)
/// that looks identical for every order, and a moving line whose position is
/// normalized so the on-target window always occupies exactly the middle
/// third — regardless of how wide that window actually is in grams for a
/// given order. A small caption below the bar still shows the measured/target
/// figures in text.
void main() {
  Future<void> pumpGauge(
    WidgetTester tester, {
    required double width,
    double? measured,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: WeightGauge(
              loGrams: 1271,
              hiGrams: 1325,
              idealGrams: 1295,
              measuredGrams: measured,
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets(
      'shows only the bar (no marker) plus the caption while the scale is empty',
      (tester) async {
    await pumpGauge(tester, width: 340, measured: null);

    expect(tester.takeException(), isNull);
    expect(find.text('Place a bag on the scale'), findsOneWidget);
    expect(find.text('Target 1,295g'), findsOneWidget);
    expect(find.byType(Positioned), findsOneWidget);
  });

  testWidgets('shows the marker and "Measured" once there is a reading',
      (tester) async {
    await pumpGauge(tester, width: 340, measured: 1295);

    expect(tester.takeException(), isNull);
    expect(find.text('Measured 1,295g'), findsOneWidget);
    expect(find.text('Target 1,295g'), findsOneWidget);
    expect(find.text('Place a bag on the scale'), findsNothing);
    expect(find.byType(Positioned), findsNWidgets(2));
  });

  testWidgets(
      'the on-target window always maps to exactly the middle third of the bar',
      (tester) async {
    const width = 300.0;

    Positioned marker() =>
        tester.widgetList<Positioned>(find.byType(Positioned)).last;

    // measured == loGrams -> exactly 1/3 across.
    await pumpGauge(tester, width: width, measured: 1271);
    final leftAtLo = marker().left!;
    expect(leftAtLo, closeTo((width / 3) - 8, 0.5));

    // measured == hiGrams -> exactly 2/3 across.
    await pumpGauge(tester, width: width, measured: 1325);
    final leftAtHi = marker().left!;
    expect(leftAtHi, closeTo((width * 2 / 3) - 8, 0.5));

    // measured == idealGrams (inside the window) -> strictly between the two.
    await pumpGauge(tester, width: width, measured: 1295);
    final leftAtIdeal = marker().left!;
    expect(leftAtIdeal, greaterThan(leftAtLo));
    expect(leftAtIdeal, lessThan(leftAtHi));
  });

  testWidgets('a 0g reading pins the marker to the far left', (tester) async {
    const width = 300.0;
    await pumpGauge(tester, width: width, measured: 0);

    final marker =
        tester.widgetList<Positioned>(find.byType(Positioned)).last;
    expect(tester.takeException(), isNull);
    expect(marker.left, closeTo(0.0, 0.5));
  });

  testWidgets('a far over-weight reading pins the marker to the far right',
      (tester) async {
    const width = 300.0;
    await pumpGauge(tester, width: width, measured: 100000);

    final marker =
        tester.widgetList<Positioned>(find.byType(Positioned)).last;
    expect(tester.takeException(), isNull);
    expect(marker.left, closeTo(width - 16, 0.5));
  });

  testWidgets('the gauge shape (zone split) is identical across very different orders',
      (tester) async {
    // A tight-tolerance order and a wide-tolerance order must still both
    // render as exactly three equal-width zones — the point of normalizing
    // the marker position rather than sizing zones off the raw gram window.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: WeightGauge(
              loGrams: 100,
              hiGrams: 102,
              idealGrams: 101,
              measuredGrams: null,
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: WeightGauge(
              loGrams: 500,
              hiGrams: 5000,
              idealGrams: 2750,
              measuredGrams: null,
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);

    // Only the bar's own three zones — the caption row below also has an
    // Expanded (for its status text), which isn't part of the zone split.
    final zoneFlexes = tester
        .widgetList<Expanded>(
          find.ancestor(
              of: find.byType(ColoredBox), matching: find.byType(Expanded)),
        )
        .map((e) => e.flex)
        .toList();
    expect(zoneFlexes, [1, 1, 1]);
  });

  // Every earlier test in this file only inspects the WIDGET TREE (Expanded
  // flex values, Positioned offsets) — that proves the structure is wired up
  // but not that the zones actually PAINT visible colors on screen. This test
  // renders the gauge to real pixels and reads them back, the same class of
  // check a manual screenshot would give, so a rendering-only bug (wrong
  // paint order, a clip hiding content, transparent colors, …) can't slip
  // through even though the widget tree looks correct.
  testWidgets('the three zones actually paint distinct, correct colors',
      (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: AppColors.white,
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: const SizedBox(
              width: 300,
              child: WeightGauge(
                loGrams: 100,
                hiGrams: 200,
                idealGrams: 150,
                measuredGrams: null,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
    expect(image, isNotNull);
    final byteData =
        await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
    expect(byteData, isNotNull);
    final bytes = byteData!.buffer.asUint8List();
    final stride = image!.width * 4;

    Color pixelAt(int x, int y) {
      final offset = y * stride + x * 4;
      return Color.fromARGB(
          bytes[offset + 3], bytes[offset], bytes[offset + 1], bytes[offset + 2]);
    }

    // Bar height is 20 within a 42-tall widget, bottom-aligned -> spans
    // y=[22,42]; y=32 samples comfortably inside it. x samples sit at the
    // center of each third (300px wide -> thirds are [0,100]/[100,200]/[200,300]),
    // well clear of the ink border and the rounded pill ends.
    const y = 32;
    expect(pixelAt(50, y), AppColors.coral);
    expect(pixelAt(150, y), AppColors.green);
    expect(pixelAt(250, y), AppColors.amber);
  });
}
