/// Foodics' own order `type` enum (documented at apidocs.foodics.com — the
/// Orders resource), reused as-is rather than inventing a parallel scheme:
/// 1=Dine In, 2=Pick Up, 3=Delivery, 4=Drive Thru. Kept as a real enum (not a
/// raw int) so every place that needs to display or filter by it agrees on
/// the same four values and labels, instead of each call site re-deriving
/// its own switch statement that could quietly drift out of sync.
enum FoodicsOrderType {
  dineIn(1, 'Dine In'),
  pickUp(2, 'Pick Up'),
  delivery(3, 'Delivery'),
  driveThru(4, 'Drive Thru');

  const FoodicsOrderType(this.code, this.label);

  /// The exact integer Foodics sends in the order's `type` field.
  final int code;

  /// The label shown in Settings and used as a display-name fallback.
  final String label;

  /// Maps a raw Foodics `type` value to the matching enum member, or null for
  /// an absent/unrecognized value (a brand-new order type Foodics adds later,
  /// or a source that doesn't set one at all) — callers must treat null as
  /// "unknown", never guess a default, so an order is never silently
  /// mis-filtered by a code this app hasn't been taught about yet.
  static FoodicsOrderType? fromCode(int? code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}
