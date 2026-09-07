/// The weight-check state of an order.
enum OrderStatus {
  /// Not yet weighed.
  pending,

  /// Measured weight is within tolerance of expected.
  onWeight,

  /// Measured weight is below tolerance.
  under,

  /// Measured weight is above tolerance.
  over,

  /// Confirmed and sent to the driver.
  dispatched,
}

extension OrderStatusX on OrderStatus {
  bool get isOffWeight => this == OrderStatus.under || this == OrderStatus.over;
}
