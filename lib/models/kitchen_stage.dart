/// The Foodics order's own kitchen/till lifecycle stage — distinct from
/// [OrderStatus] (in `order_status.dart`), which tracks OUR weight-check
/// lifecycle. Derived from the Foodics `status` field: Pending (1) and Active
/// (2) both mean the kitchen is still working on it; Closed (4) means the
/// till side is done — which, confirmed against the live API (a "Closed"
/// order and "Ready To Deliver" showing together), is also when food is
/// packed and waiting to be weighed and dispatched. The other status codes
/// (Declined, Returned, Joined, Void, Draft) are filtered out before an order
/// ever reaches the app, so they have no representation here.
enum KitchenStage {
  /// Foodics status 1 (Pending) or 2 (Active) — still being prepared.
  preparing,

  /// Foodics status 4 (Closed) — packed and ready for a weight-check.
  ready,
}
