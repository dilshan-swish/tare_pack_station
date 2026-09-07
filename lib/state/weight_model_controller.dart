import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/weight_predictor.dart';
import 'headoffice_controller.dart';
import 'settings_controller.dart';

/// Visible state of the optional ML weight-prediction model, for the
/// Settings screen. [available] mirrors [WeightPredictor.isAvailable] — the
/// weigh-check flow itself never touches this state directly, it always goes
/// through [WeightModelController.predict], which already knows to fall back
/// silently when this is false.
class WeightModelState {
  final bool available;
  final int? version;

  /// Set only when a download/load genuinely failed — informational for
  /// Settings, never a reason to interrupt weighing.
  final String? lastError;

  const WeightModelState({this.available = false, this.version, this.lastError});

  WeightModelState copyWith({bool? available, int? version, String? lastError}) =>
      WeightModelState(
        available: available ?? this.available,
        version: version ?? this.version,
        lastError: lastError,
      );
}

/// Keeps the optional ML weight-prediction model in sync with whatever head
/// office has published for this device's brand — same "poll a cheap
/// version, download the full thing only when it changed" shape as the menu
/// sync in `headoffice_menu_controller.dart`. There is always a working
/// statistical fallback (`WeightEvaluator`), so every failure mode here
/// (offline, no model published, a corrupt download, a wrong-shaped model)
/// just means "keep using the fallback" — never a crash, never a blocked
/// weigh-check.
final weightModelProvider =
    NotifierProvider<WeightModelController, WeightModelState>(WeightModelController.new);

class WeightModelController extends Notifier<WeightModelState> {
  static const _pollEvery = Duration(seconds: 20);
  Timer? _timer;
  final _predictor = WeightPredictor();

  @override
  WeightModelState build() {
    final api = ref.watch(headOfficeApiProvider);
    _timer?.cancel();
    ref.onDispose(() {
      _timer?.cancel();
      _predictor.dispose();
    });

    if (api == null) return const WeightModelState();

    unawaited(_loadCachedThenCheck());
    _timer = Timer.periodic(_pollEvery, (_) => unawaited(_checkForUpdate()));
    return const WeightModelState();
  }

  Future<void> _loadCachedThenCheck() async {
    try {
      final cached = await ref.read(settingsStoreProvider).loadCachedModel();
      if (cached != null && _predictor.loadFromBytes(cached.bytes)) {
        state = WeightModelState(available: true, version: cached.version);
      }
    } catch (e) {
      debugPrint('WeightModelController: cache load failed: $e');
    }
    await _checkForUpdate();
  }

  Future<void> _checkForUpdate() async {
    final api = ref.read(headOfficeApiProvider);
    if (api == null) return;

    final meta = await api.fetchModelVersion();
    // Null covers BOTH "no model published for this brand" (a normal,
    // permanent state) and a transient network failure — either way, keep
    // whatever we already have (a loaded model, or the fallback) rather than
    // treating it as an error.
    if (meta == null) return;
    if (meta.version == state.version) return;

    final bytes = await api.downloadModel();
    if (bytes == null) return;

    final actualHash = sha256.convert(bytes).toString();
    if (actualHash != meta.sha256Hash) {
      debugPrint('WeightModelController: downloaded model hash mismatch, discarding');
      state = state.copyWith(lastError: 'Downloaded model failed an integrity check');
      return;
    }

    if (!_predictor.loadFromBytes(bytes)) {
      state = state.copyWith(
          lastError: 'Model v${meta.version} failed to load — using the built-in formula');
      return;
    }

    state = WeightModelState(available: true, version: meta.version);
    try {
      await ref.read(settingsStoreProvider).saveCachedModel(bytes, meta.version);
    } catch (e) {
      debugPrint('WeightModelController: cache save failed: $e');
    }
  }

  /// The model's prediction for this order's 6-feature vector (see
  /// docs/AI_MODEL_CONTRACT.md), or null to fall back to the statistical
  /// formula — null whenever no model is loaded, not just on error.
  ModelPrediction? predict(List<double> features) =>
      state.available ? _predictor.predict(features) : null;
}
