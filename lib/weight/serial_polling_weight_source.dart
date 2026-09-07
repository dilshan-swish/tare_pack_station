import 'dart:async';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';

import '../models/weight_source_type.dart';
import 'serial_weight_source.dart';

/// For protocols that answer a request. Once the port is open we listen for
/// responses (via the base read loop) and send the poll command on a timer.
/// The 8217 Mettler-Toledo host request for weight is `W` + CR.
class SerialPollingWeightSource extends SerialWeightSource {
  SerialPollingWeightSource(super.settings);

  /// The command sent to request a reading.
  static const String pollCommand = 'W\r';

  /// How often to poll. The 8217 Mettler-Toledo (WO) host-communications spec
  /// requires "at least a 200-ms delay between commands to allow for
  /// processing data response time at the scale" — 250ms keeps a safe margin
  /// above that floor while still giving ~4 readings/sec, which reads as a
  /// continuous live update on screen rather than the noticeably stepped
  /// feel of a slower poll.
  static const Duration pollEvery = Duration(milliseconds: 250);

  Timer? _timer;

  @override
  String get statusLabel => isConnected
      ? 'Serial (polling) — connected'
      : 'Serial (polling) — no scale connected';

  @override
  WeightSourceType sourceType() => WeightSourceType.serialPolling;

  @override
  void onConnected(UsbPort port) {
    _timer?.cancel();
    _sendPoll(); // ask immediately, then on a timer
    _timer = Timer.periodic(pollEvery, (_) => _sendPoll());
  }

  @override
  void onDisconnected() {
    _timer?.cancel();
    _timer = null;
  }

  void _sendPoll() {
    try {
      port?.write(Uint8List.fromList(pollCommand.codeUnits));
    } catch (_) {
      // A transient write failure is fine — the next tick retries.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
