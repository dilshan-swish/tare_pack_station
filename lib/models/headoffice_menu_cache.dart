import '../logic/modifier_pairing.dart';
import 'menu_item.dart';

/// The last-known-good menu pulled from head office, kept on disk so the scale
/// can still weigh-check correctly the moment the app opens — before the
/// first network round trip completes, or entirely offline.
class HeadOfficeMenuCache {
  final List<MenuItem> items;

  /// Modifier-combination overrides — see ModifierCombinationWeight. Empty for a brand with
  /// none configured.
  final List<ModifierCombinationWeight> modifierCombinations;
  final int publishedVersion;

  /// Separate from [publishedVersion] — bumped by head office's automatic
  /// Foodics sync (webhook or periodic sweep) rather than an admin's
  /// deliberate "Publish" click. Comparing both is what lets a newly synced
  /// item (e.g. one just added in Foodics) reach this cache within the
  /// device's next ~20s version poll, without anyone touching the portal.
  final int menuSyncedVersion;

  final DateTime? syncedAt;

  /// This device's own brand code + registered branch's Foodics branch id —
  /// cached alongside the menu so live orders can still be fetched for the
  /// right brand/branch immediately on startup, before the next network
  /// round trip to head office completes.
  final String brandCode;
  final String? foodicsBranchId;

  /// The branch's human-readable label (e.g. "ARD-BBT"), cached so it's
  /// available for display immediately on startup too.
  final String? branchName;

  /// Foodics' own localized display name (e.g. "Yard Branch") — preferred
  /// over [branchName] wherever a person reads it.
  final String? branchNameLocalized;

  /// Foodics' daily opening/closing time ("HH:mm" strings), cached for
  /// immediate display on startup too.
  final String? branchOpeningFrom;
  final String? branchOpeningTo;

  const HeadOfficeMenuCache({
    required this.items,
    this.modifierCombinations = const [],
    required this.publishedVersion,
    this.menuSyncedVersion = 0,
    this.syncedAt,
    this.brandCode = '',
    this.foodicsBranchId,
    this.branchName,
    this.branchNameLocalized,
    this.branchOpeningFrom,
    this.branchOpeningTo,
  });
}
