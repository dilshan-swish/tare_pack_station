import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'connection_issue.dart';
import '../logic/modifier_pairing.dart';
import '../models/headoffice_settings.dart';
import '../models/menu_item.dart';
import '../models/modifier.dart';

/// Bumped when the tablet app changes; reported to head office on heartbeat.
const String kAppVersion = '1.0.0';

/// Outcome of one [HeadOfficeApi.sendWeighEvent] attempt — distinguishes a
/// genuine success from the two different ways it can fail, because only
/// ONE of those failure modes is worth retrying:
///   - [sent]: a 2xx response. Done.
///   - [retryable]: no network, a timeout, or a 5xx — head office (or the
///     connection to it) is the problem, not this payload. Worth queuing
///     for another attempt once connectivity returns.
///   - [rejected]: a 4xx — head office understood the request and refused
///     it (a malformed field, most likely). The exact same payload will
///     get the exact same 4xx forever, so queuing it for retry would just
///     grow the local queue without ever succeeding; the caller should log
///     it and drop it instead.
enum WeighEventSendResult { sent, retryable, rejected }

/// The published menu this device's branch/brand belongs to, as returned by
/// `GET /api/devices/me/config` — each item carries exactly the modifiers
/// actually linked to it (weighed or not).
class HeadOfficeConfig {
  final int brandId;
  final String brandCode;
  final String brandName;
  final int publishedVersion;

  /// Separate from [publishedVersion] — see [HeadOfficeMenuCache.menuSyncedVersion].
  final int menuSyncedVersion;

  final List<MenuItem> items;

  /// Modifier-combination overrides for this brand — see ModifierCombinationWeight.
  /// Empty for a brand with none configured (the overwhelmingly common case).
  final List<ModifierCombinationWeight> modifierCombinations;

  /// This device's own registered branch, as a Foodics branch UUID — lets the
  /// app fetch live orders for exactly this branch automatically, instead of
  /// relying on a separately/manually picked brand+branch in Settings that
  /// could silently drift out of sync with what this device actually weighs
  /// for. Null if the branch was never linked to a Foodics branch (e.g.
  /// created by hand in the portal without a Foodics sync).
  final String? foodicsBranchId;

  /// The branch's human-readable label (e.g. "ARD-BBT") — for display. The
  /// UUID above is not something a person should ever have to read.
  final String? branchName;

  /// Foodics' own localized display name (e.g. "Yard Branch") — preferred
  /// over [branchName] wherever a person reads it, falling back to
  /// [branchName] when Foodics hasn't set one.
  final String? branchNameLocalized;

  /// Foodics' daily opening/closing time ("HH:mm" strings, not full
  /// timestamps) — null if Foodics never set them. Equal from/to
  /// conventionally means open around the clock.
  final String? branchOpeningFrom;
  final String? branchOpeningTo;

  const HeadOfficeConfig({
    required this.brandId,
    required this.brandCode,
    required this.brandName,
    required this.publishedVersion,
    this.menuSyncedVersion = 0,
    required this.items,
    this.modifierCombinations = const [],
    this.foodicsBranchId,
    this.branchName,
    this.branchNameLocalized,
    this.branchOpeningFrom,
    this.branchOpeningTo,
  });
}

/// The two independent version counters `GET /api/devices/me/version` reports
/// — see [HeadOfficeMenuCache.menuSyncedVersion] for why there are two, not
/// one. The tablet refetches the full config when EITHER has moved.
class HeadOfficeVersion {
  final int publishedVersion;
  final int menuSyncedVersion;
  const HeadOfficeVersion({
    required this.publishedVersion,
    required this.menuSyncedVersion,
  });
}

/// Talks to the on-prem head-office API using this device's key. Every call is
/// wrapped so a network/head-office problem can never crash the pack station —
/// the scale keeps working locally regardless.
class HeadOfficeApi {
  final HeadOfficeSettings settings;
  final http.Client _client;

  HeadOfficeApi(this.settings, {http.Client? client})
      : _client = client ?? http.Client();

  Uri _u(String path) =>
      Uri.parse(settings.baseUrl.trim().replaceAll(RegExp(r'/+$'), '') + path);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Device-Key': settings.deviceKey.trim(),
      };

  /// The most recent classification from any call this instance has made —
  /// read by the UI for an immediate local "why" without waiting on a
  /// round trip. Null until the first call completes.
  ConnectionIssue? get lastIssue => _lastReported;
  ConnectionIssue? _lastReported;

  /// Reports a connectivity classification to head office's device-event log
  /// — but ONLY on a change from what was last reported, so a scale sitting
  /// offline for hours produces one log entry, not one per poll. Best-effort
  /// and silent: if head office can't be reached at all, there is inherently
  /// no channel to explain why (nothing can fix that), so this simply no-ops
  /// rather than throwing.
  Future<void> _report(ConnectionIssue issue) async {
    if (issue == _lastReported) return;
    final previous = _lastReported;
    _lastReported = issue;
    if (!settings.isConnected) return;
    // Never report the very first observation as a "recovery" — only an
    // actual transition away from a known problem counts as one.
    if (issue == ConnectionIssue.none && previous == null) return;
    try {
      await _client
          .post(_u('/api/devices/events'),
              headers: _headers,
              body: jsonEncode({
                'eventType':
                    issue == ConnectionIssue.none ? 'recovered' : 'connection_error',
                'reason': issue.code,
                'detail': issue == ConnectionIssue.none ? null : issue.label,
              }))
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('HeadOffice reportEvent failed: $e');
    }
  }

  /// Pings head office. Returns true only if it responded OK AND the body is
  /// actually shaped like our own API's response — a bare status-200 check
  /// isn't enough: a mistyped address can resolve to a *different* real
  /// server (a parked domain, a captive portal, someone else's site) that
  /// happens to answer 200 to an unrecognized path, which would otherwise be
  /// misread as "connected". Never throws.
  Future<bool> heartbeat() async {
    if (!settings.isConnected) return false;
    try {
      final res = await _client
          .post(_u('/api/devices/heartbeat'),
              headers: _headers,
              body: jsonEncode({'appVersion': kAppVersion}))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        await _report(classifyConnectionFailure(statusCode: res.statusCode));
        return false;
      }
      final decoded = jsonDecode(res.body);
      final ok = decoded is Map<String, dynamic> && decoded.containsKey('deviceId');
      await _report(ok ? ConnectionIssue.none : ConnectionIssue.malformedResponse);
      return ok;
    } catch (e) {
      debugPrint('HeadOffice heartbeat failed: $e');
      await _report(classifyConnectionFailure(error: e));
      return false;
    }
  }

  /// The Foodics order ids this device has already weighed-and-dispatched
  /// recently (per `sendWeighEvent`, fired exactly once, at the moment
  /// "Confirm and dispatch" happens), each mapped to whatever override reason
  /// was recorded (null for a clean on-weight dispatch) — the durable answer
  /// to "has this order already been weighed," independent of the app's own
  /// in-memory state. Foodics itself has no such concept (an order can sit
  /// "open" for a long time after it's physically been packed and handed
  /// off), and the in-memory dispatched-tracking in `OrdersController` only
  /// survives for as long as the app keeps running — lost on a restart, a
  /// Settings change that rebuilds the order repository, or a manual retry.
  /// Checking this on every fresh order fetch is what stops an
  /// already-weighed order from reappearing as "Ready to weigh" in exactly
  /// those cases. Returns empty on any failure — an already-weighed order
  /// incorrectly re-showing as unweighed is a minor annoyance (staff can just
  /// re-weigh); silently hiding a genuinely-unweighed order would be far
  /// worse, so this never blocks or fails the queue. Never throws.
  Future<Map<String, String?>> fetchRecentlyWeighedOrders({
    Duration within = const Duration(hours: 48),
  }) async {
    if (!settings.isConnected) return const {};
    try {
      final since = DateTime.now().toUtc().subtract(within);
      final res = await _client
          .get(
            _u('/api/weigh-events?from=${since.toIso8601String()}&limit=500'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const {};
      final decoded = jsonDecode(res.body);
      if (decoded is! List) return const {};
      final result = <String, String?>{};
      for (final row in decoded) {
        if (row is! Map<String, dynamic>) continue;
        final id = row['foodicsOrderId'] as String?;
        if (id == null || id.isEmpty) continue;
        result[id] = row['overrideReason'] as String?;
      }
      return result;
    } catch (e) {
      debugPrint('HeadOffice fetchRecentlyWeighedOrders failed: $e');
      return const {};
    }
  }

  /// Records a completed weigh. Never throws — every failure mode (no
  /// connection configured, a network error, a timeout, a non-2xx status)
  /// resolves to a [WeighEventSendResult] instead, so a caller that wants
  /// this durable (see WeighEventQueueController) can tell "try again
  /// later" apart from "this exact payload will never succeed."
  Future<WeighEventSendResult> sendWeighEvent(Map<String, dynamic> payload) async {
    if (!settings.isConnected) return WeighEventSendResult.retryable;
    try {
      final res = await _client
          .post(_u('/api/weigh-events'),
              headers: _headers, body: jsonEncode(payload))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return WeighEventSendResult.sent;
      }
      if (res.statusCode >= 400 && res.statusCode < 500) {
        debugPrint('HeadOffice sendWeighEvent rejected (${res.statusCode}): ${res.body}');
        return WeighEventSendResult.rejected;
      }
      debugPrint('HeadOffice sendWeighEvent failed (${res.statusCode})');
      return WeighEventSendResult.retryable;
    } catch (e) {
      debugPrint('HeadOffice sendWeighEvent failed: $e');
      return WeighEventSendResult.retryable;
    }
  }

  /// Pulls this device's published item/modifier weights from head office.
  /// Returns null on any failure (offline, auth, malformed response) so the
  /// caller keeps using its last-known-good cache — a head-office hiccup must
  /// never blank out the weigh-check. Never throws.
  Future<HeadOfficeConfig?> fetchConfig() async {
    if (!settings.isConnected) return null;
    try {
      final res = await _client
          .get(_u('/api/devices/me/config'), headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        await _report(classifyConnectionFailure(statusCode: res.statusCode));
        return null;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        await _report(ConnectionIssue.malformedResponse);
        return null;
      }
      final config = parseHeadOfficeConfig(decoded);
      await _report(config == null ? ConnectionIssue.malformedResponse : ConnectionIssue.none);
      return config;
    } catch (e) {
      debugPrint('HeadOffice fetchConfig failed: $e');
      await _report(classifyConnectionFailure(error: e));
      return null;
    }
  }

  /// Cheap poll target for near-real-time menu sync: just the brand's current
  /// version counters, nowhere near the cost of the full item/modifier list
  /// — safe to call every ~20s. The caller re-fetches the full config when
  /// EITHER counter changes (see [HeadOfficeVersion]). Returns null on any
  /// failure (caller simply tries again on the next tick). Never throws.
  Future<HeadOfficeVersion?> fetchVersion() async {
    if (!settings.isConnected) return null;
    try {
      final res = await _client
          .get(_u('/api/devices/me/version'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        await _report(classifyConnectionFailure(statusCode: res.statusCode));
        return null;
      }
      final decoded = jsonDecode(res.body);
      final published =
          decoded is Map<String, dynamic> ? decoded['publishedVersion'] : null;
      if (published is! num) {
        await _report(ConnectionIssue.malformedResponse);
        return null;
      }
      // Older head-office builds won't send this field yet — 0 keeps the
      // comparison harmless (never triggers a spurious "changed") rather
      // than treating an absent field as malformed.
      final synced = decoded['menuSyncedVersion'];
      await _report(ConnectionIssue.none);
      return HeadOfficeVersion(
        publishedVersion: published.toInt(),
        menuSyncedVersion: synced is num ? synced.toInt() : 0,
      );
    } catch (e) {
      debugPrint('HeadOffice fetchVersion failed: $e');
      await _report(classifyConnectionFailure(error: e));
      return null;
    }
  }

  /// Cheap poll target for the ML weight-prediction model — same shape as
  /// [fetchVersion] for the menu. Returns null if this brand has no model
  /// published (a normal, permanent state, not a failure) or on any network
  /// problem. Never throws.
  Future<ModelMeta?> fetchModelVersion() async {
    if (!settings.isConnected) return null;
    try {
      final res = await _client
          .get(_u('/api/devices/me/model-version'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        await _report(classifyConnectionFailure(statusCode: res.statusCode));
        return null;
      }
      final decoded = jsonDecode(res.body);
      if (decoded == null) {
        await _report(ConnectionIssue.none);
        return null; // no model published for this brand — normal, not an error
      }
      if (decoded is! Map<String, dynamic>) {
        await _report(ConnectionIssue.malformedResponse);
        return null;
      }
      final version = decoded['version'];
      final sha256 = decoded['sha256Hash'];
      if (version is! num || sha256 is! String) {
        await _report(ConnectionIssue.malformedResponse);
        return null;
      }
      await _report(ConnectionIssue.none);
      return ModelMeta(version: version.toInt(), sha256Hash: sha256);
    } catch (e) {
      debugPrint('HeadOffice fetchModelVersion failed: $e');
      await _report(classifyConnectionFailure(error: e));
      return null;
    }
  }

  /// Downloads the full model file. Returns null on any failure — the caller
  /// keeps using whatever model (or fallback) it already had. Never throws.
  Future<Uint8List?> downloadModel() async {
    if (!settings.isConnected) return null;
    try {
      final res = await _client
          .get(_u('/api/devices/me/model'), headers: _headers)
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        await _report(classifyConnectionFailure(statusCode: res.statusCode));
        return null;
      }
      await _report(ConnectionIssue.none);
      return res.bodyBytes;
    } catch (e) {
      debugPrint('HeadOffice downloadModel failed: $e');
      await _report(classifyConnectionFailure(error: e));
      return null;
    }
  }

  void dispose() => _client.close();
}

/// Metadata for the currently-published weight-prediction model, without the
/// (potentially large) model bytes themselves — see [HeadOfficeApi.fetchModelVersion].
class ModelMeta {
  final int version;
  final String sha256Hash;
  const ModelMeta({required this.version, required this.sha256Hash});
}

/// Parses a `GET /api/devices/me/config` response body into a
/// [HeadOfficeConfig]. Every list entry is parsed defensively — one malformed
/// item or modifier is skipped rather than failing the whole config; a
/// completely unusable payload returns null rather than throwing.
HeadOfficeConfig? parseHeadOfficeConfig(Map<String, dynamic> json) {
  try {
    final brandId = (json['brandId'] as num?)?.toInt() ?? 0;
    final brandCode = json['code'] as String? ?? '';
    final brandName = json['name'] as String? ?? '';
    final publishedVersion = (json['publishedVersion'] as num?)?.toInt() ?? 0;
    final menuSyncedVersion = (json['menuSyncedVersion'] as num?)?.toInt() ?? 0;

    // Every modifier option the brand has, weighed or not — a null weight
    // (not yet set in the portal) is kept, NOT dropped: it still needs to be
    // shown to staff (e.g. "Sprite — not weighed yet", matching the portal's
    // own display), it just must never be treated as 0g in the weight math
    // (see WeightEvaluator/findUnconfiguredWeightMessages, which explicitly
    // check for a null weight rather than relying on the id being absent).
    // Keyed by id so each item below can look up exactly (and only) the
    // options actually linked to it.
    final modifiersById = <String, Modifier>{};
    final modifiersRaw = json['modifiers'];
    if (modifiersRaw is List) {
      for (final m in modifiersRaw) {
        try {
          if (m is! Map<String, dynamic>) continue;
          final id = m['foodicsModifierId'] as String?;
          final name = m['name'] as String?;
          if (id == null || id.isEmpty || name == null) continue;
          modifiersById[id] = Modifier(
            id: id,
            name: name,
            weightGrams: (m['weightG'] as num?)?.toDouble(),
            minWeightGrams: (m['minWeightG'] as num?)?.toDouble(),
            maxWeightGrams: (m['maxWeightG'] as num?)?.toDouble(),
            groupName: m['modifierGroupName'] as String?,
            groupReference: m['modifierGroupReference'] as String?,
            sku: m['sku'] as String?,
            isActive: m['isActive'] as bool? ?? true,
          );
        } catch (_) {
          // Skip this one malformed modifier row; the rest are still usable.
        }
      }
    }

    final items = <MenuItem>[];
    final itemsRaw = json['items'];
    if (itemsRaw is List) {
      for (final it in itemsRaw) {
        try {
          if (it is! Map<String, dynamic>) continue;
          final id = it['foodicsProductId'] as String?;
          final name = it['name'] as String?;
          if (id == null || id.isEmpty || name == null) continue;

          // Only the options actually linked to THIS item (already narrowed
          // server-side to the real, non-duplicated set via the Foodics
          // product<->group pivot) — never the brand's whole modifier list,
          // which would otherwise show e.g. 30 near-identical "Arwa Water"
          // rows on a single item. Includes unweighed options (for display);
          // only an id with no catalog entry at all is skipped.
          final linkedIds = (it['modifierIds'] as List<dynamic>? ?? [])
              .whereType<String>();
          final itemModifiers = <Modifier>[
            for (final mid in linkedIds) ?modifiersById[mid],
          ];

          items.add(MenuItem(
            id: id,
            name: name,
            baseWeightGrams: (it['idealWeightG'] as num?)?.toDouble() ?? 0,
            packagingWeightGrams:
                (it['packagingWeightG'] as num?)?.toDouble() ?? 0,
            minWeightGrams: (it['minWeightG'] as num?)?.toDouble(),
            maxWeightGrams: (it['maxWeightG'] as num?)?.toDouble(),
            availableModifiers: itemModifiers,
            isActive: it['isActive'] as bool? ?? true,
          ));
        } catch (_) {
          // Skip this one malformed item row; the rest are still usable.
        }
      }
    }

    final combinations = <ModifierCombinationWeight>[];
    final combinationsRaw = json['modifierCombinations'];
    if (combinationsRaw is List) {
      for (final c in combinationsRaw) {
        try {
          if (c is! Map<String, dynamic>) continue;
          final ids = (c['foodicsModifierIds'] as List<dynamic>? ?? [])
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toList();
          final weight = (c['weightG'] as num?)?.toDouble();
          if (ids.length < 2 || weight == null) continue;
          // Only trust the anchor if it's genuinely one of a true 2-member
          // pair — anything else falls back to the older symmetric
          // behavior rather than risking a malformed/impossible override.
          final anchorRaw = c['anchorFoodicsModifierId'] as String?;
          final anchor =
              (anchorRaw != null && ids.length == 2 && ids.contains(anchorRaw)) ? anchorRaw : null;
          combinations.add(ModifierCombinationWeight(
            modifierIds: ids,
            weightG: weight,
            minWeightG: (c['minWeightG'] as num?)?.toDouble(),
            maxWeightG: (c['maxWeightG'] as num?)?.toDouble(),
            anchorModifierId: anchor,
          ));
        } catch (_) {
          // Skip this one malformed combination row; the rest are still usable.
        }
      }
    }

    return HeadOfficeConfig(
      brandId: brandId,
      brandCode: brandCode,
      brandName: brandName,
      publishedVersion: publishedVersion,
      menuSyncedVersion: menuSyncedVersion,
      items: items,
      modifierCombinations: combinations,
      foodicsBranchId: json['foodicsBranchId'] as String?,
      branchName: json['branchName'] as String?,
      branchNameLocalized: json['branchNameLocalized'] as String?,
      branchOpeningFrom: json['branchOpeningFrom'] as String?,
      branchOpeningTo: json['branchOpeningTo'] as String?,
    );
  } catch (e) {
    debugPrint('HeadOffice config parse failed: $e');
    return null;
  }
}
