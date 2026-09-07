import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tare_pack_station/data/headoffice_api.dart';
import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/models/headoffice_settings.dart';
import 'package:tare_pack_station/state/headoffice_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';
import 'package:tare_pack_station/state/weight_model_controller.dart';

const _settings = HeadOfficeSettings(
  baseUrl: 'https://example.trycloudflare.com',
  deviceKey: 'dev_test_key',
);

ProviderContainer _container(http.Client client) => ProviderContainer(overrides: [
      initialSettingsProvider.overrideWithValue(AppSettings.defaults()),
      headOfficeApiProvider.overrideWithValue(HeadOfficeApi(_settings, client: client)),
    ]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // No model published for this brand is a normal, permanent state (not an
  // error) — the weigh-check flow must keep using the built-in formula with
  // no error surfaced anywhere.
  test('no model published leaves the controller unavailable, with no error',
      () async {
    // The backend reports "no model for this brand" as a 200 with a null
    // body (not a 404) — see WeightModelsController.Meta's own comment for
    // why: a 404 here would show as a failed request in the console on every
    // poll for a brand that simply hasn't had a model uploaded yet.
    final client = MockClient((req) async => http.Response('null', 200));
    final container = _container(client);
    addTearDown(container.dispose);

    container.read(weightModelProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(weightModelProvider);
    expect(state.available, isFalse);
    expect(state.lastError, isNull);
  });

  // A network hiccup on the version poll must fail open exactly like "no
  // model published" — never surface as an error state that would alarm
  // staff over something that isn't actually broken.
  test('a network failure checking for a model also stays quiet', () async {
    final client = MockClient((req) async => throw Exception('offline'));
    final container = _container(client);
    addTearDown(container.dispose);

    container.read(weightModelProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(weightModelProvider);
    expect(state.available, isFalse);
    expect(state.lastError, isNull);
  });

  // A download whose bytes don't match the server's own reported hash must
  // be discarded outright — never loaded, never cached — since a corrupted
  // transfer is exactly the scenario this check exists to catch.
  test('a downloaded model that fails its integrity check is discarded',
      () async {
    final badBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/model-version')) {
        return http.Response(
            jsonEncode({
              'version': 1,
              'fileName': 'model.tflite',
              'sizeBytes': badBytes.length,
              'sha256Hash': 'deadbeef', // deliberately wrong
              'uploadedAt': DateTime.now().toIso8601String(),
            }),
            200);
      }
      if (req.url.path.endsWith('/model')) {
        return http.Response.bytes(badBytes, 200);
      }
      return http.Response('', 404);
    });
    final container = _container(client);
    addTearDown(container.dispose);

    container.read(weightModelProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(weightModelProvider);
    expect(state.available, isFalse);
    expect(state.lastError, contains('integrity'));

    final store = SettingsStore();
    expect(await store.loadCachedModel(), isNull,
        reason: 'a failed-integrity-check download must never be cached');
  });

  // A download that passes its integrity check but isn't a real/loadable
  // TFLite model (corrupt, wrong format, or — as happens in this very test
  // environment — the native runtime itself unavailable) must still leave
  // the controller safely on the fallback, with a clear (non-alarming)
  // status rather than crashing anything.
  test('a model that fails to load (bad format) falls back safely, and is '
      'not cached', () async {
    final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final hash = sha256.convert(bytes).toString();
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/model-version')) {
        return http.Response(
            jsonEncode({
              'version': 5,
              'fileName': 'model.tflite',
              'sizeBytes': bytes.length,
              'sha256Hash': hash,
              'uploadedAt': DateTime.now().toIso8601String(),
            }),
            200);
      }
      if (req.url.path.endsWith('/model')) {
        return http.Response.bytes(bytes, 200);
      }
      return http.Response('', 404);
    });
    final container = _container(client);
    addTearDown(container.dispose);

    container.read(weightModelProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(weightModelProvider);
    expect(state.available, isFalse);
    expect(state.lastError, isNotNull);

    final store = SettingsStore();
    expect(await store.loadCachedModel(), isNull,
        reason: 'a model that failed to load must never be cached either');
  });
}
