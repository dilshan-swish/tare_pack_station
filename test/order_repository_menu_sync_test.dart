import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/data/foodics_order_repository.dart';
import 'package:tare_pack_station/data/settings_store.dart';
import 'package:tare_pack_station/models/foodics_brand.dart';
import 'package:tare_pack_station/models/foodics_settings.dart';
import 'package:tare_pack_station/state/foodics_controller.dart';
import 'package:tare_pack_station/state/headoffice_menu_controller.dart';
import 'package:tare_pack_station/state/orders_controller.dart';
import 'package:tare_pack_station/state/settings_controller.dart';

/// A [HeadOfficeMenuController] whose state a test can push directly,
/// bypassing the real network-driven `build()`/`_refresh()` flow.
class _MutableMenu extends HeadOfficeMenuController {
  @override
  HeadOfficeMenuState build() => const HeadOfficeMenuState();
  void set(HeadOfficeMenuState s) => state = s;
}

void main() {
  // Regression test for a real report: tapping "Sync Menu" showed a full
  // loading spinner and reloaded the entire orders queue, even though only
  // the menu (weights/modifiers) was meant to refresh. Root cause:
  // `orderRepositoryProvider` watched the whole `HeadOfficeMenuState` object,
  // which `HeadOfficeMenuController._refresh()` replaces with a brand-new
  // instance on every successful sync — even when the device's actual
  // brand/branch haven't changed. Watching the whole object meant Riverpod
  // tore down and rebuilt the repository (and therefore the whole
  // `ordersProvider`) on every menu sync, not just the rare case where the
  // brand/branch genuinely changes. Fixed with a `.select()` on just the
  // brand/branch fields.
  test(
      'a menu sync that keeps the same brand/branch does not rebuild the '
      'order repository (the "Sync Menu forces a reload" bug)', () async {
    final container = ProviderContainer(overrides: [
      initialSettingsProvider.overrideWithValue(
        AppSettings.defaults().copyWith(
          foodics: FoodicsSettings.defaults.copyWith(enabled: true),
        ),
      ),
      foodicsBrandsProvider.overrideWith((ref) async => const [
            FoodicsBrand(code: 'BBT', name: 'BBT', account: '1', token: 'tok'),
          ]),
      headOfficeMenuProvider.overrideWith(() => _MutableMenu()),
    ]);
    addTearDown(container.dispose);

    await container.read(foodicsBrandsProvider.future);
    final menu = container.read(headOfficeMenuProvider.notifier) as _MutableMenu;

    menu.set(const HeadOfficeMenuState(
      brandCode: 'BBT',
      foodicsBranchId: 'branch-1',
      branchName: 'Branch One',
      publishedVersion: 3,
    ));
    final repo1 = container.read(orderRepositoryProvider);
    expect(repo1, isA<FoodicsOrderRepository>());

    // Simulate "Sync Menu": a brand-new HeadOfficeMenuState instance (newer
    // publishedVersion/syncedAt/items) but the SAME brand/branch.
    menu.set(const HeadOfficeMenuState(
      brandCode: 'BBT',
      foodicsBranchId: 'branch-1',
      branchName: 'Branch One',
      publishedVersion: 4,
      usingCache: false,
    ));
    final repo2 = container.read(orderRepositoryProvider);

    expect(identical(repo1, repo2), isTrue,
        reason: 'menu content changed but brand/branch did not — the order '
            'repository (and thus the orders queue) must not reload');

    // Sanity check the other direction: a genuine brand/branch change (e.g.
    // moving this device to a different branch) must still get a fresh
    // repository pointed at the new branch.
    menu.set(const HeadOfficeMenuState(
      brandCode: 'BBT',
      foodicsBranchId: 'branch-2',
      branchName: 'Branch Two',
    ));
    final repo3 = container.read(orderRepositoryProvider);
    expect(identical(repo1, repo3), isFalse,
        reason: 'a real brand/branch change must still get a fresh repository');
  });
}
