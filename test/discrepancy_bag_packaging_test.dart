import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/ai/discrepancy.dart';
import 'package:tare_pack_station/ai/discrepancy_engine.dart';
import 'package:tare_pack_station/ai/discrepancy_model_config.dart';
import 'package:tare_pack_station/logic/weight_evaluator.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/models/tolerance_settings.dart';

/// Regression test for a real report: a bag missing its K&M Sauce (packed as
/// its own separate order line, not a modifier) measured 541g against a
/// 628g target, and the AI insight named "Likely normal pack variation" as
/// the top explanation instead of the sauce — even though 628 − 541 = 87g,
/// exactly the sauce's own weight.
///
/// Root cause: the brand had a bag-packaging range configured (75g, 65–90g)
/// — the exact "Bag and extras" line the receipt shows — but
/// WeightInferenceEngine.analyze() never received it, so its own internal
/// "expected" total for the order silently excluded that 75g. Every
/// hypothesis was then scored against the wrong (75g-too-small) baseline:
/// the true, dead-on-target "missing sauce" explanation looked artificially
/// terrible (residual off by 75g), while "just normal variation" looked
/// artificially plausible (its own apparent gap having shrunk from 87g to a
/// much less alarming 12g). Fixed by threading BagPackaging/bagCount through
/// to the engine, mirroring exactly what WeightEvaluator.expectedFor already
/// added to produce the 628g target the verdict itself was judged against.
void main() {
  const engine = WeightInferenceEngine(DiscrepancyModelConfig.fallback);
  const tol = ToleranceSettings.defaults;

  const beef = MenuItem(id: 'mi_beef', name: 'SUUUBER™ BEEF', baseWeightGrams: 302);
  const oldSkool = MenuItem(id: 'mi_oldskool', name: 'Classic Old Skool', baseWeightGrams: 164);
  const sauce = MenuItem(id: 'mi_kmsauce', name: 'K&M SAUCE', baseWeightGrams: 87);
  final menuIndex = {beef.id: beef, oldSkool.id: oldSkool, sauce.id: sauce};

  final order = const Order(
    id: 'order_250',
    orderNumber: 250,
    customerName: 'Test Customer',
    readyInMinutes: 0,
    dasherInMinutes: 0,
    items: [
      OrderItem(menuItemId: 'mi_beef'),
      OrderItem(menuItemId: 'mi_oldskool'),
      OrderItem(menuItemId: 'mi_kmsauce'),
    ],
  );

  const bag = BagPackaging(idealGrams: 75, minGrams: 65, maxGrams: 90);

  // The real order's own accept range (598g–670g around a 628g target) —
  // passed explicitly, exactly as analyzeDiscrepancy passes
  // WeightEvaluator.rangeFor's output, so the on/off-weight GATE itself
  // (already correct before this fix, since it comes from the evaluator)
  // is decided the same way in every test below. What's under test here is
  // only what happens AFTER that gate — which explanation the model picks.
  const windowMin = 598.0;
  const windowMax = 670.0;

  test(
      'a bag missing an item worth exactly the shortfall is identified, not '
      'dismissed as normal variation, once bag packaging is passed through',
      () {
    // 302 + 164 + 87 + 75 (bag) = 628 expected; measured 541 -> -87, exactly
    // K&M Sauce's own weight.
    final r = engine.analyze(
      order: order,
      measuredGrams: 541,
      menuIndex: menuIndex,
      tolerance: tol,
      bagPackaging: bag,
      bagCount: 1,
      windowMinGrams: windowMin,
      windowMaxGrams: windowMax,
    );

    expect(r.deltaGrams, closeTo(-87, 0.01),
        reason: 'the engine\'s own internal delta must match the 628g target '
            'the on-screen verdict was judged against, bag included');
    expect(r.hasPredictions, isTrue);
    expect(r.top!.kind, PredictionKind.missingItem);
    expect(r.top!.refId, 'mi_kmsauce');
    expect(r.top!.title, contains('K&M SAUCE'));
    expect(r.top!.confidence, greaterThan(0.9),
        reason: 'a near-perfect residual match should dominate the softmax, '
            'not tie with or lose to natural variation');
    expect(r.top!.suggestedReasonTag, 'Item left off scale');
  });

  test(
      'omitting the brand\'s configured bag (the pre-fix call shape) '
      'reproduces the original bug: variation beats the real answer', () {
    final withoutBag = engine.analyze(
      order: order,
      measuredGrams: 541,
      menuIndex: menuIndex,
      tolerance: tol,
      windowMinGrams: windowMin,
      windowMaxGrams: windowMax,
      // bagPackaging omitted -> BagPackaging.none, matching every call site
      // before this fix.
    );

    expect(withoutBag.deltaGrams, closeTo(-12, 0.01),
        reason: 'without the bag, the engine\'s own baseline (553g) is short '
            'by the bag\'s 75g, so its internal gap is a misleadingly small 12g');
    expect(withoutBag.top!.kind, PredictionKind.naturalVariation,
        reason: 'this is the exact bug: a small apparent gap makes "normal '
            'variation" look right, and the real culprit (K&M Sauce, now '
            'scored against the wrong baseline) looks like a terrible fit');
  });

  test('a correctly packed bag (measured 628g) is on-weight and inconclusive',
      () {
    final r = engine.analyze(
      order: order,
      measuredGrams: 628,
      menuIndex: menuIndex,
      tolerance: tol,
      bagPackaging: bag,
      bagCount: 1,
      windowMinGrams: windowMin,
      windowMaxGrams: windowMax,
    );
    expect(r.predictions, isEmpty);
  });

  test('bagCount scales the bag\'s own contribution for a multi-bag order',
      () {
    // Two bags: 302+164+87 + 75*2 = 703 expected. Missing the sauce from
    // ONE of the two bags still measures -87 off that total.
    final r = engine.analyze(
      order: order,
      measuredGrams: 703 - 87,
      menuIndex: menuIndex,
      tolerance: tol,
      bagPackaging: bag,
      bagCount: 2,
    );
    expect(r.deltaGrams, closeTo(-87, 0.01));
    expect(r.top!.kind, PredictionKind.missingItem);
    expect(r.top!.refId, 'mi_kmsauce');
  });
}
