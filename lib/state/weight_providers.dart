import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/weight_source_type.dart';
import '../weight/manual_weight_source.dart';
import '../weight/serial_polling_weight_source.dart';
import '../weight/serial_streaming_weight_source.dart';
import '../weight/serial_weight_source.dart';
import '../weight/weight_source.dart';
import 'settings_controller.dart';

/// The active [WeightSource], rebuilt whenever the selected mode or the serial
/// settings change. The previous instance is disconnected and disposed.
final weightSourceProvider = Provider<WeightSource>((ref) {
  final type = ref.watch(settingsProvider.select((s) => s.weightSourceType));
  final serial = ref.watch(settingsProvider.select((s) => s.serial));

  final WeightSource source = switch (type) {
    WeightSourceType.manual => ManualWeightSource(),
    WeightSourceType.serialStreaming => SerialStreamingWeightSource(serial),
    WeightSourceType.serialPolling => SerialPollingWeightSource(serial),
  };

  // Manual connects instantly and never throws.
  if (source is ManualWeightSource) {
    source.connect();
  } else if (source is SerialWeightSource) {
    // Auto-attempt the serial connection (fire-and-forget). Failures — no cable,
    // wrong platform — are swallowed here; the UI shows "connect a scale" and a
    // USB-attach event will open the port when the scale is plugged in.
    source.connect().catchError((Object e) {
      debugPrint('Serial auto-connect: $e');
    });
  }

  ref.onDispose(() {
    source.disconnect();
    if (source is ManualWeightSource) source.dispose();
    if (source is SerialWeightSource) source.dispose();
  });

  return source;
});
