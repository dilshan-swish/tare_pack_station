import 'weight_source_type.dart';

/// A single reading from a [WeightSource].
class WeightReading {
  final double grams;

  /// true = settled reading, false = still moving.
  final bool stable;
  final DateTime timestamp;
  final WeightSourceType source;

  const WeightReading({
    required this.grams,
    required this.stable,
    required this.timestamp,
    required this.source,
  });
}
