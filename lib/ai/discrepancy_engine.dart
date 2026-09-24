import 'dart:math' as math;

import '../logic/modifier_pairing.dart';
import '../logic/weight_evaluator.dart';
import '../models/menu_item.dart';
import '../models/order.dart';
import '../models/tolerance_settings.dart';
import 'discrepancy.dart';
import 'discrepancy_model_config.dart';

/// Abstract discrepancy engine. Kept behind an interface so a different
/// implementation (a cloud model, a bigger local net, …) can be swapped in
/// without touching the UI — mirroring the `WeightSource` / `OrderRepository`
/// pattern used elsewhere in the app.
abstract class DiscrepancyEngine {
  DiscrepancyResult analyze({
    required Order order,
    required double measuredGrams,
    required Map<String, MenuItem> menuIndex,
    required ToleranceSettings tolerance,
    List<Order> otherOrders,
    double? windowMinGrams,
    double? windowMaxGrams,
    ModifierCombinationIndex? combinationIndex,
    // Brand-level "one bag's worth of packaging" (see WeightEvaluator) —
    // should ALWAYS be passed whenever the brand has one configured, exactly
    // mirroring what WeightEvaluator.expectedFor added to reach
    // `measuredGrams`'s own target. Leaving it at the default (none) when the
    // brand actually has one configured doesn't just shift every
    // hypothesis's fit by a constant — it corrupts WHICH hypothesis looks
    // best, since "missing item" hypotheses are scored by how much of the
    // (now wrongly small) gap each component's own weight would explain.
    BagPackaging bagPackaging = BagPackaging.none,
    int bagCount = 1,
  });
}

/// One weighable piece of an order (an item's base+packaging, or one modifier).
class _Component {
  final String label;
  final String refId;
  final double mean;
  final double variance;
  final bool isWholeItem;
  const _Component(
    this.label,
    this.refId,
    this.mean,
    this.variance, {
    this.isWholeItem = false,
  });
}

/// A candidate explanation before it is turned into a [Prediction].
class _Hypothesis {
  final PredictionKind kind;
  final String title;
  final String detail;
  final double weightAccounted; // signed
  final double residual; // measured − predictedMean
  final double sigma; // sd of that residual
  final String? refId;
  final String? relatedOrderId;
  final String? relatedOrderLabel;
  final String? reasonTag;
  final double prior;
  _Hypothesis({
    required this.kind,
    required this.title,
    required this.detail,
    required this.weightAccounted,
    required this.residual,
    required this.sigma,
    required this.prior,
    this.refId,
    this.relatedOrderId,
    this.relatedOrderLabel,
    this.reasonTag,
  });

  /// log(prior) + log-likelihood of the observed residual under this hypothesis
  /// (dropping the constant −½·log(2π) shared by every hypothesis).
  double logScore() {
    final z = residual / sigma;
    return math.log(prior) - 0.5 * z * z - math.log(sigma);
  }
}

/// The on-device probabilistic model.
///
/// It does not guess with a language model — it reasons over the *known* weight
/// distribution of every menu component. Given how far the bag is from the
/// order's expected weight, it scores each possible cause (a missing item, an
/// extra item, a mixed-up order, or plain pack variation) with a Gaussian
/// likelihood, combines that with trained priors, and returns calibrated
/// probabilities. That makes it precise and, crucially, honest about
/// uncertainty — exactly what a dispatch safety check needs.
class WeightInferenceEngine implements DiscrepancyEngine {
  final DiscrepancyModelConfig config;
  const WeightInferenceEngine(this.config);

  @override
  DiscrepancyResult analyze({
    required Order order,
    required double measuredGrams,
    required Map<String, MenuItem> menuIndex,
    required ToleranceSettings tolerance,
    List<Order> otherOrders = const [],
    double? windowMinGrams,
    double? windowMaxGrams,
    ModifierCombinationIndex? combinationIndex,
    BagPackaging bagPackaging = BagPackaging.none,
    int bagCount = 1,
  }) {
    final combinations = combinationIndex ?? ModifierCombinationIndex.empty;
    final components = _componentsOf(order, menuIndex, combinations, bagPackaging);
    var expected = components.fold<double>(0, (s, c) => s + c.mean);
    var variance = components.fold<double>(0, (s, c) => s + c.variance);
    // Must match WeightEvaluator.expectedFor's own bag-packaging term exactly
    // — this order's `measuredGrams` was judged (for the on/under/over
    // verdict shown on screen) against an expected total that already
    // includes it, so the model's internal baseline has to too, or every
    // hypothesis below is scored against the wrong gap.
    final bag = _bagContribution(bagPackaging, bagCount);
    expected += bag.mean;
    variance += bag.variance;
    final sigmaOrder = math.sqrt(variance);
    final delta = measuredGrams - expected;

    // Decide "on weight" using an explicit Min/Max range when supplied (BBT
    // standards), otherwise the computed tolerance window. `window` is the
    // effective half-width used for internal comparisons (wrong-order margin).
    final bool onWeight;
    final double window;
    if (windowMinGrams != null && windowMaxGrams != null) {
      onWeight =
          measuredGrams >= windowMinGrams && measuredGrams <= windowMaxGrams;
      window = (windowMaxGrams - windowMinGrams) / 2;
    } else {
      window = tolerance.toleranceGrams(
        expectedGrams: expected,
        combinedStdDev: sigmaOrder,
      );
      onWeight = delta.abs() <= window;
    }

    // On weight — nothing to explain.
    if (onWeight) {
      return DiscrepancyResult(
        deltaGrams: delta,
        predictions: const [],
        wrongOrderSuspected: false,
        modelVersion: config.version,
      );
    }

    final noise2 = config.scaleNoiseGrams * config.scaleNoiseGrams;
    final hypotheses = <_Hypothesis>[];

    // Always consider "just natural variation / still settling".
    hypotheses.add(_Hypothesis(
      kind: PredictionKind.naturalVariation,
      title: 'Likely normal pack variation',
      detail: 'The gap is close to the usual spread — re-weigh to confirm.',
      weightAccounted: 0,
      residual: delta,
      sigma: math.sqrt(variance + noise2),
      prior: config.priorNaturalVariation,
      reasonTag: 'Weight should be correct',
    ));

    if (delta < 0) {
      // UNDER — something appears to be missing.
      // Whole item missing: aggregate each order line into one hypothesis.
      final wholeItems = _wholeItemComponents(order, menuIndex, combinations, bagPackaging);
      for (final c in wholeItems) {
        final predictedMean = expected - c.mean;
        hypotheses.add(_Hypothesis(
          kind: PredictionKind.missingItem,
          title: 'Missing: ${c.label}',
          detail: '≈ ${_g(c.mean)} would close the gap.',
          weightAccounted: -c.mean,
          residual: measuredGrams - predictedMean,
          sigma: math.sqrt(math.max(variance - c.variance, 0) + noise2),
          prior: config.priorMissingItem,
          refId: c.refId,
          reasonTag: 'Item left off scale',
        ));
      }
      // Just the item's own body/base — its modifiers each stayed. A canned
      // drink, a sauce cup, a seasoning packet are physically separate
      // objects from the food itself; leaving out only the food while
      // everything else on that line stays in the bag is at least as common
      // a real failure as the whole line disappearing together, and the
      // "whole item" hypothesis above fits it badly (it's scored against
      // the item PLUS every modifier vanishing, not the item alone). Only
      // added for a line that actually HAS modifiers/inclusions — one with
      // none is already identical to the whole-item hypothesis above, so a
      // second copy would only dilute the ranking with a duplicate.
      for (final line in order.items) {
        final mi = menuIndex[line.menuItemId];
        if (mi == null) continue;
        final slots = [
          ...resolveSelectedModifiers(mi, line.selectedModifierIds, combinations),
          ...resolveFixedInclusions(mi),
        ];
        if (slots.isEmpty) continue;
        final bodyMean =
            mi.baseWeightGrams + (bagPackaging.isConfigured ? 0 : mi.packagingWeightGrams);
        final bodyVariance = mi.baseWeightStdDev * mi.baseWeightStdDev;
        final predictedMean = expected - bodyMean;
        hypotheses.add(_Hypothesis(
          kind: PredictionKind.missingItem,
          title: 'Missing: ${mi.name} itself',
          detail: '≈ ${_g(bodyMean)} would close the gap — its add-ons are still packed.',
          weightAccounted: -bodyMean,
          residual: measuredGrams - predictedMean,
          sigma: math.sqrt(math.max(variance - bodyVariance, 0) + noise2),
          prior: config.priorMissingItem,
          refId: mi.id,
          reasonTag: 'Item left off scale',
        ));
      }
      // Single modifier missing.
      for (final c in components.where((c) => !c.isWholeItem)) {
        final predictedMean = expected - c.mean;
        hypotheses.add(_Hypothesis(
          kind: PredictionKind.missingModifier,
          title: 'Missing add-on: ${c.label}',
          detail: '≈ ${_g(c.mean)} would close the gap.',
          weightAccounted: -c.mean,
          residual: measuredGrams - predictedMean,
          sigma: math.sqrt(math.max(variance - c.variance, 0) + noise2),
          prior: config.priorMissingModifier,
          refId: c.refId,
          reasonTag: 'No free extra / sauce',
        ));
      }
    } else {
      // OVER — something extra appears to be present.
      // Candidates are deliberately NOT "every item this brand sells" — with a
      // full catalog (often hundreds of items) there is almost always some
      // unrelated item whose weight happens to match the gap by pure chance,
      // which is exactly why this used to suggest items nowhere near the
      // order. The only physically plausible way a whole extra item ends up
      // in this bag is a mix-up with another order actually in the queue
      // right now, so that queue is the candidate pool.
      final candidateItemIds = <String>{};
      for (final other in otherOrders) {
        if (other.id == order.id) continue;
        for (final line in other.items) {
          candidateItemIds.add(line.menuItemId);
        }
      }
      for (final itemId in candidateItemIds) {
        final mi = menuIndex[itemId];
        if (mi == null) continue;
        final extra = mi.baseWeightGrams + mi.packagingWeightGrams;
        final predictedMean = expected + extra;
        hypotheses.add(_Hypothesis(
          kind: PredictionKind.extraItem,
          title: 'Extra item: ${mi.name}',
          detail: '≈ ${_g(extra)} heavier — may be from another order.',
          weightAccounted: extra,
          residual: measuredGrams - predictedMean,
          sigma: math.sqrt(
            variance + mi.baseWeightStdDev * mi.baseWeightStdDev + noise2,
          ),
          prior: config.priorExtraItem,
          refId: mi.id,
          reasonTag: 'Extra portion added',
        ));
      }
      // Extra modifier / portion — from the modifiers available on the order.
      final seen = <String>{};
      for (final line in order.items) {
        final mi = menuIndex[line.menuItemId];
        if (mi == null) continue;
        for (final mod in mi.availableModifiers) {
          // Not weighed yet — nothing to hypothesize a candidate weight from.
          if (mod.weightGrams == null) continue;
          if (!seen.add(mod.id)) continue;
          final modWeight = mod.weightGrams!;
          final predictedMean = expected + modWeight;
          hypotheses.add(_Hypothesis(
            kind: PredictionKind.extraModifier,
            title: 'Extra add-on: ${mod.name}',
            detail: '≈ ${_g(modWeight)} heavier than expected.',
            weightAccounted: modWeight,
            residual: measuredGrams - predictedMean,
            sigma: math.sqrt(
              variance + mod.weightStdDev * mod.weightStdDev + noise2,
            ),
            prior: config.priorExtraModifier,
            refId: mod.id,
            reasonTag: 'Extra sauce / sides',
          ));
        }
      }
    }

    // Wrong-order (mix-up): does another queued order fit the bag better?
    for (final other in otherOrders) {
      if (other.id == order.id) continue;
      final otherComps = _componentsOf(other, menuIndex, combinations, bagPackaging);
      var otherExpected = otherComps.fold<double>(0, (s, c) => s + c.mean);
      var otherVar = otherComps.fold<double>(0, (s, c) => s + c.variance);
      // A queued order not yet weighed has no captured-bag-count of its own
      // to go by — 1 bag is the same assumption WeightEvaluator itself makes
      // by default.
      final otherBag = _bagContribution(bagPackaging, 1);
      otherExpected += otherBag.mean;
      otherVar += otherBag.variance;
      final residual = measuredGrams - otherExpected;
      // Staff-facing label — the order's own internal id is a Foodics UUID,
      // never something a person should have to read (same rule as the
      // branch id elsewhere). displayTitle/displaySubtitle are the same
      // human-readable pair shown on that order's own card in the queue.
      final label = other.displaySubtitle == null
          ? other.displayTitle
          : '${other.displayTitle} · ${other.displaySubtitle}';
      hypotheses.add(_Hypothesis(
        kind: PredictionKind.wrongOrder,
        title: 'Might be $label',
        detail: 'The weight matches that order (${_g(otherExpected)}).',
        weightAccounted: otherExpected - expected,
        residual: residual,
        sigma: math.sqrt(otherVar + noise2),
        prior: config.priorWrongOrder,
        refId: other.id,
        relatedOrderId: other.id,
        relatedOrderLabel: label,
        reasonTag: 'Wrong item packed',
      ));
    }

    // Score → calibrated probabilities via a tempered softmax.
    final maxLog = hypotheses
        .map((h) => h.logScore())
        .reduce((a, b) => a > b ? a : b);
    final temp = config.confidenceTemperature <= 0
        ? 1.0
        : config.confidenceTemperature;
    double sumExp = 0;
    final exps = <double>[];
    for (final h in hypotheses) {
      final e = math.exp((h.logScore() - maxLog) / temp);
      exps.add(e);
      sumExp += e;
    }
    if (sumExp <= 0 || sumExp.isNaN) {
      return DiscrepancyResult(
        deltaGrams: delta,
        predictions: [_inconclusive()],
        wrongOrderSuspected: false,
        modelVersion: config.version,
      );
    }

    final scored = <MapEntry<_Hypothesis, double>>[
      for (var i = 0; i < hypotheses.length; i++)
        MapEntry(hypotheses[i], exps[i] / sumExp),
    ]..sort((a, b) => b.value.compareTo(a.value));

    // A wrong-order mix-up is suspected when another order fits within the
    // tolerance window and clearly better than the selected one.
    final wrongOrderSuspected = scored.any((e) =>
        e.key.kind == PredictionKind.wrongOrder &&
        e.key.residual.abs() <= window &&
        e.key.residual.abs() + config.wrongOrderMarginGrams < delta.abs() &&
        e.value >= config.minConfidenceToShow);

    final predictions = <Prediction>[];
    for (final entry in scored) {
      if (entry.value < config.minConfidenceToShow) continue;
      final h = entry.key;
      // Only surface component explanations that actually shrink the gap.
      if ((h.kind.isMissing || h.kind.isExtra) &&
          h.residual.abs() >= delta.abs()) {
        continue;
      }
      predictions.add(Prediction(
        kind: h.kind,
        title: h.title,
        detail: h.detail,
        confidence: entry.value,
        weightAccountedGrams: h.weightAccounted,
        refId: h.refId,
        relatedOrderId: h.relatedOrderId,
        relatedOrderLabel: h.relatedOrderLabel,
        suggestedReasonTag: h.reasonTag,
      ));
      if (predictions.length >= config.maxSuggestions) break;
    }

    if (predictions.isEmpty) predictions.add(_inconclusive());

    return DiscrepancyResult(
      deltaGrams: delta,
      predictions: predictions,
      wrongOrderSuspected: wrongOrderSuspected,
      modelVersion: config.version,
    );
  }

  Prediction _inconclusive() => const Prediction(
        kind: PredictionKind.inconclusive,
        title: 'No confident explanation',
        detail: 'The weight is off but nothing fits cleanly — check the bag '
            'against the order by hand before dispatching.',
        confidence: 0,
        weightAccountedGrams: 0,
      );

  /// Flat component list: each item contributes a base+packaging component and
  /// one component per selected modifier (fused into one combined component
  /// when a combination override matches all of them — see ModifierCombinationWeight, and
  /// resolveSelectedModifiers for why that's the statistically honest
  /// representation rather than a hack). Unknown ids are skipped.
  ///
  /// [bagPackaging]'s own contribution is added once, separately, by the
  /// caller (see [_bagContribution]) — mirroring WeightEvaluator.expectedFor,
  /// a configured brand-level bag REPLACES each item's legacy per-item
  /// packaging rather than adding to it (never both at once), which is all
  /// [bagPackaging] is used for here.
  List<_Component> _componentsOf(
    Order order,
    Map<String, MenuItem> menuIndex,
    ModifierCombinationIndex combinationIndex,
    BagPackaging bagPackaging,
  ) {
    final out = <_Component>[];
    for (final line in order.items) {
      final mi = menuIndex[line.menuItemId];
      if (mi == null) continue;
      out.add(_Component(
        mi.name,
        mi.id,
        mi.baseWeightGrams + (bagPackaging.isConfigured ? 0 : mi.packagingWeightGrams),
        mi.baseWeightStdDev * mi.baseWeightStdDev,
        // Flagged so it is not treated as a modifier in the "missing add-on"
        // hypotheses — only true modifiers should appear there.
        isWholeItem: true,
      ));
      // Always-included components sit alongside the line's modifiers here
      // deliberately: they are exactly the kind of small, individually
      // omittable thing the "missing add-on" hypotheses exist to name, and
      // they're the likeliest culprit of all since nothing on the order
      // ticket reminds anyone to pack them. See FixedInclusion.
      for (final slot in [
        ...resolveSelectedModifiers(mi, line.selectedModifierIds, combinationIndex),
        ...resolveFixedInclusions(mi),
      ]) {
        out.add(_Component(
          slot.label,
          slot.ids.join('+'),
          slot.weightG,
          slot.weightStdDev * slot.weightStdDev,
        ));
      }
    }
    return out;
  }

  /// One component per order line, aggregating the item's base+packaging plus
  /// all its selected modifiers — used for the "whole item missing" case. See
  /// [_componentsOf] for why [bagPackaging] only ever suppresses the legacy
  /// per-item packaging term, never adds to it here.
  List<_Component> _wholeItemComponents(
    Order order,
    Map<String, MenuItem> menuIndex,
    ModifierCombinationIndex combinationIndex,
    BagPackaging bagPackaging,
  ) {
    final out = <_Component>[];
    for (final line in order.items) {
      final mi = menuIndex[line.menuItemId];
      if (mi == null) continue;
      var mean = mi.baseWeightGrams + (bagPackaging.isConfigured ? 0 : mi.packagingWeightGrams);
      var variance = mi.baseWeightStdDev * mi.baseWeightStdDev;
      for (final slot in [
        ...resolveSelectedModifiers(mi, line.selectedModifierIds, combinationIndex),
        ...resolveFixedInclusions(mi),
      ]) {
        mean += slot.weightG;
        variance += slot.weightStdDev * slot.weightStdDev;
      }
      out.add(_Component(mi.name, mi.id, mean, variance, isWholeItem: true));
    }
    return out;
  }

  /// The mean/variance one bag's worth of brand-level packaging contributes
  /// — the exact formula WeightEvaluator.expectedFor uses, so the
  /// discrepancy model's own internal "expected" total for an order always
  /// agrees with the one the on/under/over verdict shown on screen was
  /// judged against. Zero/zero when the brand hasn't configured one.
  ({double mean, double variance}) _bagContribution(
    BagPackaging bagPackaging,
    int bagCount,
  ) {
    if (!bagPackaging.isConfigured) return (mean: 0, variance: 0);
    var variance = 0.0;
    if (bagPackaging.hasRange) {
      final bagStdDev = (bagPackaging.maxGrams! - bagPackaging.minGrams!) / 4 * bagCount;
      variance = bagStdDev * bagStdDev;
    }
    return (mean: bagPackaging.idealGrams! * bagCount, variance: variance);
  }

  static String _g(double grams) {
    final r = grams.roundToDouble();
    return (grams - r).abs() < 0.05
        ? '${r.toInt()} g'
        : '${grams.toStringAsFixed(1)} g';
  }
}
