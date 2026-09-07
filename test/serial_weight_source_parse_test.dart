import 'package:flutter_test/flutter_test.dart';

import 'package:tare_pack_station/models/serial_settings.dart';
import 'package:tare_pack_station/models/weight_reading.dart';
import 'package:tare_pack_station/models/weight_source_type.dart';
import 'package:tare_pack_station/weight/serial_polling_weight_source.dart';

/// Exposes the protected `parseFrame` for direct testing. A subclass of the
/// class that declares it — this is the normal way to unit-test a
/// `@protected` member without weakening its visibility for real callers.
class _TestSerialSource extends SerialPollingWeightSource {
  _TestSerialSource() : super(SerialSettings.defaults);
  WeightReading? parse(String raw) => parseFrame(raw);
}

void main() {
  late _TestSerialSource source;

  setUp(() {
    source = _TestSerialSource();
  });

  // The 8217 Mettler-Toledo (WO) protocol has no in-band unit for a plain
  // gross-weight response — a decimal value is the scale's metric default
  // (kilograms), matching the Ariva's factory configuration.
  test('a plain decimal frame is read as kilograms', () {
    final reading = source.parse('\x02 0.250\r');
    expect(reading, isNotNull);
    expect(reading!.grams, closeTo(250, 0.001));
    expect(reading.source, WeightSourceType.serialPolling);
  });

  test('a net-weight frame (trailing N) still parses the weight', () {
    final reading = source.parse('\x020.250N\r');
    expect(reading!.grams, closeTo(250, 0.001));
  });

  test('an explicit "kg" unit is honored', () {
    final reading = source.parse('\x02 1.500kg\r');
    expect(reading!.grams, closeTo(1500, 0.001));
  });

  test('an explicit "lb" unit converts to grams', () {
    final reading = source.parse('\x02 1.00lb\r');
    expect(reading!.grams, closeTo(453.59237, 0.001));
  });

  test('a bare integer with a "g" unit is read as-is (not x1000)', () {
    final reading = source.parse('\x02 250g\r');
    expect(reading!.grams, closeTo(250, 0.001));
  });

  // Regression coverage for the actual bug this fixes: a status-byte-only
  // response ("scale in motion" / over-under capacity / negative weight / no
  // change since last poll) is a single arbitrary byte that can coincidentally
  // render as a printable digit. Before this fix, that digit was misread as a
  // real weight — e.g. showing "3g" on screen while the scale was actually
  // still settling, over capacity, or reporting negative weight.
  test('a status-byte-only response ("?" + a digit-looking byte) is not '
      'mistaken for a weight reading', () {
    final reading = source.parse('\x02?3\r');
    expect(reading, isNull,
        reason: 'this is a status byte (e.g. "scale in motion"), not a '
            'weight — even though the byte happens to render as a digit');
  });

  test('a status-byte-only response with a non-digit byte is also rejected',
      () {
    final reading = source.parse('\x02?A\r');
    expect(reading, isNull);
  });

  test('an empty or purely-control frame yields no reading', () {
    expect(source.parse('\x02\x03'), isNull);
    expect(source.parse(''), isNull);
  });

  test('a frame with no digits at all yields no reading', () {
    expect(source.parse('\x02OPOS\x03'), isNull);
  });

  // A garbled/absurd value (bad frame, line noise) must never be shown as a
  // real weight — the exception-handling spec calls for rejecting >50kg on
  // manual entry, and this generic parser applies the same sanity floor.
  test('an absurdly large value is rejected rather than shown', () {
    final reading = source.parse('\x02 999999\r');
    expect(reading, isNull);
  });
}
