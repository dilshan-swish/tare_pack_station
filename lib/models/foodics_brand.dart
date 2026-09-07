/// A Foodics business/brand and its API access token.
///
/// Loaded from the bundled `assets/foodics/brands.json`. NOTE: that asset holds
/// live access tokens — treat it as a secret (it is git-ignored). Rotate tokens
/// by regenerating the asset from your keys file.
class FoodicsBrand {
  /// Short code, e.g. `MM`.
  final String code;

  /// Display name, e.g. `Mishmash`.
  final String name;

  /// Foodics account reference number.
  final String account;

  /// Bearer access token for this brand.
  final String token;

  const FoodicsBrand({
    required this.code,
    required this.name,
    required this.account,
    required this.token,
  });

  factory FoodicsBrand.fromJson(Map<String, dynamic> json) => FoodicsBrand(
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? (json['code'] as String? ?? 'Brand'),
        account: json['account']?.toString() ?? '',
        token: json['token'] as String? ?? '',
      );

  bool get isValid => code.isNotEmpty && token.isNotEmpty;
}

/// A branch (physical location) within a brand.
class FoodicsBranch {
  final String id;
  final String name;
  final String reference;

  const FoodicsBranch({
    required this.id,
    required this.name,
    required this.reference,
  });

  factory FoodicsBranch.fromJson(Map<String, dynamic> json) => FoodicsBranch(
        id: json['id']?.toString() ?? '',
        name: json['name'] as String? ??
            json['name_localized'] as String? ??
            'Branch',
        reference: json['reference']?.toString() ?? '',
      );
}
