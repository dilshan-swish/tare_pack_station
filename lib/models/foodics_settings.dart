/// Configuration for the Foodics POS integration.
///
/// The access token is NOT stored here — it is resolved from the selected
/// [brandCode] against the bundled brand list (`assets/foodics/brands.json`).
/// This keeps one rotatable source of secrets and lets staff switch brands
/// without pasting tokens.
///
/// While [enabled] is false (or no brand/branch is chosen) the app uses the
/// built-in sample orders, so nothing breaks before Foodics is wired up.
class FoodicsSettings {
  /// Turn the live integration on. When off, mock orders are used.
  final bool enabled;

  /// API base, e.g. `https://api.foodics.com/v5`.
  final String baseUrl;

  /// Selected brand code (e.g. `MM`). Resolves to a token in the brand list.
  final String brandCode;

  /// Selected branch id (the pack-station location) whose orders to fetch.
  final String branchId;

  /// Cached branch name for display (optional).
  final String branchName;

  /// How often to poll for new orders, in seconds (realtime feel).
  final int pollSeconds;

  const FoodicsSettings({
    this.enabled = false,
    this.baseUrl = 'https://api.foodics.com/v5',
    this.brandCode = '',
    this.branchId = '',
    this.branchName = '',
    this.pollSeconds = 10,
  });

  static const FoodicsSettings defaults = FoodicsSettings();

  /// The integration can only run when a brand and branch are chosen.
  bool get isConfigured => brandCode.isNotEmpty && branchId.isNotEmpty;

  /// True when the app should actually hit Foodics instead of the mock.
  bool get isLive => enabled && isConfigured;

  /// Poll interval clamped to a sane range (Foodics allows 90 req/min).
  Duration get pollInterval => Duration(seconds: pollSeconds.clamp(5, 120));

  String get summary {
    if (!enabled) return 'Disabled — using sample orders';
    if (brandCode.isEmpty) return 'Enabled — choose a brand';
    if (branchId.isEmpty) return 'Enabled — choose a branch';
    return 'Live — $brandCode · ${branchName.isEmpty ? branchId : branchName} '
        '· every ${pollInterval.inSeconds}s';
  }

  FoodicsSettings copyWith({
    bool? enabled,
    String? baseUrl,
    String? brandCode,
    String? branchId,
    String? branchName,
    int? pollSeconds,
  }) {
    return FoodicsSettings(
      enabled: enabled ?? this.enabled,
      baseUrl: baseUrl ?? this.baseUrl,
      brandCode: brandCode ?? this.brandCode,
      branchId: branchId ?? this.branchId,
      branchName: branchName ?? this.branchName,
      pollSeconds: pollSeconds ?? this.pollSeconds,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'baseUrl': baseUrl,
        'brandCode': brandCode,
        'branchId': branchId,
        'branchName': branchName,
        'pollSeconds': pollSeconds,
      };

  factory FoodicsSettings.fromJson(Map<String, dynamic> json) =>
      FoodicsSettings(
        enabled: json['enabled'] as bool? ?? false,
        baseUrl: json['baseUrl'] as String? ?? defaults.baseUrl,
        brandCode: json['brandCode'] as String? ?? '',
        branchId: json['branchId'] as String? ?? '',
        branchName: json['branchName'] as String? ?? '',
        pollSeconds: (json['pollSeconds'] as num?)?.toInt() ?? 10,
      );
}
