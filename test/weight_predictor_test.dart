import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/ai/weight_predictor.dart';

void main() {
  // The model is an optional enhancement layered on top of an always-working
  // statistical formula — a corrupt/garbage file must never crash the app,
  // it must just leave the predictor unavailable so the caller falls back.
  test('garbage bytes fail to load, leaving the predictor unavailable',
      () {
    final predictor = WeightPredictor();
    final ok = predictor.loadFromBytes(
        Uint8List.fromList(List<int>.generate(64, (i) => i)));

    expect(ok, isFalse);
    expect(predictor.isAvailable, isFalse);
  });

  test('predicting with no model loaded returns null, never throws', () {
    final predictor = WeightPredictor();
    final result = predictor.predict([1, 2, 3, 4, 5, 6]);
    expect(result, isNull);
  });

  test('predicting with the wrong feature count returns null, never throws',
      () {
    final predictor = WeightPredictor();
    // Even with no model loaded, a caller passing the wrong shape must not
    // crash — this exercises the same guard that protects a real model too.
    expect(predictor.predict([1, 2, 3]), isNull);
    expect(predictor.predict(List.filled(10, 0.0)), isNull);
  });

  test('dispose is safe to call even when nothing was ever loaded', () {
    final predictor = WeightPredictor();
    expect(() => predictor.dispose(), returnsNormally);
    expect(predictor.isAvailable, isFalse);
  });
}
