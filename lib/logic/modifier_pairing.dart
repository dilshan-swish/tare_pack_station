import '../models/menu_item.dart';

/// The combined weight for 2-4 modifiers selected together on the same order
/// line, when it isn't simply the sum of each one's own weight. Real case
/// that motivated this: a combo-SIZE choice ("Medium") can affect BOTH the
/// fries-type portion AND the drink-type portion at once — a genuine 3-way
/// interaction (size x fries-type x drink-type) that a 2-only design can't
/// represent without silently resolving only one of the two pairings.
/// Confirmed against BBT's real menu: the Regular->Medium fries delta ranges
/// from +15g to +32g depending on which fries were picked — no single
/// per-modifier weight can capture that with plain addition, and the same is
/// true of the drink portion. A combination with no override anywhere just
/// isn't looked up — [resolveSelectedModifiers] falls back to summing each
/// modifier's own weight, exactly as it always has.
class ModifierCombinationWeight {
  final List<String> modifierIds;
  final double weightG;
  final double? minWeightG;
  final double? maxWeightG;

  /// When set, one of [modifierIds] (exactly 2 members) is "context only" —
  /// its own standalone weight is added normally, untouched (e.g. a
  /// combo-size chip, typically 0g since it's a label, not a physical
  /// component) — so [weightG] replaces only the OTHER member's own weight.
  /// Null keeps the older behavior: [weightG] replaces the sum of both
  /// members' own weights. Because the anchor's own weight is never
  /// touched, the same anchor value can be shared across several
  /// independent dependent-group overrides (fries, drinks, ...) applied to
  /// the same line at once, with no double-counting — see
  /// [resolveSelectedModifiers].
  final String? anchorModifierId;

  ModifierCombinationWeight({
    required this.modifierIds,
    required this.weightG,
    this.minWeightG,
    this.maxWeightG,
    this.anchorModifierId,
  }) : assert(modifierIds.length >= 2 && modifierIds.length <= 4,
            'a combination needs 2-4 modifiers'),
       assert(modifierIds.toSet().length == modifierIds.length,
            'a combination cannot repeat the same modifier'),
       assert(anchorModifierId == null ||
            (modifierIds.length == 2 && modifierIds.contains(anchorModifierId)),
            'an anchor can only be set for a two-modifier combination, and must be one of its members');

  bool get hasRange =>
      minWeightG != null && maxWeightG != null && maxWeightG! >= minWeightG!;

  /// The other member of an anchored pair — the one whose own weight
  /// [weightG] replaces. Only meaningful when [anchorModifierId] is set.
  String get dependentModifierId =>
      modifierIds.firstWhere((id) => id != anchorModifierId);

  Map<String, dynamic> toJson() => {
        'modifierIds': modifierIds,
        'weightG': weightG,
        if (minWeightG != null) 'minWeightG': minWeightG,
        if (maxWeightG != null) 'maxWeightG': maxWeightG,
        if (anchorModifierId != null) 'anchorModifierId': anchorModifierId,
      };

  factory ModifierCombinationWeight.fromJson(Map<String, dynamic> json) =>
      ModifierCombinationWeight(
        modifierIds: (json['modifierIds'] as List<dynamic>).map((e) => e as String).toList(),
        weightG: (json['weightG'] as num).toDouble(),
        minWeightG: (json['minWeightG'] as num?)?.toDouble(),
        maxWeightG: (json['maxWeightG'] as num?)?.toDouble(),
        anchorModifierId: json['anchorModifierId'] as String?,
      );
}

/// Every configured combination for the active brand, ready to be matched
/// against a line's actual selections. Sorted largest-first once, at
/// construction, so [resolveSelectedModifiers] can simply try candidates in
/// order — a combination covering more modifiers is always more specific
/// (and so preferred) than one covering fewer.
class ModifierCombinationIndex {
  final List<ModifierCombinationWeight> _plainBySize;
  final List<ModifierCombinationWeight> _anchored;

  ModifierCombinationIndex(List<ModifierCombinationWeight> combinations)
      : _plainBySize = [...combinations.where((c) => c.anchorModifierId == null)]
          ..sort((a, b) => b.modifierIds.length.compareTo(a.modifierIds.length)),
        _anchored = combinations.where((c) => c.anchorModifierId != null).toList();

  /// No combinations configured — every line falls back to plain addition.
  /// The safe default before head office has ever published one, and while
  /// offline.
  static final ModifierCombinationIndex empty = ModifierCombinationIndex(const []);

  bool get isEmpty => _plainBySize.isEmpty && _anchored.isEmpty;

  /// Symmetric (non-anchored) combinations whose every member id is present
  /// in [availableIds], largest first — a match fully replaces the sum of
  /// ALL its members' own weights, so its members can never overlap with
  /// another applied combination.
  Iterable<ModifierCombinationWeight> plainCandidatesFor(Set<String> availableIds) =>
      _plainBySize.where((c) => c.modifierIds.every(availableIds.contains));

  /// Anchored pairs whose anchor AND dependent are both present in
  /// [availableIds] — a match replaces only the dependent's own weight, so
  /// its anchor may still be shared by other anchored pairs applying to the
  /// same line (see [resolveSelectedModifiers]).
  Iterable<ModifierCombinationWeight> anchoredCandidatesFor(Set<String> availableIds) =>
      _anchored.where((c) => c.modifierIds.every(availableIds.contains));
}

/// One resolved weighable contribution from a line's selected modifiers —
/// either a single modifier's own weight (the normal case), 2-4 modifiers
/// fused into one slot because a symmetric [ModifierCombinationWeight]
/// matched all of them, or one dependent modifier whose own weight was
/// replaced by an anchored pair (ids holds only the dependent in that case —
/// the anchor's own weight is resolved separately, see
/// [resolveSelectedModifiers]).
class ResolvedModifierSlot {
  final String label;
  final List<String> ids;
  final double weightG;
  final double weightStdDev;
  final double? minWeightG;
  final double? maxWeightG;
  final bool isOverride;

  const ResolvedModifierSlot({
    required this.label,
    required this.ids,
    required this.weightG,
    this.weightStdDev = 0,
    this.minWeightG,
    this.maxWeightG,
    this.isOverride = false,
  });

  bool get hasRange =>
      minWeightG != null && maxWeightG != null && maxWeightG! >= minWeightG!;

  /// True when this slot represents a combination override (symmetric or
  /// anchored) rather than a single modifier's own standalone weight.
  bool get isCombination => isOverride;
}

/// Turns one order line's selected modifier ids into resolved weight slots,
/// folding in any combination override so every modifier it covers
/// contributes the right combined slot instead of being added independently
/// (which would double up, or use the wrong number, whenever their combined
/// weight isn't simply the sum of each one's own — see
/// [ModifierCombinationWeight]).
///
/// Resolution runs in two passes:
///
/// 1. Symmetric combinations, largest first (most specific evidence wins),
///    fully claiming every id they cover — a smaller combination, an
///    anchored pair, or a plain individual weight can never also apply to an
///    id a bigger symmetric match already covers.
/// 2. Anchored pairs: each replaces only its DEPENDENT member's own weight,
///    so its ANCHOR is never claimed by this pass and remains free for as
///    many other anchored pairs as apply (e.g. a combo-size choice
///    independently overriding both the fries portion and the drink
///    portion) — the anchor's own weight (typically 0 for a size label)
///    still gets added exactly once via the plain per-modifier fallback
///    below, never doubled just because several dependents key off it.
///
/// A selected modifier with no configured weight (linked but not yet
/// weighed) contributes nothing at either stage, unchanged from before
/// combinations existed — this only ever changes what modifiers that are
/// ALL already weighed contribute together.
List<ResolvedModifierSlot> resolveSelectedModifiers(
  MenuItem menuItem,
  List<String> selectedModifierIds,
  ModifierCombinationIndex combinationIndex,
) {
  final slots = <ResolvedModifierSlot>[];
  if (selectedModifierIds.isEmpty) return slots;

  final available = selectedModifierIds.toSet();
  final claimed = <String>{};

  if (!combinationIndex.isEmpty) {
    // Pass 1: symmetric combinations — greedy, largest first. A candidate is
    // claimed only if none of its ids were already claimed by an earlier
    // (necessarily >= as big) one.
    for (final combo in combinationIndex.plainCandidatesFor(available)) {
      if (combo.modifierIds.any(claimed.contains)) continue;
      claimed.addAll(combo.modifierIds);
      final names = combo.modifierIds.map((id) => menuItem.modifierById(id)?.name ?? id);
      slots.add(ResolvedModifierSlot(
        label: names.join(' + '),
        ids: combo.modifierIds,
        weightG: combo.weightG,
        minWeightG: combo.minWeightG,
        maxWeightG: combo.maxWeightG,
        isOverride: true,
      ));
    }

    // Pass 2: anchored pairs — the anchor is deliberately never added to
    // `claimed`, so it stays available to every other anchored pair that
    // applies to this same line.
    for (final combo in combinationIndex.anchoredCandidatesFor(available)) {
      final dependentId = combo.dependentModifierId;
      if (claimed.contains(dependentId)) continue;
      claimed.add(dependentId);
      final anchorName = menuItem.modifierById(combo.anchorModifierId!)?.name ?? combo.anchorModifierId!;
      final dependentName = menuItem.modifierById(dependentId)?.name ?? dependentId;
      slots.add(ResolvedModifierSlot(
        label: '$dependentName ($anchorName)',
        ids: [dependentId],
        weightG: combo.weightG,
        minWeightG: combo.minWeightG,
        maxWeightG: combo.maxWeightG,
        isOverride: true,
      ));
    }
  }

  for (final id in selectedModifierIds) {
    if (claimed.contains(id)) continue;
    final mod = menuItem.modifierById(id);
    // Linked-but-not-yet-weighed (or unlinked) — contributes nothing, exactly
    // as before combinations existed; never treated as 0g.
    if (mod?.weightGrams == null) continue;
    slots.add(ResolvedModifierSlot(
      label: mod!.name,
      ids: [id],
      weightG: mod.weightGrams!,
      weightStdDev: mod.weightStdDev,
      minWeightG: mod.hasRange ? mod.minWeightGrams : null,
      maxWeightG: mod.hasRange ? mod.maxWeightGrams : null,
    ));
  }
  return slots;
}

/// Which of [selectedModifierIds] have NEITHER their own configured weight
/// NOR are resolved together by a combination override — i.e. genuinely
/// still unconfigured. A modifier that's only ever meant to be used together
/// with others (e.g. a combo-size choice whose own weight is deliberately
/// left unset because it only makes sense combined with a fries + drink
/// choice) is NOT flagged here as long as its combination partners are also
/// selected and the combination itself has a weight — see
/// findUnconfiguredWeightMessages.
Set<String> unresolvedModifierIds(
  MenuItem menuItem,
  List<String> selectedModifierIds,
  ModifierCombinationIndex combinationIndex,
) {
  final claimed = _claimedIds(selectedModifierIds, combinationIndex);
  final unresolved = <String>{};
  for (final id in selectedModifierIds) {
    if (claimed.contains(id)) continue;
    if (menuItem.modifierById(id)?.weightGrams == null) unresolved.add(id);
  }
  return unresolved;
}

/// Every id [resolveSelectedModifiers] would account for through some
/// combination — shared so [unresolvedModifierIds] never has to duplicate
/// (and risk drifting from) the matching logic. Deliberately broader than
/// resolution's own internal weight-summing "claimed" set: an anchor (e.g. a
/// combo-size choice) is included here even though its own weight is never
/// added by an anchored match (see [resolveSelectedModifiers]) — its own
/// weight is *legitimately* left unconfigured when it only ever makes sense
/// combined with a dependent choice, so it must not be flagged as missing.
Set<String> _claimedIds(
  List<String> selectedModifierIds,
  ModifierCombinationIndex combinationIndex,
) {
  final accountedFor = <String>{};
  if (combinationIndex.isEmpty) return accountedFor;
  final available = selectedModifierIds.toSet();

  final symmetricClaimed = <String>{};
  for (final combo in combinationIndex.plainCandidatesFor(available)) {
    if (combo.modifierIds.any(symmetricClaimed.contains)) continue;
    symmetricClaimed.addAll(combo.modifierIds);
  }
  accountedFor.addAll(symmetricClaimed);

  for (final combo in combinationIndex.anchoredCandidatesFor(available)) {
    final dependentId = combo.dependentModifierId;
    if (accountedFor.contains(dependentId)) continue;
    accountedFor.add(dependentId);
    accountedFor.add(combo.anchorModifierId!);
  }
  return accountedFor;
}
