import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';

Order _order({int? orderNumber, String? reference, String customerName = 'Test Customer'}) {
  return Order(
    id: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890', // a real Foodics order id: long, never shown to staff
    orderNumber: orderNumber,
    reference: reference,
    customerName: customerName,
    items: const [OrderItem(menuItemId: 'mi_x')],
    readyInMinutes: 0,
    dasherInMinutes: 0,
  );
}

void main() {
  // Regression test for a real report: the "Confirm and dispatch" SnackBar
  // showed the raw (long, Foodics-UUID) order id instead of the short,
  // staff-facing number — e.g. "Order #a1b2c3d4-e5f6-... marked ready for
  // pickup" instead of "Order 63 marked ready for pickup". `displayTitle` is
  // the one place this formatting lives; every screen (including that
  // SnackBar) must go through it rather than reading `order.id` directly.
  test('a friendly daily order number shows as "Order 63", never the raw id',
      () {
    final order = _order(orderNumber: 63);
    expect(order.displayTitle, 'Order 63');
    expect(order.displayTitle, isNot(contains('a1b2c3d4')));
  });

  test('no order number falls back to the account reference, still never '
      'the raw id', () {
    final order = _order(reference: 'REF-9981');
    expect(order.displayTitle, '#REF-9981');
    expect(order.displayTitle, isNot(contains('a1b2c3d4')));
  });

  test('neither number nor reference falls back to the customer name', () {
    final order = _order(customerName: 'Sara M.');
    expect(order.displayTitle, 'Sara M.');
  });
}
