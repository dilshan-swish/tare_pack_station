import 'dart:convert';

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
import 'package:tare_pack_station/state/weigh_event_queue_controller.dart';

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

  test('sendOrQueue does not queue a payload that sends successfully',
      () async {
    final client = MockClient((req) async => http.Response('', 200));
    final container = _container(client);
    addTearDown(container.dispose);

    container.read(weighEventQueueProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await container
        .read(weighEventQueueProvider.notifier)
        .sendOrQueue({'foodicsOrderId': 'a'});
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(weighEventQueueProvider), 0);
    final store = SettingsStore();
    expect(await store.loadWeighEventQueue(), isEmpty);
  });

  test('sendOrQueue queues a payload on a retryable (network) failure',
      () async {
    final client = MockClient((req) async => throw Exception('offline'));
    final container = _container(client);
    addTearDown(container.dispose);

    container.read(weighEventQueueProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await container
        .read(weighEventQueueProvider.notifier)
        .sendOrQueue({'foodicsOrderId': 'a'});
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(weighEventQueueProvider), 1);
    final store = SettingsStore();
    final queue = await store.loadWeighEventQueue();
    expect(queue, hasLength(1));
    expect(queue.values.single['payload'], {'foodicsOrderId': 'a'});
  });

  // A 4xx means the payload itself is invalid — retrying it forever would
  // never succeed and would just occupy a slot other, valid entries could
  // use, so a rejected send must be dropped, not queued.
  test('sendOrQueue does NOT queue a payload rejected with a 4xx', () async {
    final client = MockClient((req) async => http.Response('bad payload', 400));
    final container = _container(client);
    addTearDown(container.dispose);

    container.read(weighEventQueueProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await container
        .read(weighEventQueueProvider.notifier)
        .sendOrQueue({'foodicsOrderId': 'a'});
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(weighEventQueueProvider), 0);
    final store = SettingsStore();
    expect(await store.loadWeighEventQueue(), isEmpty);
  });

  test(
      'a queue populated while offline drains automatically once the API is '
      'reachable again', () async {
    final store = SettingsStore();
    await store.enqueueWeighEvent({'foodicsOrderId': 'a'});
    await store.enqueueWeighEvent({'foodicsOrderId': 'b'});

    var requestCount = 0;
    final client = MockClient((req) async {
      requestCount++;
      return http.Response('', 200);
    });
    final container = _container(client);
    addTearDown(container.dispose);

    // Building the controller (with a reachable API) triggers an immediate
    // flush — this is what actually recovers a device the moment it comes
    // back online, not just the periodic timer.
    container.read(weighEventQueueProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(requestCount, 2);
    expect(container.read(weighEventQueueProvider), 0);
    expect(await store.loadWeighEventQueue(), isEmpty);
  });

  test(
      '_flush stops at the first retryable failure, leaving later queued '
      'entries untouched', () async {
    final store = SettingsStore();
    await store.enqueueWeighEvent({'foodicsOrderId': 'a'});
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await store.enqueueWeighEvent({'foodicsOrderId': 'b'});
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await store.enqueueWeighEvent({'foodicsOrderId': 'c'});

    var requestCount = 0;
    final client = MockClient((req) async {
      requestCount++;
      throw Exception('still offline');
    });
    final container = _container(client);
    addTearDown(container.dispose);

    container.read(weighEventQueueProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(requestCount, 1,
        reason: 'a still-offline flush must stop at the first retryable '
            'failure rather than burning the HTTP timeout on every queued '
            'entry');
    expect(container.read(weighEventQueueProvider), 3);
    expect(await store.loadWeighEventQueue(), hasLength(3));
  });

  test(
      'a corrupted queue entry is dropped without blocking the rest of the '
      'flush', () async {
    SharedPreferences.setMockInitialValues({
      'weigh_event_queue': jsonEncode({
        'corrupt-id': {
          'queuedAt': '2020-01-01T00:00:00.000Z',
          'payload': 'not-a-map', // malformed — never sendable
        },
        'good-id': {
          'queuedAt': '2020-01-02T00:00:00.000Z',
          'payload': {'foodicsOrderId': 'good'},
        },
      }),
    });

    var requestCount = 0;
    final client = MockClient((req) async {
      requestCount++;
      return http.Response('', 200);
    });
    final container = _container(client);
    addTearDown(container.dispose);

    container.read(weighEventQueueProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(requestCount, 1,
        reason: 'the corrupt entry can never be sent either way, so only the '
            'good one should ever reach the API');
    expect(container.read(weighEventQueueProvider), 0);
    final store = SettingsStore();
    expect(await store.loadWeighEventQueue(), isEmpty);
  });
}
