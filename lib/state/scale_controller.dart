import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/weight_reading.dart';
import '../models/weight_source_type.dart';
import '../weight/manual_weight_source.dart';
import '../weight/weight_source.dart';
import 'weight_providers.dart';

/// The single, station-wide measured weight — "what is currently on the scale".
///
/// There is one physical scale at the pack station, so the measured weight is a
/// shared value rather than a per-order field. This provider subscribes to the
/// active [WeightSource] and holds its latest reading; the queue and the order
/// detail screen both watch it, so every order's on/under/over verdict updates
/// in realtime as the weight on the scale changes.
final scaleReadingProvider =
    NotifierProvider<ScaleController, WeightReading?>(ScaleController.new);

class ScaleController extends Notifier<WeightReading?> {
  @override
  WeightReading? build() {
    final source = ref.watch(weightSourceProvider);

    final sub = source.readings.listen(
      (reading) => state = reading,
      // A stream error must never take down the app; surface as "no reading".
      onError: (Object _) => state = null,
    );
    ref.onDispose(sub.cancel);

    // Seed synchronously so late subscribers (broadcast streams don't buffer)
    // still see the current value. Manual starts at whatever it holds (0g).
    if (source is ManualWeightSource) {
      return WeightReading(
        grams: source.grams,
        stable: source.stable,
        timestamp: DateTime.now(),
        source: WeightSourceType.manual,
      );
    }
    return null;
  }
}

/// The current measured weight in grams if a bag is on the scale, else null.
/// A reading of 0g (or negative) is treated as an empty scale so orders show a
/// neutral "waiting" state rather than a spurious "under weight".
final scaleGramsProvider = Provider<double?>((ref) {
  final reading = ref.watch(scaleReadingProvider);
  if (reading == null || reading.grams <= 0) return null;
  return reading.grams;
});

/// Clears the scale back to empty (0g). Used by "Re-weigh order".
void resetScale(WidgetRef ref) {
  final source = ref.read(weightSourceProvider);
  if (source is ManualWeightSource) source.setGrams(0);
}
