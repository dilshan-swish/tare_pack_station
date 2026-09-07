import '../models/menu_item.dart';
import '../models/modifier.dart';

/// Synthetic menu data used ONLY to generate/evaluate the AI discrepancy
/// model (see tool/train_discrepancy_model.dart and its test) — realistic
/// mean weights + std devs the trainer samples from to build labelled
/// training data. Not used by the running app: real weight-checks always
/// come from the head-office portal (see menuIndexProvider).
class MenuSeed {
  MenuSeed._();

  static List<MenuItem> items() => [
        const MenuItem(
          id: 'mi_zinger',
          name: 'Zinger burger',
          baseWeightGrams: 240,
          baseWeightStdDev: 8,
          packagingWeightGrams: 25,
          availableModifiers: [
            Modifier(id: 'mod_cheese', name: 'Cheese', weightGrams: 18, weightStdDev: 2),
            Modifier(id: 'mod_pickles', name: 'Pickles', weightGrams: 8, weightStdDev: 2),
          ],
        ),
        const MenuItem(
          id: 'mi_onion_rings',
          name: 'Onion rings',
          baseWeightGrams: 95,
          baseWeightStdDev: 6,
          packagingWeightGrams: 15,
        ),
        const MenuItem(
          id: 'mi_beef_taco',
          name: 'Beef taco',
          baseWeightGrams: 135,
          baseWeightStdDev: 7,
          packagingWeightGrams: 12,
          availableModifiers: [
            Modifier(id: 'mod_breadcrumbs', name: 'Breadcrumbs', weightGrams: 10, weightStdDev: 2),
            Modifier(id: 'mod_jalapenos', name: 'Jalapenos', weightGrams: 6, weightStdDev: 2),
            Modifier(id: 'mod_sauce', name: 'Extra sauce', weightGrams: 20, weightStdDev: 4),
          ],
        ),
        const MenuItem(
          id: 'mi_steak_fajita_mac',
          name: 'Steak fajita mac',
          baseWeightGrams: 265,
          baseWeightStdDev: 12,
          packagingWeightGrams: 20,
          availableModifiers: [
            Modifier(id: 'mod_breadcrumbs2', name: 'Breadcrumbs', weightGrams: 10, weightStdDev: 2),
            Modifier(id: 'mod_jalapenos2', name: 'Jalapenos', weightGrams: 6, weightStdDev: 2),
          ],
        ),
        const MenuItem(
          id: 'mi_loaded_fries',
          name: 'Loaded fries',
          baseWeightGrams: 180,
          baseWeightStdDev: 10,
          packagingWeightGrams: 18,
          availableModifiers: [
            Modifier(id: 'mod_cheese2', name: 'Cheese', weightGrams: 20, weightStdDev: 3),
            Modifier(id: 'mod_bacon', name: 'Bacon bits', weightGrams: 15, weightStdDev: 3),
          ],
        ),
        const MenuItem(
          id: 'mi_soft_drink',
          name: 'Soft drink (large)',
          baseWeightGrams: 420,
          baseWeightStdDev: 10,
          packagingWeightGrams: 30,
        ),
      ];
}
