/// Serial-port configuration that maps directly onto a scale's own setup menu.
/// Stored so it is ready the moment hardware is connected.
class SerialSettings {
  final int baudRate;
  final String parity; // None / Even / Odd
  final int dataBits; // 7 or 8
  final int stopBits; // 1 or 2
  final String protocolName; // e.g. "8217 Mettler-Toledo"

  const SerialSettings({
    this.baudRate = 9600,
    this.parity = 'Even',
    this.dataBits = 7,
    this.stopBits = 1,
    this.protocolName = '8217 Mettler-Toledo',
  });

  static const SerialSettings defaults = SerialSettings();

  static const List<int> baudOptions = [1200, 2400, 4800, 9600, 19200, 38400];
  static const List<String> parityOptions = ['None', 'Even', 'Odd'];
  static const List<int> dataBitOptions = [7, 8];
  static const List<int> stopBitOptions = [1, 2];

  SerialSettings copyWith({
    int? baudRate,
    String? parity,
    int? dataBits,
    int? stopBits,
    String? protocolName,
  }) {
    return SerialSettings(
      baudRate: baudRate ?? this.baudRate,
      parity: parity ?? this.parity,
      dataBits: dataBits ?? this.dataBits,
      stopBits: stopBits ?? this.stopBits,
      protocolName: protocolName ?? this.protocolName,
    );
  }

  String get summary =>
      '$baudRate / $parity / $dataBits / $stopBits · $protocolName';

  Map<String, dynamic> toJson() => {
        'baudRate': baudRate,
        'parity': parity,
        'dataBits': dataBits,
        'stopBits': stopBits,
        'protocolName': protocolName,
      };

  factory SerialSettings.fromJson(Map<String, dynamic> json) => SerialSettings(
        baudRate: (json['baudRate'] as num?)?.toInt() ?? 9600,
        parity: json['parity'] as String? ?? 'Even',
        dataBits: (json['dataBits'] as num?)?.toInt() ?? 7,
        stopBits: (json['stopBits'] as num?)?.toInt() ?? 1,
        protocolName: json['protocolName'] as String? ?? '8217 Mettler-Toledo',
      );
}
