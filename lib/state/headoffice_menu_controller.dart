import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/modifier_pairing.dart';
import '../models/menu_item.dart';
import 'headoffice_controller.dart';
import 'settings_controller.dart';

/// The published menu pulled from head office — the source of truth for
/// weighing once a device is connected. Empty when not connected or nothing
/// has synced yet, in which case the app falls back to the locally configured
/// menu (mock data / manual entry), unchanged from before this existed.
class HeadOfficeMenuState {
  final List<MenuItem> items;

  /// Modifier-combination overrides for the active brand — see ModifierCombinationWeight.
  /// Empty for a brand with none configured (the common case).
  final List<ModifierCombinationWeight> modifierCombinations;
  final int publishedVersion;

  /// See [HeadOfficeMenuCache.menuSyncedVersion] — the automatic-sync signal,
  /// deliberately independent of [publishedVersion].
  final int menuSyncedVersion;

  final DateTime? syncedAt;

  /// True when [items] came from the on-disk cache rather than a live fetch —
  /// i.e. head office hasn't answered yet this session (offline, still
  /// starting up). The scale still weighs correctly; this is purely informational.
  final bool usingCache;

  /// This device's own brand code + registered branch's Foodics branch UUID
  /// (e.g. "BBT" + a branch id) — the source of truth for which brand/branch
  /// to fetch LIVE ORDERS from, once connected. Automatically keeps live
  /// orders and weights pointed at the same brand; there is no separate,
  /// independently editable picker for a connected device. Empty/null until
  /// the first successful fetch (or cache load).
  final String brandCode;
  final String? foodicsBranchId;

  /// The branch's human-readable label (e.g. "ARD-BBT") — always prefer this
  /// over [foodicsBranchId] for anything a person reads.
  final String? branchName;

  /// Foodics' own localized display name (e.g. "Yard Branch") — preferred
  /// over [branchName] wherever a person reads it, falling back to
  /// [branchName] when Foodics hasn't set one.
  final String? branchNameLocalized;

  /// Foodics' daily opening/closing time ("HH:mm" strings, not full
  /// timestamps); null if Foodics never set them. Equal from/to
  /// conventionally means open around the clock.
  final String? branchOpeningFrom;
  final String? branchOpeningTo;

  const HeadOfficeMenuState({
    this.items = const [],
    this.modifierCombinations = const [],
    this.publishedVersion = 0,
    this.menuSyncedVersion = 0,
    this.syncedAt,
    this.usingCache = false,
    this.brandCode = '',
    this.foodicsBranchId,
    this.branchName,
    this.branchNameLocalized,
    this.branchOpeningFrom,
    this.branchOpeningTo,
  });

  /// The best available human-readable branch label — Foodics' own localized
  /// name when set, falling back to the plain [branchName].
  String? get branchDisplayName =>
      (branchNameLocalized != null && branchNameLocalized!.isNotEmpty)
          ? branchNameLocalized
          : branchName;

  bool get hasData => items.isNotEmpty;

  /// True once this device's own brand+branch are known, so live orders can
  /// be fetched automatically without a manual picker.
  bool get hasBrandBranch => brandCode.isNotEmpty && foodicsBranchId != null;
}

/// Keeps the head-office menu in sync: loads the last-known-good cache
/// immediately (so weighing works before the first network round trip),
/// refreshes live on connect, then periodically. A head-office hiccup keeps
/// the last-known-good data — it never blanks out the weigh-check.
final headOfficeMenuProvider =
    NotifierProvider<HeadOfficeMenuController, HeadOfficeMenuState>(
        HeadOfficeMenuController.new);

class HeadOfficeMenuController extends Notifier<HeadOfficeMenuState> {
  // Near-real-time menu sync without the cost of full polling: every tick we
  // hit a cheap version-only endpoint, and only pull the full item/modifier
  // list when that number has actually moved — so a portal "Publish" reaches
  // the tablet within ~20s instead of needing a manual "Sync Menu" tap or
  // waiting on a long fixed interval. A full refresh still runs periodically
  // regardless, as a safety net in case a version check was ever missed.
  static const _pollEvery = Duration(seconds: 20);
  static const _forceRefreshEveryNTicks = 15; // ~5 minutes at the cadence above
  Timer? _timer;
  int _tick = 0;

  @override
  HeadOfficeMenuState build() {
    final api = ref.watch(headOfficeApiProvider);
    _timer?.cancel();
    _tick = 0;
    ref.onDispose(() => _timer?.cancel());

    if (api == null) return const HeadOfficeMenuState();

    unawaited(_loadCacheThenRefresh());
    _timer = Timer.periodic(_pollEvery, (_) => unawaited(_pollVersion()));
    return const HeadOfficeMenuState();
  }

  Future<void> _pollVersion() async {
    final api = ref.read(headOfficeApiProvider);
    if (api == null) return;
    _tick++;
    if (_tick % _forceRefreshEveryNTicks == 0) {
      await _refresh();
      return;
    }
    final version = await api.fetchVersion();
    if (version != null &&
        (version.publishedVersion != state.publishedVersion ||
            version.menuSyncedVersion != state.menuSyncedVersion)) {
      await _refresh();
    }
  }

  Future<void> _loadCacheThenRefresh() async {
    try {
      final cached =
          await ref.read(settingsStoreProvider).loadHeadOfficeMenu();
      if (cached != null && cached.items.isNotEmpty) {
        state = HeadOfficeMenuState(
          items: cached.items,
          modifierCombinations: cached.modifierCombinations,
          publishedVersion: cached.publishedVersion,
          menuSyncedVersion: cached.menuSyncedVersion,
          syncedAt: cached.syncedAt,
          usingCache: true,
          brandCode: cached.brandCode,
          foodicsBranchId: cached.foodicsBranchId,
          branchName: cached.branchName,
          branchNameLocalized: cached.branchNameLocalized,
          branchOpeningFrom: cached.branchOpeningFrom,
          branchOpeningTo: cached.branchOpeningTo,
        );
      }
    } catch (e) {
      debugPrint('HeadOfficeMenu cache load failed: $e');
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    final api = ref.read(headOfficeApiProvider);
    if (api == null) return;
    final config = await api.fetchConfig();
    if (config == null || config.items.isEmpty) {
      return; // Keep whatever we already had (cache or a previous live fetch).
    }
    state = HeadOfficeMenuState(
      items: config.items,
      modifierCombinations: config.modifierCombinations,
      publishedVersion: config.publishedVersion,
      menuSyncedVersion: config.menuSyncedVersion,
      syncedAt: DateTime.now(),
      usingCache: false,
      brandCode: config.brandCode,
      foodicsBranchId: config.foodicsBranchId,
      branchName: config.branchName,
      branchNameLocalized: config.branchNameLocalized,
      branchOpeningFrom: config.branchOpeningFrom,
      branchOpeningTo: config.branchOpeningTo,
    );
    try {
      await ref.read(settingsStoreProvider).saveHeadOfficeMenu(
          config.items, config.publishedVersion, config.brandCode,
          config.foodicsBranchId, config.branchName,
          menuSyncedVersion: config.menuSyncedVersion,
          branchNameLocalized: config.branchNameLocalized,
          branchOpeningFrom: config.branchOpeningFrom,
          branchOpeningTo: config.branchOpeningTo,
          modifierCombinations: config.modifierCombinations);
    } catch (e) {
      debugPrint('HeadOfficeMenu cache save failed: $e');
    }
  }

  /// Manual refresh — e.g. wired to a "Sync now" action.
  Future<void> refreshNow() => _refresh();
}
