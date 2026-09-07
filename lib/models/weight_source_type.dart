/// Which kind of [WeightSource] is providing readings.
enum WeightSourceType {
  /// Manual numeric entry — the stand-in used while there is no scale.
  manual,

  /// A scale that pushes readings on its own, without being polled. None of
  /// the Ariva's own documented protocols (including 8217/8213 Mettler-Toledo)
  /// actually work this way — they're all host-initiated. This mode is kept
  /// for other hardware that genuinely streams continuously.
  serialStreaming,

  /// A scale that answers a poll command (send `W\r`, read one response).
  serialPolling,
}

extension WeightSourceTypeX on WeightSourceType {
  String get label => switch (this) {
        WeightSourceType.manual => 'Manual (test)',
        WeightSourceType.serialStreaming => 'Serial — Streaming',
        WeightSourceType.serialPolling => 'Serial — Polling',
      };

  bool get isSerial => this != WeightSourceType.manual;

  String get storageKey => name;

  static WeightSourceType fromStorage(String? value) {
    return WeightSourceType.values.firstWhere(
      (t) => t.name == value,
      orElse: () => WeightSourceType.manual,
    );
  }
}
