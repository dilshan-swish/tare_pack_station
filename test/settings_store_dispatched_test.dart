import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tare_pack_station/data/settings_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Foodics has no "already weighed" concept, so this local record (plus head
  // office's own durable one) is one of only two ways the app can ever tell
  // an already-dispatched order apart from a fresh one — it must survive an
  // app restart and correctly expire old entries rather than growing forever.
  test('a dispatched order round-trips with its override reason', () async {
    final store = SettingsStore();
    await store.saveDispatchedOrder('order-1', overrideReason: 'Double bagged');
    await store.saveDispatchedOrder('order-2');

    final loaded = await store.loadRecentlyDispatchedOrders();

    expect(loaded, containsPair('order-1', 'Double bagged'));
    expect(loaded, containsPair('order-2', null));
  });

  test('an order dispatched outside the requested window is not returned',
      () async {
    final store = SettingsStore();
    await store.saveDispatchedOrder('order-old');

    final loaded = await store.loadRecentlyDispatchedOrders(
      within: const Duration(seconds: -1), // already "in the past"
    );

    expect(loaded, isEmpty);
  });

  test('an unreadable/corrupt cache fails open to empty, never throws',
      () async {
    SharedPreferences.setMockInitialValues({
      'recently_dispatched_orders': 'not valid json at all {{{',
    });
    final store = SettingsStore();

    final loaded = await store.loadRecentlyDispatchedOrders();

    expect(loaded, isEmpty);
  });

  test('saving prunes entries older than 7 days so the cache never grows unbounded',
      () async {
    final ninetyDaysAgo =
        DateTime.now().subtract(const Duration(days: 90)).toIso8601String();
    SharedPreferences.setMockInitialValues({
      'recently_dispatched_orders':
          '{"order-stale": {"at": "$ninetyDaysAgo", "reason": null}}',
    });
    final store = SettingsStore();

    await store.saveDispatchedOrder('order-fresh');

    // Ask with a generous window — the stale entry should be gone from
    // storage entirely (pruned on write), not just filtered out by the
    // window, so the cache doesn't accumulate forever.
    final loaded = await store.loadRecentlyDispatchedOrders(
      within: const Duration(days: 365),
    );
    expect(loaded.containsKey('order-stale'), isFalse);
    expect(loaded.containsKey('order-fresh'), isTrue);
  });
}
