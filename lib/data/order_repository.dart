import '../models/order.dart';
import '../models/order_item.dart';

/// Interface for fetching POS orders. `FoodicsOrderRepository` (hitting the
/// real Foodics REST API) can be swapped in without touching UI code.
abstract class OrderRepository {
  const OrderRepository();

  /// One-shot fetch of the current order queue.
  Future<List<Order>> fetchOrders();

  /// Whether this repository pushes realtime updates via [watchOrders].
  /// Defaults to false so a simple/mocked repo needs no extra code.
  bool get isRealtime => false;

  /// A realtime stream of order-queue snapshots. The default is an empty
  /// stream; realtime repositories (e.g. Foodics polling) override it.
  Stream<List<Order>> watchOrders() => const Stream.empty();

  /// Release any resources (HTTP clients, timers). No-op by default.
  void dispose() {}
}

/// Generates a handful of realistic sample orders. There is no per-order
/// measured weight — the station has one scale, so the measured weight is a
/// single shared value and each order's verdict is derived live from it.
class MockOrderRepository extends OrderRepository {
  const MockOrderRepository();

  @override
  Future<List<Order>> fetchOrders() async {
    // Simulate a little network latency like a real integration would have.
    await Future<void>.delayed(const Duration(milliseconds: 350));

    final now = DateTime.now();
    DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));

    return [
      Order(
        id: '8712318',
        orderNumber: 12,
        checkNumber: 130840,
        aggregatorName: 'Talabat',
        aggregatorRef: '5070',
        customerName: 'Hamid S.',
        readyInMinutes: 9,
        dasherInMinutes: 4,
        receivedAt: ago(11),
        items: const [
          OrderItem(
            menuItemId: 'mi_beef_taco',
            selectedModifierIds: ['mod_breadcrumbs', 'mod_jalapenos', 'mod_sauce'],
          ),
          OrderItem(
            menuItemId: 'mi_steak_fajita_mac',
            selectedModifierIds: ['mod_breadcrumbs2', 'mod_jalapenos2'],
          ),
          OrderItem(menuItemId: 'mi_soft_drink'),
        ],
      ),
      Order(
        id: '8712319',
        orderNumber: 13,
        checkNumber: 130841,
        aggregatorName: 'Keeta 2.0',
        aggregatorRef: '…3635',
        customerName: 'Layla K.',
        readyInMinutes: 6,
        dasherInMinutes: 3,
        receivedAt: ago(19),
        items: const [
          OrderItem(
            menuItemId: 'mi_zinger',
            selectedModifierIds: ['mod_cheese', 'mod_pickles'],
          ),
          OrderItem(
            menuItemId: 'mi_loaded_fries',
            selectedModifierIds: ['mod_cheese2', 'mod_bacon'],
          ),
          OrderItem(menuItemId: 'mi_onion_rings'),
        ],
      ),
      Order(
        id: '8712320',
        orderNumber: 14,
        checkNumber: 130842,
        customerName: 'Omar T.',
        readyInMinutes: 12,
        dasherInMinutes: 6,
        receivedAt: ago(23),
        items: const [
          OrderItem(
            menuItemId: 'mi_zinger',
            selectedModifierIds: ['mod_cheese', 'mod_pickles'],
          ),
          OrderItem(menuItemId: 'mi_onion_rings'),
          OrderItem(menuItemId: 'mi_soft_drink'),
        ],
      ),
      Order(
        id: '8712321',
        orderNumber: 15,
        checkNumber: 130843,
        customerName: 'Sara M.',
        readyInMinutes: 5,
        dasherInMinutes: 5,
        receivedAt: ago(15),
        items: const [
          OrderItem(
            menuItemId: 'mi_beef_taco',
            selectedModifierIds: ['mod_jalapenos'],
          ),
          OrderItem(
            menuItemId: 'mi_loaded_fries',
            selectedModifierIds: ['mod_bacon'],
          ),
          OrderItem(menuItemId: 'mi_soft_drink'),
        ],
      ),
      Order(
        id: '8712322',
        orderNumber: 16,
        checkNumber: 130844,
        customerName: 'Yousef A.',
        readyInMinutes: 14,
        dasherInMinutes: 7,
        receivedAt: ago(26),
        items: const [
          OrderItem(
            menuItemId: 'mi_steak_fajita_mac',
            selectedModifierIds: ['mod_breadcrumbs2', 'mod_jalapenos2'],
          ),
          OrderItem(
            menuItemId: 'mi_loaded_fries',
            selectedModifierIds: ['mod_cheese2', 'mod_bacon'],
          ),
          OrderItem(menuItemId: 'mi_soft_drink'),
        ],
      ),
      Order(
        id: '8712323',
        orderNumber: 17,
        checkNumber: 130845,
        customerName: 'Nour F.',
        readyInMinutes: 8,
        dasherInMinutes: 4,
        receivedAt: ago(17),
        items: const [
          OrderItem(
            menuItemId: 'mi_zinger',
            selectedModifierIds: ['mod_cheese'],
          ),
          OrderItem(
            menuItemId: 'mi_beef_taco',
            selectedModifierIds: ['mod_sauce'],
          ),
          OrderItem(menuItemId: 'mi_onion_rings'),
        ],
      ),
    ];
  }
}
