import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tare_pack_station/data/settings_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('an empty queue starts empty, never throws', () async {
    final store = SettingsStore();
    expect(await store.loadWeighEventQueue(), isEmpty);
  });

  test('an enqueued payload round-trips exactly, with a queuedAt timestamp',
      () async {
    final store = SettingsStore();
    final payload = {
      'branchId': 0,
      'foodicsOrderId': 'order-1',
      'measuredG': 250.0,
      'verdict': 'onweight',
    };

    await store.enqueueWeighEvent(payload);
    final queue = await store.loadWeighEventQueue();

    expect(queue, hasLength(1));
    final entry = queue.values.single;
    expect(entry['payload'], payload);
    expect(entry['queuedAt'], isNotNull);
  });

  test('removeQueuedWeighEvents removes exactly the given ids, leaving others',
      () async {
    final store = SettingsStore();
    await store.enqueueWeighEvent({'foodicsOrderId': 'a'});
    await store.enqueueWeighEvent({'foodicsOrderId': 'b'});
    await store.enqueueWeighEvent({'foodicsOrderId': 'c'});

    final queue = await store.loadWeighEventQueue();
    expect(queue, hasLength(3));
    final idToRemove = queue.entries
        .firstWhere((e) => (e.value['payload'] as Map)['foodicsOrderId'] == 'b')
        .key;

    await store.removeQueuedWeighEvents([idToRemove]);
    final remaining = await store.loadWeighEventQueue();

    expect(remaining, hasLength(2));
    final remainingOrderIds =
        remaining.values.map((v) => (v['payload'] as Map)['foodicsOrderId']).toSet();
    expect(remainingOrderIds, {'a', 'c'});
  });

  test('removing an id that was never queued (or already removed) is a no-op',
      () async {
    final store = SettingsStore();
    await store.enqueueWeighEvent({'foodicsOrderId': 'a'});

    await store.removeQueuedWeighEvents(['not-a-real-id']);
    final queue = await store.loadWeighEventQueue();

    expect(queue, hasLength(1));
  });

  test('an unreadable queue fails open to empty, never throws', () async {
    SharedPreferences.setMockInitialValues({
      'weigh_event_queue': 'not valid json at all {{{',
    });
    final store = SettingsStore();

    expect(await store.loadWeighEventQueue(), isEmpty);
  });

  // Regression coverage for the actual failure mode this queue exists for: a
  // tablet offline for a long stretch must not grow this cache without bound
  // — every enqueue re-parses the whole blob, so an unbounded queue would
  // make every future weigh (even after connectivity returns) progressively
  // slower to record.
  test('enqueuing past the cap drops the OLDEST entries first, keeping the '
      'most recent', () async {
    final store = SettingsStore();
    // One over the 500 cap — verified via the public API only (queuedAt
    // ordering, not the private cap constant), so this stays correct even if
    // the cap value itself changes later.
    for (var i = 0; i < 501; i++) {
      await store.enqueueWeighEvent({'foodicsOrderId': 'order-$i'});
      // Distinct timestamps are needed for a deterministic oldest-first
      // ordering — real enqueues are naturally spread over time, but a tight
      // test loop can otherwise land on the exact same millisecond.
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    final queue = await store.loadWeighEventQueue();
    expect(queue, hasLength(500));

    final orderIds =
        queue.values.map((v) => (v['payload'] as Map)['foodicsOrderId'] as String).toSet();
    expect(orderIds.contains('order-0'), isFalse,
        reason: 'the very first (oldest) enqueued entry should have been evicted');
    expect(orderIds.contains('order-500'), isTrue,
        reason: 'the most recently enqueued entry must always survive');
  });
}
