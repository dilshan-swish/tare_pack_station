import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/kitchen_stage.dart';
import '../models/order.dart';
import '../models/order_item.dart';
import 'foodics_api.dart';
import 'order_repository.dart';

export 'foodics_api.dart' show FoodicsException;

/// Fetches live orders from the Foodics POS and maps them to [Order]s.
///
/// Design for a pack station:
///  • Realtime — [watchOrders] polls orders relevant to weighing (Pending,
///    Active, or Closed — see [FoodicsApi.listOpenOrders]) for the branch on a
///    short interval; no manual refresh. A "Closed" order isn't finished from
///    a pack-station's point of view — it's often exactly when food is packed
///    and waiting to be weighed — so it stays in scope; declined/returned/
///    joined/void/draft orders don't.
///  • Resilient — the underlying [FoodicsApi] adds timeouts, retries, a
///    Cloudflare-safe User-Agent and clear auth/rate-limit errors. Transient
///    blips during polling are swallowed so the queue keeps the last good data.
///  • Swappable — implements [OrderRepository]; selected purely by config.
///
/// Expected weights are looked up by menu-item id, and Foodics **product ids**
/// are used verbatim as the menu-item ids (via "Sync menu from Foodics"), so
/// live orders line up with weighed data automatically.
class FoodicsOrderRepository extends OrderRepository {
  final FoodicsApi api;
  final String branchId;
  final Duration pollInterval;
  final bool live;

  FoodicsOrderRepository({
    required this.api,
    required this.branchId,
    required this.pollInterval,
    this.live = true,
  });

  @override
  bool get isRealtime => live;

  @override
  Future<List<Order>> fetchOrders() async {
    if (branchId.isEmpty) {
      throw const FoodicsException('No branch selected in Settings.');
    }
    final raw = await api.listOpenOrders(branchId);
    final orders = <Order>[];
    for (final o in raw) {
      try {
        // Foodics orders can sit "open" for weeks (an abandoned kiosk order,
        // for instance) — nobody should be weighing and dispatching one that
        // old, so it's dropped from the live queue entirely rather than
        // confusingly appearing alongside genuinely active orders.
        if (isStaleFoodicsOrder(o)) continue;
        final mapped = _mapOrder(o);
        if (mapped != null) orders.add(mapped);
      } catch (e) {
        // One malformed order (unexpected Foodics shape) must never blank out
        // the whole queue — skip it and keep the rest.
        debugPrint('Foodics order skipped (unmappable): $e');
      }
    }
    return orders;
  }

  @override
  Stream<List<Order>> watchOrders() async* {
    var delivered = false;
    while (true) {
      try {
        final orders = await fetchOrders();
        delivered = true;
        yield orders;
      } catch (e) {
        if (!delivered) rethrow; // surface the very first failure
        debugPrint('Foodics poll skipped (transient): $e');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  @override
  void dispose() => api.dispose();

  // --- mapping ------------------------------------------------------------

  Order? _mapOrder(Map<String, dynamic> j) {
    // The UUID is the truly-unique key (used internally + for the audit).
    // `number` is the staff-facing daily "Order No"; `reference` is the stable
    // account-wide counter shown as the small #ref.
    final orderNumber = (j['number'] as num?)?.toInt();
    final reference = j['reference']?.toString();
    final checkNumber = (j['check_number'] as num?)?.toInt();
    final id = j['id']?.toString() ?? reference ?? orderNumber?.toString();
    if (id == null) return null;

    final customer = j['customer'];
    final rawName =
        customer is Map<String, dynamic> ? customer['name'] as String? : null;
    final customerName = _displayName(rawName, j['type']);

    final (aggregatorName, aggregatorRef) = parseFoodicsAggregator(j['meta']);

    // status 4 (Closed) is when the till side is done — confirmed against the
    // live API, that's also when food is packed and ready to weigh. Anything
    // else we fetch (1 Pending, 2 Active) is still being prepared. Defaults to
    // "preparing" for any unexpected value, rather than assuming ready.
    final kitchenStage = (j['status'] as num?)?.toInt() == 4
        ? KitchenStage.ready
        : KitchenStage.preparing;

    final items = <OrderItem>[];
    final products = j['products'];
    if (products is List) {
      for (final p in products) {
        if (p is! Map<String, dynamic>) continue;
        final product = p['product'];
        final productId =
            product is Map<String, dynamic> ? product['id']?.toString() : null;
        if (productId == null) continue;
        final productName = product is Map<String, dynamic>
            ? product['name']?.toString()
            : null;
        final qty = (p['quantity'] as num?)?.toInt() ?? 1;
        final selected = parseFoodicsSelectedModifiers(p['options']);
        for (var i = 0; i < (qty < 1 ? 1 : qty); i++) {
          items.add(OrderItem(
            menuItemId: productId,
            menuItemName: productName,
            selectedModifierIds: selected.ids,
            selectedModifierNames: selected.names,
          ));
        }
      }
    }

    return Order(
      id: id,
      orderNumber: orderNumber,
      reference: reference,
      checkNumber: checkNumber,
      aggregatorName: aggregatorName,
      aggregatorRef: aggregatorRef,
      customerName: customerName,
      items: items,
      // `due_at` absent just means "no ready-by time was set" — that's not the
      // order's age, so it must not fall back to minutes-since-opened (a long-
      // open order would otherwise show a nonsensical "Ready 7681m").
      readyInMinutes: _minutesUntil(j['due_at']) ?? 0,
      dasherInMinutes: _minutesUntil(j['due_at']) ?? 0,
      receivedAt: parseFoodicsReceivedAt(j),
      kitchenStage: kitchenStage,
    );
  }

  /// "Ahmed K." style label; falls back to an order-type name, then "Guest".
  String _displayName(String? name, Object? type) {
    final n = name?.trim();
    if (n != null && n.isNotEmpty) {
      final parts = n.split(RegExp(r'\s+'));
      if (parts.length == 1) return parts.first;
      return '${parts.first} ${parts.last[0].toUpperCase()}.';
    }
    switch (type) {
      case 1:
        return 'Dine-in';
      case 2:
        return 'Pickup';
      case 3:
        return 'Delivery';
      default:
        return 'Guest';
    }
  }

  int? _minutesUntil(Object? iso) {
    final t = parseFoodicsTimestamp(iso);
    if (t == null) return null;
    final m = t.difference(DateTime.now()).inMinutes;
    return m < 0 ? 0 : m;
  }
}

/// Extracts the delivery aggregator (name + its own order number) from a
/// Foodics order's `meta`, for the confirmation line staff match against the
/// aggregator's own slip. Handles every format seen in the wild and degrades
/// gracefully — any parse failure just returns (null, null) so the UI falls
/// back to the customer name. Never throws.
///
/// Examples of `meta.external_number`:
///   "Mishmash - Talabat: 3815711802, #4887"   -> (Talabat, 4887)
///   "Mishmash - Snoonu: 463327"               -> (Snoonu, 463327)
///   "Mishmash - KeeTa: 3990"                  -> (KeeTa, 3990)
///   "Mishmash - Keeta 2.0: 4874140355579055"  -> (Keeta 2.0, …9055)
///   "Mishmash - Ordable: DQYS-2118"           -> (Ordable, DQYS-2118)
///   "SUNV-4490" / null                        -> (null, null)  [not an aggregator]
(String?, String?) parseFoodicsAggregator(Object? meta) {
  try {
    if (meta is! Map) return (null, null);

    String? name = (meta['external_source'] as Object?)?.toString().trim();
    final external = (meta['external_number'] as Object?)?.toString().trim();

    String? payload;
    if (external != null && external.isNotEmpty) {
      final colon = external.indexOf(':');
      if (colon != -1) {
        // "Mishmash - Talabat: 3815711802, #4887" -> prefix + payload
        final prefix = external.substring(0, colon).trim();
        payload = external.substring(colon + 1).trim();
        if (name == null || name.isEmpty) {
          final dash = prefix.lastIndexOf(' - ');
          name = (dash != -1 ? prefix.substring(dash + 3) : prefix).trim();
        }
      } else {
        // No "Source:" prefix (e.g. "SUNV-4490") — only usable if we already
        // have a source name; otherwise it's not an aggregator order.
        payload = external;
      }
    }

    if (name == null || name.isEmpty) return (null, null);

    String? ref;
    if (payload != null && payload.isNotEmpty) {
      final hash = payload.lastIndexOf('#');
      if (hash != -1) {
        ref = payload.substring(hash + 1).trim();
      } else {
        // Last comma/space-separated token, e.g. the trailing id.
        final tokens =
            payload.split(RegExp(r'[,\s]+')).where((t) => t.isNotEmpty);
        ref = tokens.isEmpty ? null : tokens.last.trim();
      }
      ref = ref?.replaceAll(RegExp(r'^#+'), '').trim();
      // Long all-digit ids (e.g. Keeta's 16-digit) — show the last 4, which
      // is what the aggregator prints on its own slip.
      if (ref != null && RegExp(r'^\d+$').hasMatch(ref) && ref.length > 8) {
        ref = '…${ref.substring(ref.length - 4)}';
      }
    }

    return (name, (ref != null && ref.isNotEmpty) ? ref : null);
  } catch (_) {
    return (null, null);
  }
}

/// Extracts the resolved modifier-option ids a customer actually picked on one
/// order line (e.g. "Curly Fries" instead of the default "Regular Fries", or a
/// specific drink out of "Choice of Drinks") — requires
/// `include=products.options.modifier_option` on the order fetch, which
/// resolves Foodics' opaque per-order option id to the stable catalog id also
/// used to key weighed [Modifier]s. Also returns each id's display name where
/// available, purely so an unweighed selection can be flagged by name (e.g.
/// "Curly Fries not weighed yet") instead of a generic message. Any single
/// malformed option entry is skipped rather than failing the whole line;
/// never throws.
({List<String> ids, Map<String, String> names}) parseFoodicsSelectedModifiers(
    Object? optionsRaw) {
  if (optionsRaw is! List) return (ids: const [], names: const {});
  final ids = <String>[];
  final names = <String, String>{};
  for (final o in optionsRaw) {
    try {
      if (o is! Map) continue;
      final modOption = o['modifier_option'];
      if (modOption is! Map) continue;
      final id = modOption['id']?.toString();
      if (id == null || id.isEmpty) continue;
      ids.add(id);
      final name = modOption['name']?.toString();
      if (name != null && name.isNotEmpty) names[id] = name;
    } catch (_) {
      // Skip this one option; the rest of the line is still usable.
    }
  }
  return (ids: ids, names: names);
}

/// Parses a Foodics timestamp string (e.g. "2026-07-05 15:16:46") into a
/// [DateTime]. Foodics timestamps are always UTC but arrive with no zone
/// suffix — appending "Z" is required so [DateTime.tryParse] treats it as UTC
/// instead of silently assuming the device's own local zone (confirmed
/// against the live API: a fresh order's `opened_at` matched wall-clock UTC,
/// not local time). Returns null for anything unparsable; never throws.
DateTime? parseFoodicsTimestamp(Object? iso) {
  if (iso is! String || iso.isEmpty) return null;
  return DateTime.tryParse('${iso.replaceFirst(' ', 'T')}Z');
}

/// The best available "order received" timestamp for a Foodics order: the
/// kitchen's own receipt of it when present (`meta.foodics.kitchen_received_at`
/// — the most specific, when prep actually started), falling back to the
/// cashier's acceptance (`meta.foodics.cashier_received_at`), then to when the
/// order was first opened (`opened_at` — always present on every order, so
/// this always resolves to something). `kitchen_received_at` in particular is
/// sparse in practice (only set for some auto-accepted orders), which is why a
/// guaranteed fallback matters. Every layer is read defensively; a malformed
/// `meta` shape never throws, it just falls through to the next option.
DateTime? parseFoodicsReceivedAt(Map<String, dynamic> order) {
  try {
    final meta = order['meta'];
    if (meta is Map) {
      final foodics = meta['foodics'];
      if (foodics is Map) {
        final kitchen = parseFoodicsTimestamp(foodics['kitchen_received_at']);
        if (kitchen != null) return kitchen;
        final cashier = parseFoodicsTimestamp(foodics['cashier_received_at']);
        if (cashier != null) return cashier;
      }
    }
  } catch (_) {
    // Fall through to opened_at below.
  }
  return parseFoodicsTimestamp(order['opened_at']);
}

/// Orders left "open" in Foodics longer than this are treated as abandoned
/// (e.g. a stuck kiosk order) rather than something a pack station should
/// still weigh and dispatch, and are dropped from the live queue entirely —
/// they remain visible/fixable in Foodics itself.
const staleOrderThreshold = Duration(hours: 24);

/// True when [order] was opened longer ago than [staleOrderThreshold].
/// Anchored on `opened_at` — the one timestamp present on every order,
/// regardless of source/flow — rather than the more specific but sparser
/// kitchen/cashier-received fields. An order with no parsable open time is
/// never considered stale: missing data must not hide a legitimately active
/// order. [now] defaults to the real current time; tests pass a fixed value.
bool isStaleFoodicsOrder(Map<String, dynamic> order, {DateTime? now}) {
  final openedAt = parseFoodicsTimestamp(order['opened_at']);
  if (openedAt == null) return false;
  return (now ?? DateTime.now()).difference(openedAt) > staleOrderThreshold;
}
