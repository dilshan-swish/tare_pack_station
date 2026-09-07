/// How this smart scale reaches the head-office API (the on-prem Web API).
///
/// Set once per device on the Settings screen: the API base URL and this
/// device's own key (issued in the head-office portal when the scale is
/// registered to a branch). The key identifies which branch/device this is, so
/// no branch id is stored here.
class HeadOfficeSettings {
  /// e.g. http://10.0.0.5:5025  (the on-prem API, reachable from the store).
  final String baseUrl;

  /// The per-device key from the portal ("dev_...").
  final String deviceKey;

  const HeadOfficeSettings({this.baseUrl = '', this.deviceKey = ''});

  bool get isConnected =>
      baseUrl.trim().isNotEmpty && deviceKey.trim().isNotEmpty;

  static const HeadOfficeSettings defaults = HeadOfficeSettings();

  HeadOfficeSettings copyWith({String? baseUrl, String? deviceKey}) =>
      HeadOfficeSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        deviceKey: deviceKey ?? this.deviceKey,
      );

  Map<String, dynamic> toJson() => {'baseUrl': baseUrl, 'deviceKey': deviceKey};

  factory HeadOfficeSettings.fromJson(Map<String, dynamic> json) =>
      HeadOfficeSettings(
        baseUrl: json['baseUrl'] as String? ?? '',
        deviceKey: json['deviceKey'] as String? ?? '',
      );
}
