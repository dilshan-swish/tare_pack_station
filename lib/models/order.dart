import 'kitchen_stage.dart';
import 'order_item.dart';
import 'order_status.dart';

/// An order pulled from the POS, awaiting a weight check.
class Order {
  /// Unique, stable id — the Foodics order UUID for live orders. Used internally
  /// (navigation, dispatch, weigh-event audit); not shown to staff.
  final String id;

  /// The staff-facing "Order No" printed on the receipt (Foodics `number`).
  /// Small, resets per branch per day, not globally unique. Nullable.
  final int? orderNumber;

  /// The account-wide reference counter (Foodics `reference`) — stable and
  /// traceable; kept for the audit trail and used as a heading fallback when an
  /// order has no friendly `number`. Nullable.
  final String? reference;

  /// The Foodics check number (`check_number`). Prints on the POS receipt as
  /// "Check# …" — the secondary figure staff cross-check against the receipt.
  /// Nullable.
  final int? checkNumber;

  /// The delivery aggregator this order came through (Talabat, Keeta, Snoonu,
  /// Ordable…), derived from Foodics `meta.external_source`. Null for dine-in /
  /// walk-in orders that have a real customer instead.
  final String? aggregatorName;

  /// The aggregator's own order number (e.g. Talabat "#5070", Keeta "…3635") —
  /// derived from `meta.external_number` — so staff can cross-check against the
  /// aggregator's own slip. Null when unavailable.
  final String? aggregatorRef;

  final String customerName;
  final List<OrderItem> items;
  final int readyInMinutes;
  final int dasherInMinutes;
  final OrderStatus status;

  /// When the order was placed/opened (Foodics `opened_at`), for the "received
  /// at" time shown to staff. Null if the source didn't provide one.
  final DateTime? receivedAt;

  /// The kitchen/till's own prep stage (Foodics `status`) — still preparing,
  /// or packed and ready to weigh. Defaults to [KitchenStage.ready] for
  /// sources that don't provide it (mock data), matching a ready-to-weigh demo.
  final KitchenStage kitchenStage;

  /// Reason chosen when an off-weight order is dispatched (nullable).
  final String? overrideReason;

  const Order({
    required this.id,
    required this.customerName,
    required this.items,
    required this.readyInMinutes,
    required this.dasherInMinutes,
    this.orderNumber,
    this.reference,
    this.checkNumber,
    this.aggregatorName,
    this.aggregatorRef,
    this.receivedAt,
    this.kitchenStage = KitchenStage.ready,
    this.status = OrderStatus.pending,
    this.overrideReason,
  });

  int get itemCount => items.length;

  bool get _hasReference => reference != null && reference!.trim().isNotEmpty;

  /// The bold heading on cards/receipt. We always lead with a *number*, never a
  /// bare name: the friendly daily "Order No" (Foodics `number`) when present,
  /// otherwise the always-present account `reference`. Only if an order somehow
  /// has neither do we fall back to the customer name.
  String get displayTitle {
    if (orderNumber != null) return 'Order $orderNumber';
    if (_hasReference) return '#${reference!.trim()}';
    return customerName;
  }

  /// The aggregator confirmation label — e.g. "Talabat #5070", "Keeta 2.0 #…3635",
  /// "Ordable #DQYS-2118". Null when this isn't an aggregator order.
  String? get aggregatorLabel {
    final name = aggregatorName?.trim();
    if (name == null || name.isEmpty) return null;
    final ref = aggregatorRef?.trim();
    return (ref == null || ref.isEmpty) ? name : '$name #$ref';
  }

  /// The secondary line under the title. For delivery orders this is the
  /// aggregator + its own number ("Talabat #5070") so staff can confirm against
  /// the aggregator's slip; for dine-in / walk-in it's the customer name.
  /// Suppressed only when it would just repeat the title, or when empty.
  String? get displaySubtitle {
    final agg = aggregatorLabel;
    if (agg != null) return agg;
    final n = customerName.trim();
    if (n.isEmpty) return null;
    if (orderNumber == null && !_hasReference) return null;
    return n;
  }

  /// The small secondary tag beside the title: the Foodics check number,
  /// matching the POS receipt's "Check# …" so staff can confirm against the
  /// same slip they're holding. Null when the order has no check number.
  String? get displayCheck => checkNumber != null ? 'Check# $checkNumber' : null;

  Order copyWith({
    OrderStatus? status,
    String? overrideReason,
    bool clearOverrideReason = false,
  }) {
    return Order(
      id: id,
      orderNumber: orderNumber,
      reference: reference,
      checkNumber: checkNumber,
      aggregatorName: aggregatorName,
      aggregatorRef: aggregatorRef,
      customerName: customerName,
      items: items,
      readyInMinutes: readyInMinutes,
      dasherInMinutes: dasherInMinutes,
      receivedAt: receivedAt,
      kitchenStage: kitchenStage,
      status: status ?? this.status,
      overrideReason:
          clearOverrideReason ? null : (overrideReason ?? this.overrideReason),
    );
  }
}
