import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tare_pack_station/data/headoffice_api.dart';
import 'package:tare_pack_station/models/headoffice_settings.dart';

void main() {
  const settings = HeadOfficeSettings(
    baseUrl: 'https://example.trycloudflare.com',
    deviceKey: 'dev_test_key',
  );

  // A bare "status 200" check isn't enough to prove we're actually talking to
  // OUR api — a mistyped/expired tunnel address can resolve to a completely
  // different, unrelated real server (a parked domain, a captive portal) that
  // still answers 200 to an unrecognized path. heartbeat() must also confirm
  // the body is shaped like our own /api/devices/heartbeat response.
  group('HeadOfficeApi.heartbeat', () {
    test('true on a genuine 200 with the expected deviceId shape', () async {
      final client = MockClient((req) async {
        return http.Response(jsonEncode({'deviceId': 3, 'lastSeenAt': '2026-08-13T08:00:00Z'}), 200);
      });
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.heartbeat(), isTrue);
    });

    test('false on a 200 whose body is not our api\'s shape (e.g. an '
        'unrelated server/parked domain answering the request)', () async {
      final client = MockClient((req) async {
        return http.Response('<html><body>Domain parked</body></html>', 200);
      });
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.heartbeat(), isFalse);
    });

    test('false on a 200 with valid JSON but missing deviceId', () async {
      final client = MockClient((req) async {
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      });
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.heartbeat(), isFalse);
    });

    test('false on a non-200 status (e.g. 410 Gone from a dead tunnel domain)',
        () async {
      final client = MockClient((req) async {
        return http.Response(jsonEncode({'deviceId': 3}), 410);
      });
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.heartbeat(), isFalse);
    });

    test('false, never throws, when the request itself fails (DNS/timeout)',
        () async {
      final client = MockClient((req) async {
        throw Exception('Could not resolve host');
      });
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.heartbeat(), isFalse);
    });

    test('false without even attempting a request when not configured',
        () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('{}', 200);
      });
      final api = HeadOfficeApi(
        const HeadOfficeSettings(baseUrl: '', deviceKey: ''),
        client: client,
      );
      expect(await api.heartbeat(), isFalse);
      expect(called, isFalse);
    });
  });
}
