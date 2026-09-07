import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/foodics_api.dart';
import '../data/foodics_order_repository.dart';
import '../data/order_repository.dart';
import '../models/foodics_brand.dart';
import '../models/order.dart';
import '../models/order_status.dart';
import 'foodics_controller.dart';
import 'headoffice_controller.dart';
import 'headoffice_menu_controller.dart';
import 'settings_controller.dart';

/// Provides the active [OrderRepository]. Uses the live Foodics repository
/// when live orders are enabled and a brand+branch are resolvable — otherwise
/// the mock. Swapping is pure configuration; no UI code changes.
///
/// Which brand+branch: once head office has resolved this device's own
/// registration (brand + Foodics branch id), THAT is used automatically —
/// it's the same brand/branch the weights come from, so live orders and
/// weight-checks can never silently point at different brands. Only before
/// head office has ever answered (or if it's not configured at all) does the
/// manually-picked brand/branch in [FoodicsSettings] apply, matching the
/// app's original pre-head-office behavior.
///
/// On the web build we always fall back to the mock: browsers block direct
/// cross-origin calls to the Foodics API (CORS), so live orders only work in
/// the native Android app. This keeps the web preview error-free.
final orderRepositoryProvider = Provider<OrderRepository>((ref) {
  final foodics = ref.watch(settingsProvider.select((s) => s.foodics));
  if (!foodics.enabled || kIsWeb) return const MockOrderRepository();

  // Selected rather than watched wholesale: `HeadOfficeMenuState` gets a
  // brand-new instance on every menu sync (e.g. the manual "Sync Menu"
  // button), even when the brand/branch haven't changed. Watching the whole
  // state would tear down and recreate this repository — and thus force the
  // orders queue to fully reload with a loading spinner — on every menu sync,
  // not just the rare case where the device's actual brand/branch changes.
  final headOfficeBrandBranch = ref.watch(headOfficeMenuProvider.select(
      (s) => (hasBrandBranch: s.hasBrandBranch, brandCode: s.brandCode, foodicsBranchId: s.foodicsBranchId)));
  final brands = ref.watch(foodicsBrandsProvider).value ?? const [];

  final String brandCode;
  final String branchId;
  if (headOfficeBrandBranch.hasBrandBranch) {
    brandCode = headOfficeBrandBranch.brandCode;
    branchId = headOfficeBrandBranch.foodicsBranchId!;
  } else {
    brandCode = foodics.brandCode;
    branchId = foodics.branchId;
  }
  if (brandCode.isEmpty || branchId.isEmpty) return const MockOrderRepository();

  FoodicsBrand? brand;
  for (final b in brands) {
    if (b.code == brandCode) {
      brand = b;
      break;
    }
  }
  if (brand == null) return const MockOrderRepository();

  final api = FoodicsApi(baseUrl: foodics.baseUrl, token: brand.token);
  final repo = FoodicsOrderRepository(
    api: api,
    branchId: branchId,
    pollInterval: foodics.pollInterval,
  );
  ref.onDispose(repo.dispose);
  return repo;
});

/// The orders queue. Exposed as an [AsyncValue] so the UI can render loading,
/// error (retry-able), and data states without ever showing a blank screen.
final ordersProvider =
    AsyncNotifierProvider<OrdersController, List<Order>>(OrdersController.new);

class OrdersController extends AsyncNotifier<List<Order>> {
  @override
  Future<List<Order>> build() async {
    final repo = ref.watch(orderRepositoryProvider);
    final headOfficeApi = ref.watch(headOfficeApiProvider);

    // Realtime repositories (Foodics polling) push fresh snapshots. We merge
    // them so a locally dispatched order keeps its dispatched state even if the
    // POS still lists it for a moment.
    if (repo.isRealtime) {
      final sub = repo.watchOrders().listen(
        (orders) {
          state = AsyncValue.data(_reconcileDispatched(orders, previous: state.value));
        },
        onError: (Object e, StackTrace st) {
          // Only fail the whole queue if we never got a first snapshot.
          if (state.value == null) state = AsyncValue.error(e, st);
        },
      );
      ref.onDispose(sub.cancel);
    }

    // All three fire concurrently; awaited in sequence below.
    final ordersFuture = repo.fetchOrders();
    final weighedFuture = headOfficeApi?.fetchRecentlyWeighedOrders() ??
        Future.value(const <String, String?>{});
    final localFuture = _loadLocallyDispatched();
    final orders = await ordersFuture;
    final recentlyWeighed = await weighedFuture;
    final local = await localFuture;
    // No `previous` here — this IS the first fetch of a fresh app session, so
    // the durable records (head office's own, plus this device's local cache
    // of its own recent dispatches — see [_loadLocallyDispatched]) are the
    // only sources available yet to know which of these orders were already
    // dispatched in an earlier session.
    return _reconcileDispatched(orders, recentlyWeighed: {...local, ...recentlyWeighed});
  }

  /// This device's own local record of orders it dispatched recently,
  /// independent of head office. Exists because Foodics has no "already
  /// weighed" concept at all — head office's weigh-event history is the
  /// durable source of truth, but if that lookup ever fails transiently
  /// (a network hiccup right as the app restarts) this local cache still
  /// prevents the same order from being weighed a second time and creating a
  /// duplicate weigh-event. Never throws; an unreadable cache is just empty.
  Future<Map<String, String?>> _loadLocallyDispatched() async {
    try {
      return await ref.read(settingsStoreProvider).loadRecentlyDispatchedOrders();
    } catch (e) {
      debugPrint('OrdersController: local dispatched-orders cache failed: $e');
      return const {};
    }
  }

  /// Marks [incoming] orders as dispatched from two sources: [previous]'s own
  /// in-memory state (keeps a just-dispatched order dispatched across the
  /// very next poll or two, even before head office has recorded it) and
  /// [recentlyWeighed] (head office's durable weigh-event history — the
  /// source that survives an app restart, a Settings change that rebuilds the
  /// order repository, or a manual retry, none of which [previous] survives).
  List<Order> _reconcileDispatched(
    List<Order> incoming, {
    List<Order>? previous,
    Map<String, String?> recentlyWeighed = const {},
  }) {
    final prevById = previous == null ? null : {for (final o in previous) o.id: o};
    return [
      for (final o in incoming)
        if (prevById?[o.id]?.status == OrderStatus.dispatched)
          o.copyWith(
            status: OrderStatus.dispatched,
            overrideReason: prevById![o.id]!.overrideReason,
          )
        else if (o.status != OrderStatus.dispatched && recentlyWeighed.containsKey(o.id))
          o.copyWith(status: OrderStatus.dispatched, overrideReason: recentlyWeighed[o.id])
        else
          o,
    ];
  }

  /// Re-fetch from the repository, surfacing loading/error through [state].
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final repo = ref.read(orderRepositoryProvider);
      final headOfficeApi = ref.read(headOfficeApiProvider);
      final ordersFuture = repo.fetchOrders();
      final weighedFuture = headOfficeApi?.fetchRecentlyWeighedOrders() ??
          Future.value(const <String, String?>{});
      final localFuture = _loadLocallyDispatched();
      final orders = await ordersFuture;
      final recentlyWeighed = await weighedFuture;
      final local = await localFuture;
      return _reconcileDispatched(orders, recentlyWeighed: {...local, ...recentlyWeighed});
    });
  }

  /// Background sync: re-fetch and update data WITHOUT flashing a loading
  /// spinner, preserving locally dispatched orders. Used by the 10s auto-sync
  /// and the manual "Sync now" button. A transient failure keeps the last good
  /// data on screen rather than showing an error. Deliberately does NOT also
  /// re-check head office's weigh-event history on every poll — the in-memory
  /// `previous` state already carries a dispatched order forward correctly
  /// within a running session, and doing so would mean an extra API call
  /// every 10 seconds for no real benefit; the durable check only matters at
  /// the points a session's own memory can't be trusted (build/refresh above).
  Future<bool> silentRefresh() async {
    try {
      final repo = ref.read(orderRepositoryProvider);
      final fresh = await repo.fetchOrders();
      state = AsyncValue.data(_reconcileDispatched(fresh, previous: state.value));
      return true;
    } catch (e) {
      // Keep the current queue; the next sync will retry.
      return false;
    }
  }

  Order? orderById(String id) {
    final list = state.value;
    if (list == null) return null;
    for (final o in list) {
      if (o.id == id) return o;
    }
    return null;
  }

  void _replace(String id, Order Function(Order) update) {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data([
      for (final o in current) o.id == id ? update(o) : o,
    ]);
  }

  /// Confirm and dispatch. [reason] is required for off-weight orders and is
  /// stored on the order for the audit trail.
  void dispatch(String id, {String? reason}) {
    _replace(
      id,
      (o) => o.copyWith(
        status: OrderStatus.dispatched,
        overrideReason: reason,
      ),
    );
    // Fire-and-forget: a local record of this dispatch surviving an app
    // restart is a safety net (see [_loadLocallyDispatched]), not something
    // the UI needs to wait on.
    unawaited(_persistDispatched(id, reason));
  }

  Future<void> _persistDispatched(String id, String? reason) async {
    try {
      await ref.read(settingsStoreProvider).saveDispatchedOrder(id, overrideReason: reason);
    } catch (e) {
      debugPrint('OrdersController: could not persist dispatched order locally: $e');
    }
  }
}
