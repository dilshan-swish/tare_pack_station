import '../models/weight_source_type.dart';
import 'serial_weight_source.dart';

/// For scale protocols that push data continuously without being polled.
///
/// None of the protocols in the Ariva's own protocol guide actually work this
/// way — 8217/8213 Mettler-Toledo, NCI, EPOS 1/2, Dialog 06/04/02, ICL,
/// Berkel, IP3 and CAS are all host-initiated (a `W`, `ENQ`, or `DC1` command
/// must be sent before the scale replies). This mode exists for other scale
/// hardware that genuinely has a continuous-output mode; the base read loop
/// parses each frame as it arrives, no polling needed — but selecting it
/// against an Ariva configured with any of the protocols above will simply
/// never receive a reading, since the scale never speaks first.
class SerialStreamingWeightSource extends SerialWeightSource {
  SerialStreamingWeightSource(super.settings);

  @override
  String get statusLabel => isConnected
      ? 'Serial (streaming) — connected'
      : 'Serial (streaming) — no scale connected';

  @override
  WeightSourceType sourceType() => WeightSourceType.serialStreaming;
}
