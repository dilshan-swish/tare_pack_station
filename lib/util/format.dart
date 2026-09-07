import 'package:intl/intl.dart';

final _gramFmt = NumberFormat('#,##0', 'en_US');
final _gramFmt1 = NumberFormat('#,##0.#', 'en_US');
final _timeFmt = DateFormat('h:mm a', 'en_US');
final _dateFmt = DateFormat('MMM d', 'en_US');

/// Kuwait has no daylight saving, so this offset is constant year-round.
const _kuwaitOffset = Duration(hours: 3);

/// Formats grams for display, e.g. `335g` or `−15g` (a negative modifier
/// weight, e.g. "No Onion", representing weight removed rather than added —
/// uses a true minus sign, not NumberFormat's plain hyphen). Whole numbers
/// show no decimal; fractional values show one decimal place.
String formatGrams(double grams) {
  final rounded = grams.roundToDouble();
  final digits = (grams - rounded).abs() < 0.05
      ? _gramFmt.format(rounded)
      : _gramFmt1.format(grams);
  return digits.startsWith('-') ? '−${digits.substring(1)}g' : '${digits}g';
}

/// Formats a signed delta, e.g. `+100g` / `−100g` (uses a true minus sign).
String formatDelta(double grams) {
  final abs = formatGrams(grams.abs());
  if (grams > 0) return '+$abs';
  if (grams < 0) return '−$abs';
  return abs;
}

/// Converts any [DateTime] (UTC or device-local — [DateTime.toUtc] correctly
/// normalizes either) to Kuwait's wall-clock reading (UTC+3, fixed — no
/// daylight saving), independent of the device's own timezone setting.
DateTime _toKuwait(DateTime t) => t.toUtc().add(_kuwaitOffset);

/// Formats a timestamp as Kuwait local time, 12-hour clock with AM/PM — e.g.
/// `9:16 AM`. Always converts to Kuwait time explicitly rather than using
/// [DateTime.toLocal], since these are physical pack stations in Kuwait and
/// staff need Kuwait time regardless of how the tablet's own OS clock/timezone
/// happens to be configured.
String formatTimeOfDay(DateTime t) => _timeFmt.format(_toKuwait(t));

/// Formats an order's received time for display: just the time (`9:16 AM`)
/// when it falls on today in Kuwait, or with the date prefixed (`Jul 16,
/// 11:46 AM`) otherwise. Foodics orders can sit open for weeks (an abandoned
/// kiosk order, for instance) — without the date, a month-old order's receipt
/// time is indistinguishable from one just placed, which reads as a bug
/// rather than stale data.
///
/// [now] defaults to the real current time; tests pass a fixed value for
/// deterministic "is it today" checks.
String formatReceivedAt(DateTime t, {DateTime? now}) {
  final kuwaitT = _toKuwait(t);
  final kuwaitNow = _toKuwait(now ?? DateTime.now());
  final isToday = kuwaitT.year == kuwaitNow.year &&
      kuwaitT.month == kuwaitNow.month &&
      kuwaitT.day == kuwaitNow.day;
  final time = _timeFmt.format(kuwaitT);
  return isToday ? time : '${_dateFmt.format(kuwaitT)}, $time';
}
