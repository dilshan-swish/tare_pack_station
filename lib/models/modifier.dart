/// An optional add-on for a [MenuItem], with its own weighed data. Like
/// [MenuItem] it may carry an explicit measured min/max range.
///
/// [weightGrams] is nullable: a modifier can be *linked* to an item (and so
/// worth showing, e.g. "Sprite — not weighed yet") without anyone having
/// weighed it in the portal yet. Anywhere this feeds the actual weight math
/// (expected-weight totals, the "can this order be checked" gate), a null
/// weight must be treated exactly like the modifier being absent — never as
/// zero grams.
class Modifier {
  final String id;
  final String name;
  final double? weightGrams;
  final double weightStdDev;
  final double? minWeightGrams;
  final double? maxWeightGrams;

  /// Display-only context from the Foodics catalog — the modifier GROUP this
  /// option belongs to (e.g. "Choice of Fries", reference "modbb-58") plus
  /// its own SKU and whether Foodics still has it active. None of these
  /// affect the weight math; they're purely for showing the same grouped
  /// view as the head-office portal when staff open an item on the tablet.
  final String? groupName;
  final String? groupReference;
  final String? sku;
  final bool isActive;

  const Modifier({
    required this.id,
    required this.name,
    required this.weightGrams,
    this.weightStdDev = 0,
    this.minWeightGrams,
    this.maxWeightGrams,
    this.groupName,
    this.groupReference,
    this.sku,
    this.isActive = true,
  });

  bool get hasRange =>
      minWeightGrams != null &&
      maxWeightGrams != null &&
      maxWeightGrams! >= minWeightGrams!;

  Modifier copyWith({
    String? name,
    double? weightGrams,
    double? weightStdDev,
    double? minWeightGrams,
    double? maxWeightGrams,
    String? groupName,
    String? groupReference,
    String? sku,
    bool? isActive,
    bool clearRange = false,
  }) {
    return Modifier(
      id: id,
      name: name ?? this.name,
      weightGrams: weightGrams ?? this.weightGrams,
      weightStdDev: weightStdDev ?? this.weightStdDev,
      // (weightGrams itself can't be explicitly cleared via copyWith — no
      // caller currently needs that; clearRange only applies to min/max.)
      minWeightGrams: clearRange ? null : (minWeightGrams ?? this.minWeightGrams),
      maxWeightGrams: clearRange ? null : (maxWeightGrams ?? this.maxWeightGrams),
      groupName: groupName ?? this.groupName,
      groupReference: groupReference ?? this.groupReference,
      sku: sku ?? this.sku,
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (weightGrams != null) 'weightGrams': weightGrams,
        'weightStdDev': weightStdDev,
        if (minWeightGrams != null) 'minWeightGrams': minWeightGrams,
        if (maxWeightGrams != null) 'maxWeightGrams': maxWeightGrams,
        if (groupName != null) 'groupName': groupName,
        if (groupReference != null) 'groupReference': groupReference,
        if (sku != null) 'sku': sku,
        'isActive': isActive,
      };

  factory Modifier.fromJson(Map<String, dynamic> json) => Modifier(
        id: json['id'] as String,
        name: json['name'] as String,
        weightGrams: (json['weightGrams'] as num?)?.toDouble(),
        weightStdDev: (json['weightStdDev'] as num?)?.toDouble() ?? 0,
        minWeightGrams: (json['minWeightGrams'] as num?)?.toDouble(),
        maxWeightGrams: (json['maxWeightGrams'] as num?)?.toDouble(),
        groupName: json['groupName'] as String?,
        groupReference: json['groupReference'] as String?,
        sku: json['sku'] as String?,
        isActive: json['isActive'] as bool? ?? true,
      );
}
