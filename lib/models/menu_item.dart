import 'modifier.dart';

/// A menu item and its weighed data. In test mode "weighing" means typing a
/// number; the UI makes that explicit.
///
/// Weight acceptance can be expressed two ways:
///  • an explicit measured **range** [minWeightGrams, maxWeightGrams] with the
///    ideal packed weight in [baseWeightGrams] — used for brands that supply
///    finalized Min/Max standards (e.g. BBT), or
///  • the classic tolerance model (base ± computed tolerance from stdDev /
///    percent / absolute floors) when no range is set.
class MenuItem {
  final String id;
  final String name;

  /// The ideal packed weight in grams (also the mean used by the model).
  final double baseWeightGrams;
  final double baseWeightStdDev;
  final List<Modifier> availableModifiers;
  final double packagingWeightGrams;

  /// Optional explicit acceptance range (grams). When both are set the weight
  /// check uses [minWeightGrams, maxWeightGrams] directly instead of a
  /// computed tolerance.
  final double? minWeightGrams;
  final double? maxWeightGrams;

  /// Whether Foodics still has this item active. Purely a display concern
  /// (greyed out, "Inactive" badge) — an inactive item still needs to be
  /// visible, since it may still be sitting unweighed on an old order; the
  /// weight math itself never looks at this flag.
  final bool isActive;

  const MenuItem({
    required this.id,
    required this.name,
    required this.baseWeightGrams,
    this.baseWeightStdDev = 0,
    this.availableModifiers = const [],
    this.packagingWeightGrams = 0,
    this.minWeightGrams,
    this.maxWeightGrams,
    this.isActive = true,
  });

  /// True when an explicit measured min/max range is available.
  bool get hasRange =>
      minWeightGrams != null &&
      maxWeightGrams != null &&
      maxWeightGrams! >= minWeightGrams!;

  /// True when this item has a usable weight for the check — either an explicit
  /// Min/Max range or a base weight. Items synced from Foodics with no weight
  /// yet are *not* configured; the app warns rather than inventing a value.
  bool get isWeightConfigured => hasRange || baseWeightGrams > 0;

  MenuItem copyWith({
    String? name,
    double? baseWeightGrams,
    double? baseWeightStdDev,
    List<Modifier>? availableModifiers,
    double? packagingWeightGrams,
    double? minWeightGrams,
    double? maxWeightGrams,
    bool? isActive,
    bool clearRange = false,
  }) {
    return MenuItem(
      id: id,
      name: name ?? this.name,
      baseWeightGrams: baseWeightGrams ?? this.baseWeightGrams,
      baseWeightStdDev: baseWeightStdDev ?? this.baseWeightStdDev,
      availableModifiers: availableModifiers ?? this.availableModifiers,
      packagingWeightGrams: packagingWeightGrams ?? this.packagingWeightGrams,
      minWeightGrams: clearRange ? null : (minWeightGrams ?? this.minWeightGrams),
      maxWeightGrams: clearRange ? null : (maxWeightGrams ?? this.maxWeightGrams),
      isActive: isActive ?? this.isActive,
    );
  }

  Modifier? modifierById(String id) {
    for (final m in availableModifiers) {
      if (m.id == id) return m;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseWeightGrams': baseWeightGrams,
        'baseWeightStdDev': baseWeightStdDev,
        'availableModifiers':
            availableModifiers.map((m) => m.toJson()).toList(),
        'packagingWeightGrams': packagingWeightGrams,
        if (minWeightGrams != null) 'minWeightGrams': minWeightGrams,
        if (maxWeightGrams != null) 'maxWeightGrams': maxWeightGrams,
        'isActive': isActive,
      };

  factory MenuItem.fromJson(Map<String, dynamic> json) => MenuItem(
        id: json['id'] as String,
        name: json['name'] as String,
        baseWeightGrams: (json['baseWeightGrams'] as num).toDouble(),
        baseWeightStdDev: (json['baseWeightStdDev'] as num?)?.toDouble() ?? 0,
        availableModifiers: (json['availableModifiers'] as List<dynamic>? ?? [])
            .map((m) => Modifier.fromJson(m as Map<String, dynamic>))
            .toList(),
        packagingWeightGrams:
            (json['packagingWeightGrams'] as num?)?.toDouble() ?? 0,
        minWeightGrams: (json['minWeightGrams'] as num?)?.toDouble(),
        maxWeightGrams: (json['maxWeightGrams'] as num?)?.toDouble(),
        isActive: json['isActive'] as bool? ?? true,
      );
}
