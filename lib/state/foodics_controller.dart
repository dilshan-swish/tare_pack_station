import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/foodics_api.dart';
import '../models/foodics_brand.dart';
import 'settings_controller.dart';

/// Live Foodics calls only work in the native app — browsers block cross-origin
/// requests to the API (CORS). Shown wherever web would otherwise fail.
const kFoodicsWebMessage =
    'Live Foodics runs in the installed Android app. A web browser blocks '
    'direct calls to the Foodics API (CORS), so brands load but branches and '
    'menu sync only work on the tablet.';

const _brandsAsset = 'assets/foodics/brands.json';

/// Loads the bundled brand list (code, name, token). Falls back to an empty
/// list if the asset is missing/corrupt, so the app still runs on the mock.
final foodicsBrandsProvider = FutureProvider<List<FoodicsBrand>>((ref) async {
  try {
    final raw = await rootBundle.loadString(_brandsAsset);
    final list = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in list)
        if (e is Map<String, dynamic>) FoodicsBrand.fromJson(e),
    ].where((b) => b.isValid).toList();
  } catch (e) {
    debugPrint('foodicsBrands load failed: $e');
    return const [];
  }
});

/// The brand selected in settings, resolved against the loaded list.
final activeFoodicsBrandProvider = Provider<FoodicsBrand?>((ref) {
  final code = ref.watch(settingsProvider.select((s) => s.foodics.brandCode));
  if (code.isEmpty) return null;
  final brands = ref.watch(foodicsBrandsProvider).value ?? const [];
  for (final b in brands) {
    if (b.code == code) return b;
  }
  return null;
});

/// Builds a [FoodicsApi] for the active brand, or null if none is selected.
/// The caller owns the returned client and must dispose it.
FoodicsApi? buildFoodicsApi(Ref ref) {
  final brand = ref.read(activeFoodicsBrandProvider);
  if (brand == null) return null;
  final baseUrl = ref.read(settingsProvider).foodics.baseUrl;
  return FoodicsApi(baseUrl: baseUrl, token: brand.token);
}

/// Live branch list for the selected brand (for the branch dropdown).
/// Auto-disposes and refetches when the brand changes.
final foodicsBranchesProvider =
    FutureProvider.autoDispose<List<FoodicsBranch>>((ref) async {
  final brand = ref.watch(activeFoodicsBrandProvider);
  if (brand == null) return const [];
  // Web can't reach the API (CORS) — surface a clear reason instead of a
  // confusing "Failed to fetch".
  if (kIsWeb) throw const FoodicsException(kFoodicsWebMessage);
  final baseUrl = ref.watch(settingsProvider.select((s) => s.foodics.baseUrl));
  final api = FoodicsApi(baseUrl: baseUrl, token: brand.token);
  try {
    final raw = await api.listBranches();
    final branches = [for (final b in raw) FoodicsBranch.fromJson(b)];
    branches.sort((a, b) => a.name.compareTo(b.name));
    return branches;
  } finally {
    api.dispose();
  }
});
