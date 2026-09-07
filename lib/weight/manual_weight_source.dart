import 'dart:async';

import '../models/weight_reading.dart';
import '../models/weight_source_type.dart';
import 'weight_source.dart';

/// The only [WeightSource] wired up today. A number typed into the UI is
/// pushed through [setGrams]; the app consumes it exactly like a real scale
/// reading. Clearly labelled "TEST MODE" in the UI.
class ManualWeightSource implements WeightSource {
  final _controller = StreamController<WeightReading>.broadcast();
  bool _connected = false;
  double _grams = 0;
  bool _stable = true;

  @override
  Stream<WeightReading> get readings => _controller.stream;

  @override
  bool get isConnected => _connected;

  @override
  String get statusLabel => 'TEST MODE — manual entry';

  @override
  Future<void> connect() async {
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  /// Called by the UI whenever the operator changes the typed weight or toggles
  /// the "stable reading" switch. Emits a fresh [WeightReading].
  void setGrams(double grams, {bool stable = true}) {
    _grams = grams;
    _stable = stable;
    _emit();
  }

  /// Toggle only the stability flag, keeping the current grams.
  void setStable(bool stable) {
    _stable = stable;
    _emit();
  }

  double get grams => _grams;
  bool get stable => _stable;

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(
      WeightReading(
        grams: _grams,
        stable: _stable,
        // Timestamp is informational; the manual source is driven by the UI.
        timestamp: DateTime.now(),
        source: WeightSourceType.manual,
      ),
    );
  }

  void dispose() {
    _controller.close();
  }
}
