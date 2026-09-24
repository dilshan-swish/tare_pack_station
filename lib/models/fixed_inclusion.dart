/// A component that ALWAYS ships with a [MenuItem] but that a customer never
/// picks — a ranch dip, a slaw, a sauce cup. Because nobody selects it, the
/// POS never reports it on the order, so unlike a [Modifier] it can't be
/// keyed off the order's own contents: head office declares it against the
/// item, and every order containing that item expects it.
///
/// Why this is not just folded into the item's own base weight: doing that
/// blurs the item's measured variance across two different populations (bags
/// that got the dip and bags that didn't), which widens its Min/Max band
/// until a genuinely missing dip no longer trips the under-weight check at
/// all. Kept separate, each component's weight is its own known quantity —
/// which is also what lets the discrepancy engine name the specific one that
/// is missing, rather than only reporting the order as light.
///
/// [weightGrams] is nullable for the same reason [Modifier.weightGrams] is:
/// head office can declare a component before anyone has weighed it. Until
/// then the order reads as "unconfigured" — it is never silently treated as
/// 0g, which would quietly make the expected weight too low.
class FixedInclusion {
  /// Head office's own row id (dbo.MenuItemInclusions.InclusionId). Unlike a
  /// modifier there is no Foodics id — nothing upstream knows this exists.
  final int id;
  final String name;
  final double? weightGrams;
  final double? minWeightGrams;
  final double? maxWeightGrams;

  const FixedInclusion({
    required this.id,
    required this.name,
    required this.weightGrams,
    this.minWeightGrams,
    this.maxWeightGrams,
  });

  bool get hasRange =>
      minWeightGrams != null &&
      maxWeightGrams != null &&
      maxWeightGrams! >= minWeightGrams!;

  /// True once this component has a usable weight for the check.
  bool get isWeightConfigured => weightGrams != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (weightGrams != null) 'weightGrams': weightGrams,
        if (minWeightGrams != null) 'minWeightGrams': minWeightGrams,
        if (maxWeightGrams != null) 'maxWeightGrams': maxWeightGrams,
      };

  factory FixedInclusion.fromJson(Map<String, dynamic> json) => FixedInclusion(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name'] as String,
        weightGrams: (json['weightGrams'] as num?)?.toDouble(),
        minWeightGrams: (json['minWeightGrams'] as num?)?.toDouble(),
        maxWeightGrams: (json['maxWeightGrams'] as num?)?.toDouble(),
      );
}
