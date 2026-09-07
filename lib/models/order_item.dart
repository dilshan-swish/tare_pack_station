/// A single line on an order: which menu item, plus which optional modifiers
/// the customer selected.
class OrderItem {
  final String menuItemId;

  /// The item's name as Foodics' own order line reported it — independent of
  /// whether [menuItemId] resolves in the locally-synced menu index. Used
  /// only as a display fallback (e.g. a product added in Foodics but not yet
  /// pulled into head office's catalog still shows its real name instead of
  /// "Unknown item"); never affects the weight math. Null when not available
  /// (e.g. mock data, where every id already resolves locally).
  final String? menuItemName;

  final List<String> selectedModifierIds;

  /// Display names for [selectedModifierIds], keyed by id — e.g. "Curly
  /// Fries". Used only so an unweighed selection can show a specific,
  /// readable warning ("Curly Fries not weighed yet") instead of a generic
  /// one; never affects the weight math. Empty when names aren't available
  /// (e.g. mock data, where every id already resolves locally).
  final Map<String, String> selectedModifierNames;

  const OrderItem({
    required this.menuItemId,
    this.menuItemName,
    this.selectedModifierIds = const [],
    this.selectedModifierNames = const {},
  });

  Map<String, dynamic> toJson() => {
        'menuItemId': menuItemId,
        if (menuItemName != null) 'menuItemName': menuItemName,
        'selectedModifierIds': selectedModifierIds,
        if (selectedModifierNames.isNotEmpty)
          'selectedModifierNames': selectedModifierNames,
      };

  factory OrderItem.fromJson(Map<String, dynamic> json) => OrderItem(
        menuItemId: json['menuItemId'] as String,
        menuItemName: json['menuItemName'] as String?,
        selectedModifierIds: (json['selectedModifierIds'] as List<dynamic>? ??
                [])
            .map((e) => e as String)
            .toList(),
        selectedModifierNames:
            (json['selectedModifierNames'] as Map<String, dynamic>? ?? {})
                .map((k, v) => MapEntry(k, v as String)),
      );
}
