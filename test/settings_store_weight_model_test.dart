import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tare_pack_station/data/settings_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('a cached model round-trips with its version', () async {
    final store = SettingsStore();
    final bytes = Uint8List.fromList(List<int>.generate(200, (i) => i % 256));

    await store.saveCachedModel(bytes, 3);
    final loaded = await store.loadCachedModel();

    expect(loaded, isNotNull);
    expect(loaded!.version, 3);
    expect(loaded.bytes, bytes);
  });

  test('no cached model yet returns null, never throws', () async {
    final store = SettingsStore();
    expect(await store.loadCachedModel(), isNull);
  });

  test('a model larger than the cache cap is not cached, but never throws',
      () async {
    final store = SettingsStore();
    // 9MB — over the 8MB cap.
    final bytes = Uint8List(9 * 1024 * 1024);

    await store.saveCachedModel(bytes, 1);
    final loaded = await store.loadCachedModel();

    expect(loaded, isNull,
        reason: 'an oversized model should be skipped, not crash the save');
  });

  test('a corrupt cache entry fails open to null, never throws', () async {
    SharedPreferences.setMockInitialValues({
      'weight_model_bytes_base64': 'not valid base64 !!! ###',
      'weight_model_version': 1,
    });
    final store = SettingsStore();

    expect(await store.loadCachedModel(), isNull);
  });
}
