import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/modifier_pairing.dart';
import '../models/menu_item.dart';
import 'headoffice_menu_controller.dart';

/// Menu items keyed by id, for weight-check lookups. The head-office portal
/// is the sole source of truth for weights — this app only ever reads or
/// pulls it, never authors it locally. Empty (not a guessed fallback) until
/// head office has answered at least once, so an order with no data yet
/// correctly reads as "not configured" rather than silently using stale or
/// invented weights.
final menuIndexProvider = Provider<Map<String, MenuItem>>((ref) {
  final headOffice = ref.watch(headOfficeMenuProvider);
  return {for (final m in headOffice.items) m.id: m};
});

/// Modifier-combination overrides for the active brand (see
/// ModifierCombinationWeight), looked up by whichever modifiers a line
/// actually selected. Empty index — every lookup returns nothing — until
/// head office has published any (the common case for most brands), so this
/// is a safe default rather than something callers need to null-check.
final modifierCombinationIndexProvider = Provider<ModifierCombinationIndex>((ref) {
  final headOffice = ref.watch(headOfficeMenuProvider);
  if (headOffice.modifierCombinations.isEmpty) return ModifierCombinationIndex.empty;
  return ModifierCombinationIndex(headOffice.modifierCombinations);
});
