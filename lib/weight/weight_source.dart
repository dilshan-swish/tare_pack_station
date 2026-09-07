import '../models/weight_reading.dart';

/// A swappable source of weight readings. Today only [ManualWeightSource] is
/// wired up, but the whole app talks to this interface so that plugging in a
/// real scale later is a one-file change, not a rewrite.
abstract class WeightSource {
  /// Continuous stream of readings. Latest value is what the UI displays.
  Stream<WeightReading> get readings;

  /// Open the underlying transport (serial port, etc.). No-op for manual.
  Future<void> connect();

  /// Close the transport and release resources.
  Future<void> disconnect();

  /// Whether the source is currently connected/usable.
  bool get isConnected;

  /// Human-readable one-line status for the UI.
  String get statusLabel;
}
