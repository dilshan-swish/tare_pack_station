import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../logic/modifier_pairing.dart';
import '../models/foodics_settings.dart';
import '../models/headoffice_menu_cache.dart';
import '../models/headoffice_settings.dart';
import '../models/menu_item.dart';
import '../models/serial_settings.dart';
import '../models/tolerance_settings.dart';
import '../models/weight_source_type.dart';

/// The full persisted application settings bundle.
///
/// There is no locally editable menu/weight list — the head-office portal is
/// the sole source of truth for weights ([HeadOfficeMenuCache] via
/// [loadHeadOfficeMenu]/[saveHeadOfficeMenu] below); this app only ever reads
/// or pulls it. Tolerance is likewise a fixed constant, not a per-device
/// setting, so it is never persisted.
class AppSettings {
  final WeightSourceType weightSourceType;
  final ToleranceSettings tolerance;
  final SerialSettings serial;
  final FoodicsSettings foodics;
  final HeadOfficeSettings headOffice;

  const AppSettings({
    required this.weightSourceType,
    required this.tolerance,
    required this.serial,
    required this.foodics,
    required this.headOffice,
  });

  AppSettings copyWith({
    WeightSourceType? weightSourceType,
    SerialSettings? serial,
    FoodicsSettings? foodics,
    HeadOfficeSettings? headOffice,
  }) {
    return AppSettings(
      weightSourceType: weightSourceType ?? this.weightSourceType,
      tolerance: tolerance,
      serial: serial ?? this.serial,
      foodics: foodics ?? this.foodics,
      headOffice: headOffice ?? this.headOffice,
    );
  }

  static AppSettings defaults() => AppSettings(
        weightSourceType: WeightSourceType.manual,
        tolerance: ToleranceSettings.defaults,
        serial: SerialSettings.defaults,
        foodics: FoodicsSettings.defaults,
        headOffice: HeadOfficeSettings.defaults,
      );
}

/// Persists [AppSettings] locally via shared_preferences. Every read/write is
/// wrapped so a storage failure falls back to in-memory defaults for the
/// session rather than crashing on startup.
class SettingsStore {
  static const _kWeightSource = 'weight_source_type';
  static const _kSerial = 'serial_settings';
  static const _kFoodics = 'foodics_settings';
  static const _kHeadOffice = 'headoffice_settings';
  static const _kHeadOfficeMenu = 'headoffice_menu_items';
  static const _kHeadOfficeMenuVersion = 'headoffice_menu_version';
  static const _kHeadOfficeMenuSyncedVersion = 'headoffice_menu_synced_version';
  static const _kHeadOfficeMenuSyncedAt = 'headoffice_menu_synced_at';
  static const _kHeadOfficeBrandCode = 'headoffice_menu_brand_code';
  static const _kHeadOfficeFoodicsBranchId = 'headoffice_menu_foodics_branch_id';
  static const _kHeadOfficeBranchName = 'headoffice_menu_branch_name';
  static const _kHeadOfficeBranchNameLocalized =
      'headoffice_menu_branch_name_localized';
  static const _kHeadOfficeBranchOpeningFrom = 'headoffice_menu_branch_opening_from';
  static const _kHeadOfficeBranchOpeningTo = 'headoffice_menu_branch_opening_to';
  static const _kHeadOfficeModifierCombinations = 'headoffice_menu_modifier_combinations';
  static const _kRecentlyDispatched = 'recently_dispatched_orders';
  static const _kWeightModelVersion = 'weight_model_version';
  static const _kWeightModelBytesBase64 = 'weight_model_bytes_base64';
  static const _kWeighEventQueue = 'weigh_event_queue';

  SharedPreferences? _prefs;
  static const _uuid = Uuid();

  Future<void> _ensure() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Loads settings, returning safe defaults for any missing/corrupt value.
  Future<AppSettings> load() async {
    try {
      await _ensure();
      final prefs = _prefs!;

      final weightSource = WeightSourceTypeX.fromStorage(
        prefs.getString(_kWeightSource),
      );

      final serial = _decode(
        prefs.getString(_kSerial),
        SerialSettings.fromJson,
        SerialSettings.defaults,
      );

      final foodics = _decode(
        prefs.getString(_kFoodics),
        FoodicsSettings.fromJson,
        FoodicsSettings.defaults,
      );

      final headOffice = _decode(
        prefs.getString(_kHeadOffice),
        HeadOfficeSettings.fromJson,
        HeadOfficeSettings.defaults,
      );

      return AppSettings(
        weightSourceType: weightSource,
        tolerance: ToleranceSettings.defaults,
        serial: serial,
        foodics: foodics,
        headOffice: headOffice,
      );
    } catch (e) {
      debugPrint('SettingsStore.load failed, using defaults: $e');
      return AppSettings.defaults();
    }
  }

  Future<void> saveWeightSource(WeightSourceType type) =>
      _write(_kWeightSource, () async {
        await _prefs!.setString(_kWeightSource, type.storageKey);
      });

  Future<void> saveSerial(SerialSettings s) => _write(_kSerial, () async {
        await _prefs!.setString(_kSerial, jsonEncode(s.toJson()));
      });

  Future<void> saveFoodics(FoodicsSettings f) => _write(_kFoodics, () async {
        await _prefs!.setString(_kFoodics, jsonEncode(f.toJson()));
      });

  Future<void> saveHeadOffice(HeadOfficeSettings h) =>
      _write(_kHeadOffice, () async {
        await _prefs!.setString(_kHeadOffice, jsonEncode(h.toJson()));
      });

  /// Caches the published menu pulled from head office, so weighing still
  /// works correctly the instant the app opens — before the next network
  /// round trip, or entirely offline. Also caches this device's own brand
  /// code + Foodics branch id, so live orders can keep auto-fetching for the
  /// right brand/branch immediately on startup too.
  Future<void> saveHeadOfficeMenu(
    List<MenuItem> items,
    int publishedVersion,
    String brandCode,
    String? foodicsBranchId,
    String? branchName, {
    int menuSyncedVersion = 0,
    String? branchNameLocalized,
    String? branchOpeningFrom,
    String? branchOpeningTo,
    List<ModifierCombinationWeight> modifierCombinations = const [],
  }) =>
      _write(_kHeadOfficeMenu, () async {
        await _prefs!.setString(
          _kHeadOfficeMenu,
          jsonEncode(items.map((m) => m.toJson()).toList()),
        );
        await _prefs!.setString(
          _kHeadOfficeModifierCombinations,
          jsonEncode(modifierCombinations.map((c) => c.toJson()).toList()),
        );
        await _prefs!.setInt(_kHeadOfficeMenuVersion, publishedVersion);
        await _prefs!.setInt(_kHeadOfficeMenuSyncedVersion, menuSyncedVersion);
        await _prefs!.setString(
          _kHeadOfficeMenuSyncedAt,
          DateTime.now().toIso8601String(),
        );
        await _prefs!.setString(_kHeadOfficeBrandCode, brandCode);
        if (foodicsBranchId != null) {
          await _prefs!.setString(_kHeadOfficeFoodicsBranchId, foodicsBranchId);
        } else {
          await _prefs!.remove(_kHeadOfficeFoodicsBranchId);
        }
        if (branchName != null) {
          await _prefs!.setString(_kHeadOfficeBranchName, branchName);
        } else {
          await _prefs!.remove(_kHeadOfficeBranchName);
        }
        if (branchNameLocalized != null) {
          await _prefs!.setString(
              _kHeadOfficeBranchNameLocalized, branchNameLocalized);
        } else {
          await _prefs!.remove(_kHeadOfficeBranchNameLocalized);
        }
        if (branchOpeningFrom != null) {
          await _prefs!.setString(_kHeadOfficeBranchOpeningFrom, branchOpeningFrom);
        } else {
          await _prefs!.remove(_kHeadOfficeBranchOpeningFrom);
        }
        if (branchOpeningTo != null) {
          await _prefs!.setString(_kHeadOfficeBranchOpeningTo, branchOpeningTo);
        } else {
          await _prefs!.remove(_kHeadOfficeBranchOpeningTo);
        }
      });

  /// Loads the cached head-office menu, or null if there's none yet / it's
  /// unreadable — the caller then simply has nothing to show until the first
  /// live sync lands.
  Future<HeadOfficeMenuCache?> loadHeadOfficeMenu() async {
    try {
      await _ensure();
      final raw = _prefs!.getString(_kHeadOfficeMenu);
      if (raw == null || raw.isEmpty) return null;
      final list = jsonDecode(raw) as List<dynamic>;
      final items = list
          .map((e) => MenuItem.fromJson(e as Map<String, dynamic>))
          .toList();
      if (items.isEmpty) return null;
      final version = _prefs!.getInt(_kHeadOfficeMenuVersion) ?? 0;
      final syncedVersion = _prefs!.getInt(_kHeadOfficeMenuSyncedVersion) ?? 0;
      final syncedRaw = _prefs!.getString(_kHeadOfficeMenuSyncedAt);
      final syncedAt = syncedRaw != null ? DateTime.tryParse(syncedRaw) : null;
      var modifierCombinations = const <ModifierCombinationWeight>[];
      final combosRaw = _prefs!.getString(_kHeadOfficeModifierCombinations);
      if (combosRaw != null && combosRaw.isNotEmpty) {
        try {
          modifierCombinations = (jsonDecode(combosRaw) as List<dynamic>)
              .map((e) => ModifierCombinationWeight.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (_) {
          // Cached combinations unreadable — proceed with none rather than failing
          // the whole cached menu load over this one optional piece.
        }
      }
      return HeadOfficeMenuCache(
        items: items,
        modifierCombinations: modifierCombinations,
        publishedVersion: version,
        menuSyncedVersion: syncedVersion,
        syncedAt: syncedAt,
        brandCode: _prefs!.getString(_kHeadOfficeBrandCode) ?? '',
        foodicsBranchId: _prefs!.getString(_kHeadOfficeFoodicsBranchId),
        branchName: _prefs!.getString(_kHeadOfficeBranchName),
        branchNameLocalized: _prefs!.getString(_kHeadOfficeBranchNameLocalized),
        branchOpeningFrom: _prefs!.getString(_kHeadOfficeBranchOpeningFrom),
        branchOpeningTo: _prefs!.getString(_kHeadOfficeBranchOpeningTo),
      );
    } catch (e) {
      debugPrint('SettingsStore.loadHeadOfficeMenu failed: $e');
      return null;
    }
  }

  /// Records that [orderId] was just dispatched, so it reads as already
  /// weighed even if this app instance restarts (kill + relaunch, or an
  /// update) a moment later and head office's own record of it is briefly
  /// unreachable — Foodics itself has no "already weighed" concept, so this
  /// local record plus head office's durable one are the only two sources
  /// that can ever tell an already-weighed order apart from a fresh one.
  /// Entries older than 7 days are pruned on every write so this never grows
  /// unbounded; [loadRecentlyDispatchedOrders] applies the caller's own
  /// (shorter) window on top of that.
  Future<void> saveDispatchedOrder(String orderId, {String? overrideReason}) =>
      _write(_kRecentlyDispatched, () async {
        final all = await _readDispatchedMap();
        final cutoff = DateTime.now().subtract(const Duration(days: 7));
        all.removeWhere((_, v) {
          final ts = DateTime.tryParse(v['at'] as String? ?? '');
          return ts == null || ts.isBefore(cutoff);
        });
        all[orderId] = {
          'at': DateTime.now().toIso8601String(),
          'reason': overrideReason,
        };
        await _prefs!.setString(_kRecentlyDispatched, jsonEncode(all));
      });

  /// Order ids dispatched by THIS device within [within], mapping to the
  /// override reason (or null for on-weight). Never throws — an unreadable
  /// cache is treated as empty, same fail-open behavior as the head-office
  /// API equivalent this is merged with.
  Future<Map<String, String?>> loadRecentlyDispatchedOrders({
    Duration within = const Duration(hours: 48),
  }) async {
    try {
      await _ensure();
      final all = await _readDispatchedMap();
      final cutoff = DateTime.now().subtract(within);
      return {
        for (final entry in all.entries)
          if ((DateTime.tryParse(entry.value['at'] as String? ?? '')) != null &&
              !DateTime.parse(entry.value['at'] as String).isBefore(cutoff))
            entry.key: entry.value['reason'] as String?,
      };
    } catch (e) {
      debugPrint('SettingsStore.loadRecentlyDispatchedOrders failed: $e');
      return const {};
    }
  }

  Future<Map<String, Map<String, dynamic>>> _readDispatchedMap() async {
    await _ensure();
    final raw = _prefs!.getString(_kRecentlyDispatched);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
    } catch (_) {
      return {};
    }
  }

  /// Caches the ML weight-prediction model, so it's ready to use immediately
  /// on the next app launch without waiting on a network round trip. Stored
  /// as base64 in shared_preferences (the same mechanism as everything else
  /// here) rather than a raw file — this app also targets web, where
  /// `dart:io` file access isn't available at all, and a model small enough
  /// for a tablet to run inference on in real time is also small enough for
  /// this to be a non-issue. Models larger than [_kMaxCacheableModelBytes]
  /// are deliberately NOT cached (the tablet will just re-download on next
  /// launch) rather than risk a very large value slowing down every future
  /// shared_preferences read in the app.
  static const _kMaxCacheableModelBytes = 8 * 1024 * 1024; // 8MB

  Future<void> saveCachedModel(Uint8List bytes, int version) =>
      _write(_kWeightModelVersion, () async {
        if (bytes.length > _kMaxCacheableModelBytes) {
          debugPrint('SettingsStore: model too large to cache locally '
              '(${bytes.length} bytes) — will re-download next launch');
          return;
        }
        await _prefs!.setString(_kWeightModelBytesBase64, base64Encode(bytes));
        await _prefs!.setInt(_kWeightModelVersion, version);
      });

  /// Loads the cached model, or null if there's none yet / it's unreadable —
  /// the caller then simply has no model until the next successful download,
  /// falling back to the statistical formula in the meantime.
  Future<({Uint8List bytes, int version})?> loadCachedModel() async {
    try {
      await _ensure();
      final encoded = _prefs!.getString(_kWeightModelBytesBase64);
      final version = _prefs!.getInt(_kWeightModelVersion);
      if (encoded == null || version == null) return null;
      return (bytes: base64Decode(encoded), version: version);
    } catch (e) {
      debugPrint('SettingsStore.loadCachedModel failed: $e');
      return null;
    }
  }

  /// The most queued weigh events kept locally at once. Small (~1-2KB each)
  /// JSON payloads, so this stays a fraction of a MB even full — the cap
  /// exists so a device offline for days doesn't grow this blob without
  /// bound (every read/write of it re-parses the whole thing). If a device
  /// is ever offline long enough to fill it, the OLDEST queued events are
  /// dropped first on the next enqueue — better to keep the most recent
  /// weighs (closer to when connectivity will likely return, and freshest
  /// in anyone's memory if they need to be re-entered by hand) than to
  /// silently stop queuing new ones.
  static const _maxQueuedWeighEvents = 500;

  /// Adds one weigh-event payload — the exact JSON body [HeadOfficeApi.
  /// sendWeighEvent] would have posted — to the local offline queue. This is
  /// the only reason a weigh recorded while the API (or the network) is
  /// unreachable doesn't just vanish: [WeighEventQueueController] retries
  /// everything queued here on a timer once head office is reachable again.
  Future<void> enqueueWeighEvent(Map<String, dynamic> payload) =>
      _write('enqueueWeighEvent', () async {
        final all = await _readWeighEventQueue();
        all[_uuid.v4()] = {
          'queuedAt': DateTime.now().toIso8601String(),
          'payload': payload,
        };
        if (all.length > _maxQueuedWeighEvents) {
          final oldestFirst = all.entries.toList()
            ..sort((a, b) => (a.value['queuedAt'] as String? ?? '')
                .compareTo(b.value['queuedAt'] as String? ?? ''));
          final overflow = all.length - _maxQueuedWeighEvents;
          for (final e in oldestFirst.take(overflow)) {
            all.remove(e.key);
          }
          debugPrint(
              'SettingsStore: weigh-event queue full, dropped $overflow oldest entries');
        }
        await _prefs!.setString(_kWeighEventQueue, jsonEncode(all));
      });

  /// Every queued weigh event, unordered — [WeighEventQueueController] sorts
  /// by `queuedAt` itself so retry order is oldest-first. Never throws; an
  /// unreadable queue is treated as empty (same fail-open behavior as
  /// everything else here) rather than blocking retries on a corrupt cache.
  Future<Map<String, Map<String, dynamic>>> loadWeighEventQueue() =>
      _readWeighEventQueue();

  /// Removes exactly the given queue entries (by the id [enqueueWeighEvent]
  /// generated) — used after a successful (re)send, or to discard a payload
  /// head office permanently rejected (retrying an invalid payload forever
  /// would never succeed and would just crowd out real, retryable ones).
  Future<void> removeQueuedWeighEvents(Iterable<String> ids) =>
      _write('removeQueuedWeighEvents', () async {
        final all = await _readWeighEventQueue();
        for (final id in ids) {
          all.remove(id);
        }
        await _prefs!.setString(_kWeighEventQueue, jsonEncode(all));
      });

  Future<Map<String, Map<String, dynamic>>> _readWeighEventQueue() async {
    await _ensure();
    final raw = _prefs!.getString(_kWeighEventQueue);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
    } catch (_) {
      return {};
    }
  }

  Future<void> _write(String label, Future<void> Function() action) async {
    try {
      await _ensure();
      await action();
    } catch (e) {
      // Non-fatal: the in-memory state remains correct for this session.
      debugPrint('SettingsStore.save[$label] failed: $e');
    }
  }

  T _decode<T>(
    String? raw,
    T Function(Map<String, dynamic>) fromJson,
    T fallback,
  ) {
    if (raw == null || raw.isEmpty) return fallback;
    try {
      return fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return fallback;
    }
  }
}
