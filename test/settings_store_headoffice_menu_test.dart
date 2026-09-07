import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/models/menu_item.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Regression coverage for real-time menu sync: PublishedVersion (the
  // admin's deliberate "Publish" click) and MenuSyncedVersion (the automatic
  // Foodics sync, webhook or periodic) are deliberately two separate
  // counters — the cache must round-trip both independently, or a device
  // restart would lose track of which automatic syncs it had already seen
  // and either miss a real change or force a needless extra refetch.
  test('the cached menu round-trips both publishedVersion and '
      'menuSyncedVersion independently', () async {
    final store = SettingsStore();
    const items = [
      MenuItem(id: 'mi_a', name: 'Old Skool Deal', baseWeightGrams: 250),
    ];

    await store.saveHeadOfficeMenu(
      items, 3, 'BBT', 'branch-1', 'ARD-BBT',
      menuSyncedVersion: 42,
    );
    final loaded = await store.loadHeadOfficeMenu();

    expect(loaded, isNotNull);
    expect(loaded!.publishedVersion, 3);
    expect(loaded.menuSyncedVersion, 42,
        reason: 'the automatic-sync counter must survive a restart just '
            'like the published one does');
    expect(loaded.items.single.name, 'Old Skool Deal');
  });

  test('menuSyncedVersion defaults to 0 when omitted (older call sites, '
      'pre-migration data)', () async {
    final store = SettingsStore();
    const items = [
      MenuItem(id: 'mi_a', name: 'Old Skool Deal', baseWeightGrams: 250),
    ];

    await store.saveHeadOfficeMenu(items, 3, 'BBT', 'branch-1', 'ARD-BBT');
    final loaded = await store.loadHeadOfficeMenu();

    expect(loaded!.menuSyncedVersion, 0);
  });
}
