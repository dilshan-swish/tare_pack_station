import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/util/format.dart';

void main() {
  group('formatGrams', () {
    test('whole positive number shows no decimal', () {
      expect(formatGrams(335), '335g');
    });

    test('fractional number shows one decimal place', () {
      expect(formatGrams(335.7), '335.7g');
    });

    test('negative weight uses a true minus sign, not a hyphen', () {
      // A "No Onion"/"No Cheese" modifier's configured weight is negative —
      // it represents weight removed from the item, not added. The display
      // must use the same true-minus glyph as formatDelta, not
      // NumberFormat's plain hyphen.
      expect(formatGrams(-15), '−15g');
      expect(formatGrams(-15).contains('-'), isFalse);
    });

    test('negative fractional weight also uses a true minus sign', () {
      expect(formatGrams(-15.4), '−15.4g');
    });

    test('zero formats without a sign', () {
      expect(formatGrams(0), '0g');
    });
  });

  group('formatDelta', () {
    test('positive delta is prefixed with +', () {
      expect(formatDelta(100), '+100g');
    });

    test('negative delta uses a true minus sign', () {
      expect(formatDelta(-100), '−100g');
    });

    test('zero delta has no sign', () {
      expect(formatDelta(0), '0g');
    });
  });

  group('formatTimeOfDay', () {
    test('converts UTC to Kuwait time (UTC+3) in 12-hour AM/PM format', () {
      // 07:07 UTC -> 10:07 Kuwait.
      final utc = DateTime.utc(2026, 8, 11, 7, 7);
      expect(formatTimeOfDay(utc), '10:07 AM');
    });

    test('rolls over past midnight into the next Kuwait-local day', () {
      // 22:30 UTC -> 01:30 Kuwait (next day), 12-hour clock shows 1:30 AM.
      final utc = DateTime.utc(2026, 8, 11, 22, 30);
      expect(formatTimeOfDay(utc), '1:30 AM');
    });

    test('correctly shows PM for a Kuwait-afternoon instant', () {
      // 11:15 UTC -> 14:15 Kuwait -> 2:15 PM.
      final utc = DateTime.utc(2026, 8, 11, 11, 15);
      expect(formatTimeOfDay(utc), '2:15 PM');
    });

    test('is independent of the device/local timezone, not just UTC input', () {
      // A device-local (non-UTC) DateTime representing the same real instant
      // as 07:07 UTC, but expressed with an arbitrary local offset — toUtc()
      // must correctly normalize it before adding the Kuwait offset.
      final localEquivalent =
          DateTime.utc(2026, 8, 11, 7, 7).toLocal();
      expect(formatTimeOfDay(localEquivalent), '10:07 AM');
    });
  });

  group('formatReceivedAt', () {
    // Fixed "now": 2026-08-11 10:52 Kuwait local == 07:52 UTC.
    final fixedNowUtc = DateTime.utc(2026, 8, 11, 7, 52);

    test('same Kuwait-local day as now -> time only, no date', () {
      // 07:52 UTC == 10:52 AM Kuwait, same calendar day as "now".
      final t = DateTime.utc(2026, 8, 11, 7, 52);
      expect(formatReceivedAt(t, now: fixedNowUtc), '10:52 AM');
    });

    test('a stale order from weeks earlier gets the date prefixed', () {
      // The exact real-world case: opened 2026-07-16, 08:46:14 UTC
      // -> 11:46:14 AM Kuwait, nowhere near "now" (2026-08-11).
      final t = DateTime.utc(2026, 7, 16, 8, 46, 14);
      expect(formatReceivedAt(t, now: fixedNowUtc), 'Jul 16, 11:46 AM');
    });

    test('yesterday in Kuwait-local terms is NOT "today", even if <24h ago',
        () {
      // "now" is 10:52 AM Kuwait on Aug 11. An order from 1:00 AM Kuwait on
      // Aug 11 is today; one from 11:00 PM Kuwait on Aug 10 is *not* — even
      // though it's less than 24 hours before "now" — because the date
      // shown must reflect the Kuwait calendar day, not a rolling window.
      final earlierTodayKuwait = DateTime.utc(2026, 8, 10, 22, 0); // 1 AM Kuwait, Aug 11
      expect(formatReceivedAt(earlierTodayKuwait, now: fixedNowUtc),
          isNot(contains(',')));

      final lateYesterdayKuwait = DateTime.utc(2026, 8, 10, 20, 0); // 11 PM Kuwait, Aug 10
      expect(
          formatReceivedAt(lateYesterdayKuwait, now: fixedNowUtc), 'Aug 10, 11:00 PM');
    });

    test('a moment in the future relative to now still formats correctly',
        () {
      // Not expected in practice, but must never throw or misbehave — e.g. a
      // clock-skewed device. Same-day-as-now still means time-only.
      final laterToday = DateTime.utc(2026, 8, 11, 8, 30); // 11:30 AM Kuwait
      expect(formatReceivedAt(laterToday, now: fixedNowUtc), '11:30 AM');
    });

    test('defaults "now" to the real current time when not provided', () {
      expect(() => formatReceivedAt(DateTime.now()), returnsNormally);
    });
  });
}
