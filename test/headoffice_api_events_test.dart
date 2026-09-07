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

  group('HeadOfficeApi connectivity-issue reporting', () {
    test('reports a connection_error event on the first failure, but never '
        'repeats an unchanged classification, and reports again on a real '
        'change or recovery', () async {
      final eventBodies = <Map<String, dynamic>>[];
      // Heartbeat responses, consumed in order: 500, 500, DNS-style throw, 200 ok.
      var call = 0;

      final client = MockClient((req) async {
        if (req.url.path.endsWith('/api/devices/events')) {
          eventBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response('{}', 200);
        }
        if (req.url.path.endsWith('/api/devices/heartbeat')) {
          call++;
          switch (call) {
            case 1:
            case 2:
              return http.Response('{}', 500);
            case 3:
              throw Exception('Failed host lookup');
            default:
              return http.Response(jsonEncode({'deviceId': 3}), 200);
          }
        }
        throw StateError('Unexpected request: ${req.url}');
      });

      final api = HeadOfficeApi(settings, client: client);

      expect(await api.heartbeat(), isFalse); // #1: 500 -> server_error
      expect(await api.heartbeat(), isFalse); // #2: 500 again -> unchanged, no repeat
      expect(await api.heartbeat(), isFalse); // #3: throws -> no_internet (a real change)
      expect(await api.heartbeat(), isTrue); // #4: recovers

      expect(eventBodies.length, 3,
          reason: 'server_error once, no_internet once, and one recovery — '
              'never a duplicate for the unchanged #2 call');
      expect(eventBodies[0]['reason'], 'server_error');
      expect(eventBodies[0]['eventType'], 'connection_error');
      expect(eventBodies[1]['reason'], 'no_internet');
      expect(eventBodies[1]['eventType'], 'connection_error');
      expect(eventBodies[2]['eventType'], 'recovered');
    });

    test('a first call that simply succeeds never reports anything — there is '
        'nothing to "recover" from', () async {
      final eventCalls = <String>[];
      final client = MockClient((req) async {
        eventCalls.add(req.url.path);
        if (req.url.path.endsWith('/api/devices/heartbeat')) {
          return http.Response(jsonEncode({'deviceId': 1}), 200);
        }
        return http.Response('{}', 200);
      });

      final api = HeadOfficeApi(settings, client: client);
      expect(await api.heartbeat(), isTrue);
      expect(eventCalls, ['/api/devices/heartbeat'],
          reason: 'no POST to /api/devices/events on a clean first success');
    });
  });

  group('HeadOfficeApi.fetchVersion', () {
    test('returns the published version on a well-formed 200', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/api/devices/events')) return http.Response('{}', 200);
        return http.Response(jsonEncode({'publishedVersion': 7}), 200);
      });
      final api = HeadOfficeApi(settings, client: client);
      final version = await api.fetchVersion();
      expect(version?.publishedVersion, 7);
      // Older head-office builds omit menuSyncedVersion entirely — must read
      // as 0, not null/crash, so the comparison in HeadOfficeMenuController
      // stays harmless against a server that hasn't deployed this yet.
      expect(version?.menuSyncedVersion, 0);
    });

    test('also reports the automatic-sync version, independent of the '
        'published (human-reviewed) one', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/api/devices/events')) return http.Response('{}', 200);
        return http.Response(
            jsonEncode({'publishedVersion': 7, 'menuSyncedVersion': 42}), 200);
      });
      final api = HeadOfficeApi(settings, client: client);
      final version = await api.fetchVersion();
      expect(version?.publishedVersion, 7);
      expect(version?.menuSyncedVersion, 42);
    });

    test('returns null on a non-200 status', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/api/devices/events')) return http.Response('{}', 200);
        return http.Response(jsonEncode({'publishedVersion': 7}), 503);
      });
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.fetchVersion(), isNull);
    });

    test('returns null when the body is missing/malformed publishedVersion', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/api/devices/events')) return http.Response('{}', 200);
        return http.Response(jsonEncode({'somethingElse': true}), 200);
      });
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.fetchVersion(), isNull);
    });

    test('returns null, never throws, when the request fails', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/api/devices/events')) return http.Response('{}', 200);
        throw Exception('Could not resolve host');
      });
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.fetchVersion(), isNull);
    });
  });

  group('HeadOfficeApi.fetchRecentlyWeighedOrders', () {
    test('maps foodicsOrderId to its overrideReason (null for a clean dispatch)',
        () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode([
            {
              'eventId': 1,
              'deviceId': 5,
              'foodicsOrderId': 'order-a',
              'expectedMinG': 100,
              'expectedMaxG': 110,
              'measuredG': 105,
              'verdict': 'onweight',
              'overrideReason': null,
              'itemMissing': null,
              'weighedAt': '2026-08-19T06:00:00Z',
            },
            {
              'eventId': 2,
              'deviceId': 5,
              'foodicsOrderId': 'order-b',
              'expectedMinG': 100,
              'expectedMaxG': 110,
              'measuredG': 80,
              'verdict': 'under',
              'overrideReason': 'Item left off scale',
              'itemMissing': true,
              'weighedAt': '2026-08-19T06:05:00Z',
            },
          ]),
          200,
        );
      });
      final api = HeadOfficeApi(settings, client: client);
      final result = await api.fetchRecentlyWeighedOrders();
      expect(result, {'order-a': null, 'order-b': 'Item left off scale'});
    });

    test('returns empty on a non-200 status, never throws', () async {
      final client = MockClient((req) async => http.Response('[]', 503));
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.fetchRecentlyWeighedOrders(), isEmpty);
    });

    test('returns empty when the request itself fails (DNS/timeout)', () async {
      final client = MockClient((req) async {
        throw Exception('Could not resolve host');
      });
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.fetchRecentlyWeighedOrders(), isEmpty);
    });

    test('a malformed row is skipped without failing the rest', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode([
            {'foodicsOrderId': 'order-a', 'overrideReason': null},
            'not a map',
            {'foodicsOrderId': '', 'overrideReason': null}, // blank id skipped
            {'overrideReason': null}, // missing id skipped
          ]),
          200,
        );
      });
      final api = HeadOfficeApi(settings, client: client);
      expect(await api.fetchRecentlyWeighedOrders(), {'order-a': null});
    });

    test('false without even attempting a request when not configured', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('[]', 200);
      });
      final api = HeadOfficeApi(
        const HeadOfficeSettings(baseUrl: '', deviceKey: ''),
        client: client,
      );
      expect(await api.fetchRecentlyWeighedOrders(), isEmpty);
      expect(called, isFalse);
    });
  });
}
