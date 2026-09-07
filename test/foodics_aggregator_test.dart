import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/data/foodics_order_repository.dart';

void main() {
  group('parseFoodicsAggregator', () {
    test('Talabat: "Prefix: id, #ref" format', () {
      final (name, ref) = parseFoodicsAggregator({
        'external_source': 'Talabat',
        'external_number': 'Mishmash - Talabat: 3815711802, #4887',
      });
      expect(name, 'Talabat');
      expect(ref, '4887');
    });

    test('Snoonu: "Prefix: id" with no #, short id kept as-is', () {
      final (name, ref) = parseFoodicsAggregator({
        'external_source': 'Snoonu',
        'external_number': 'Mishmash - Snoonu: 463327',
      });
      expect(name, 'Snoonu');
      expect(ref, '463327');
    });

    test('KeeTa: short numeric id kept as-is', () {
      final (name, ref) = parseFoodicsAggregator({
        'external_source': 'KeeTa',
        'external_number': 'Mishmash - KeeTa: 3990',
      });
      expect(name, 'KeeTa');
      expect(ref, '3990');
    });

    test('Keeta 2.0: long numeric id truncated to last 4 digits', () {
      final (name, ref) = parseFoodicsAggregator({
        'external_source': 'Keeta 2.0',
        'external_number': 'Mishmash - Keeta 2.0: 4874140355579055',
      });
      expect(name, 'Keeta 2.0');
      expect(ref, '…9055');
    });

    test('Ordable: alphanumeric ref kept as-is', () {
      final (name, ref) = parseFoodicsAggregator({
        'external_source': 'Ordable',
        'external_number': 'Mishmash - Ordable: DQYS-2118',
      });
      expect(name, 'Ordable');
      expect(ref, 'DQYS-2118');
    });

    test('derives name from prefix when external_source missing', () {
      final (name, ref) = parseFoodicsAggregator({
        'external_number': 'Mishmash - Talabat: 3815711802, #4887',
      });
      expect(name, 'Talabat');
      expect(ref, '4887');
    });

    test('dine-in with no source at all -> not an aggregator', () {
      final (name, ref) = parseFoodicsAggregator({
        'external_number': 'SUNV-4490',
      });
      expect(name, isNull);
      expect(ref, isNull);
    });

    test('null meta -> (null, null), no throw', () {
      final (name, ref) = parseFoodicsAggregator(null);
      expect(name, isNull);
      expect(ref, isNull);
    });

    test('meta is not a Map -> (null, null), no throw', () {
      final (name, ref) = parseFoodicsAggregator('not a map');
      expect(name, isNull);
      expect(ref, isNull);
    });

    test('empty meta -> (null, null)', () {
      final (name, ref) = parseFoodicsAggregator(<String, dynamic>{});
      expect(name, isNull);
      expect(ref, isNull);
    });

    test('external_source present but blank external_number -> name only', () {
      final (name, ref) = parseFoodicsAggregator({
        'external_source': 'Talabat',
        'external_number': '',
      });
      expect(name, 'Talabat');
      expect(ref, isNull);
    });

    test('malformed types do not throw (numbers instead of strings)', () {
      final (name, ref) = parseFoodicsAggregator({
        'external_source': 12345,
        'external_number': 67890,
      });
      // Coerced to strings, no crash either way.
      expect(() => (name, ref), returnsNormally);
    });
  });

  group('parseFoodicsSelectedModifiers', () {
    test('resolves a single selected option to its catalog id and name', () {
      final r = parseFoodicsSelectedModifiers([
        {
          'id': 'a2780994-c805-4fc3-952f-bb2de3355860', // opaque per-order join id
          'modifier_option': {
            'id': 'a0a739a8-52f8-46c1-bea9-d9e19ba8188a', // stable catalog id
            'name': 'Curly Fries',
          },
        },
      ]);
      expect(r.ids, ['a0a739a8-52f8-46c1-bea9-d9e19ba8188a']);
      expect(r.names['a0a739a8-52f8-46c1-bea9-d9e19ba8188a'], 'Curly Fries');
    });

    test('resolves multiple selected options on one line, in order', () {
      final r = parseFoodicsSelectedModifiers([
        {
          'modifier_option': {'id': 'opt-fries', 'name': 'Curly Fries'}
        },
        {
          'modifier_option': {'id': 'opt-seasoning', 'name': 'Chilli Lime'}
        },
        {
          'modifier_option': {'id': 'opt-drink', 'name': 'Kinza Diet Lemon'}
        },
      ]);
      expect(r.ids, ['opt-fries', 'opt-seasoning', 'opt-drink']);
      expect(r.names, {
        'opt-fries': 'Curly Fries',
        'opt-seasoning': 'Chilli Lime',
        'opt-drink': 'Kinza Diet Lemon',
      });
    });

    test('null options -> empty ids/names, no throw', () {
      final r = parseFoodicsSelectedModifiers(null);
      expect(r.ids, isEmpty);
      expect(r.names, isEmpty);
    });

    test('options is not a List -> empty ids/names, no throw', () {
      final r = parseFoodicsSelectedModifiers('not a list');
      expect(r.ids, isEmpty);
      expect(r.names, isEmpty);
    });

    test('empty options list -> empty ids/names', () {
      final r = parseFoodicsSelectedModifiers(<Object?>[]);
      expect(r.ids, isEmpty);
      expect(r.names, isEmpty);
    });

    test('missing modifier_option (unresolved include) -> skipped, no throw', () {
      final r = parseFoodicsSelectedModifiers([
        {'id': 'a2780c52-0742-4d98-8e0e-f39c344e8367'}, // no modifier_option key
      ]);
      expect(r.ids, isEmpty);
      expect(r.names, isEmpty);
    });

    test('one malformed entry does not drop the good ones', () {
      final r = parseFoodicsSelectedModifiers([
        {
          'modifier_option': {'id': 'opt-good-1', 'name': 'Regular Fries'}
        },
        'not a map', // malformed
        {'modifier_option': 'not a map either'}, // malformed
        {'modifier_option': <String, dynamic>{}}, // missing id
        {
          'modifier_option': {'id': 'opt-good-2', 'name': 'Coca Cola Zero'}
        },
      ]);
      expect(r.ids, ['opt-good-1', 'opt-good-2']);
      expect(r.names, {
        'opt-good-1': 'Regular Fries',
        'opt-good-2': 'Coca Cola Zero',
      });
    });

    test('blank id is skipped', () {
      final r = parseFoodicsSelectedModifiers([
        {
          'modifier_option': {'id': '', 'name': 'Something'}
        },
      ]);
      expect(r.ids, isEmpty);
      expect(r.names, isEmpty);
    });

    test('id present but name missing -> id kept, no name entry', () {
      final r = parseFoodicsSelectedModifiers([
        {
          'modifier_option': {'id': 'opt-noname'}
        },
      ]);
      expect(r.ids, ['opt-noname']);
      expect(r.names.containsKey('opt-noname'), isFalse);
    });
  });

  group('parseFoodicsTimestamp', () {
    test('treats the naive Foodics timestamp as UTC, not device-local', () {
      final t = parseFoodicsTimestamp('2026-08-11 07:07:22');
      expect(t, isNotNull);
      expect(t!.isUtc, isTrue);
      expect(t.hour, 7);
      expect(t.minute, 7);
      expect(t.second, 22);
      expect(t.year, 2026);
      expect(t.month, 8);
      expect(t.day, 11);
    });

    test('null / empty / non-string -> null, no throw', () {
      expect(parseFoodicsTimestamp(null), isNull);
      expect(parseFoodicsTimestamp(''), isNull);
      expect(parseFoodicsTimestamp(12345), isNull);
    });

    test('unparsable string -> null, no throw', () {
      expect(parseFoodicsTimestamp('not a date'), isNull);
    });
  });

  group('parseFoodicsReceivedAt', () {
    test('prefers kitchen_received_at when present', () {
      final t = parseFoodicsReceivedAt({
        'opened_at': '2026-08-11 07:07:22',
        'meta': {
          'foodics': {
            'cashier_received_at': '2026-08-11 07:07:24',
            'kitchen_received_at': '2026-08-11 07:07:29',
          },
        },
      });
      expect(t, isNotNull);
      expect(t!.second, 29);
    });

    test('falls back to cashier_received_at when kitchen_received_at is absent',
        () {
      final t = parseFoodicsReceivedAt({
        'opened_at': '2026-08-11 07:07:22',
        'meta': {
          'foodics': {'cashier_received_at': '2026-08-11 07:07:24'},
        },
      });
      expect(t, isNotNull);
      expect(t!.second, 24);
    });

    test('falls back to opened_at when meta has neither (always resolves)', () {
      final t = parseFoodicsReceivedAt({
        'opened_at': '2026-08-11 07:07:22',
        'meta': {'foodics': {}},
      });
      expect(t, isNotNull);
      expect(t!.second, 22);
    });

    test('falls back to opened_at when meta/foodics is missing entirely', () {
      final t = parseFoodicsReceivedAt({'opened_at': '2026-08-11 07:07:22'});
      expect(t, isNotNull);
      expect(t!.second, 22);
    });

    test('malformed meta shape does not throw, falls back to opened_at', () {
      final t = parseFoodicsReceivedAt({
        'opened_at': '2026-08-11 07:07:22',
        'meta': 'not a map',
      });
      expect(t, isNotNull);
      expect(t!.second, 22);
    });

    test('no usable timestamp anywhere -> null, no throw', () {
      expect(parseFoodicsReceivedAt({}), isNull);
    });
  });

  group('isStaleFoodicsOrder', () {
    // Fixed "now" for deterministic threshold checks.
    final fixedNow = DateTime.utc(2026, 8, 11, 12, 0);

    test('an order opened just now is not stale', () {
      final order = {'opened_at': '2026-08-11 12:00:00'};
      expect(isStaleFoodicsOrder(order, now: fixedNow), isFalse);
    });

    test('an order opened 23 hours ago is not stale (under the threshold)', () {
      final order = {'opened_at': '2026-08-10 13:00:00'};
      expect(isStaleFoodicsOrder(order, now: fixedNow), isFalse);
    });

    test('an order opened exactly 24 hours ago is not stale (boundary is exclusive)',
        () {
      final order = {'opened_at': '2026-08-10 12:00:00'};
      expect(isStaleFoodicsOrder(order, now: fixedNow), isFalse);
    });

    test('an order opened 25 hours ago is stale', () {
      final order = {'opened_at': '2026-08-10 11:00:00'};
      expect(isStaleFoodicsOrder(order, now: fixedNow), isTrue);
    });

    test('the real-world stale case: opened nearly a month ago', () {
      final order = {'opened_at': '2026-07-16 08:46:11'};
      expect(isStaleFoodicsOrder(order, now: fixedNow), isTrue);
    });

    test('missing opened_at -> never treated as stale (fail-open)', () {
      expect(isStaleFoodicsOrder({}, now: fixedNow), isFalse);
    });

    test('unparsable opened_at -> never treated as stale (fail-open)', () {
      expect(
          isStaleFoodicsOrder({'opened_at': 'garbage'}, now: fixedNow), isFalse);
    });

    test('defaults "now" to the real current time when not provided', () {
      expect(
          () => isStaleFoodicsOrder({'opened_at': '2026-08-11 12:00:00'}),
          returnsNormally);
    });
  });
}
