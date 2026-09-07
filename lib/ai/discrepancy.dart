/// Data types produced by the on-device discrepancy model.
///
/// The model looks at how far a measured weight is from an order's expected
/// weight and infers the most likely *reason* — a missing item, an extra item,
/// or that the bag on the scale might belong to a different order. It is a
/// careful, calibrated statistical model: every prediction carries a
/// probability so the UI can stay honest about how sure it is.
library;

/// The kind of explanation a [Prediction] represents.
enum PredictionKind {
  /// A whole menu item looks absent from the bag (order is under).
  missingItem,

  /// A single modifier / add-on looks absent (order is under).
  missingModifier,

  /// An extra whole menu item looks present in the bag (order is over).
  extraItem,

  /// An extra modifier / portion looks present (order is over).
  extraModifier,

  /// The measured weight matches a *different* queued order much better —
  /// the bags may have been mixed up.
  wrongOrder,

  /// The gap is small enough to be normal pack-to-pack variation or the scale
  /// still settling — recommend a re-weigh rather than a component change.
  naturalVariation,

  /// Nothing explained the gap confidently — recommend a manual check.
  inconclusive,
}

extension PredictionKindX on PredictionKind {
  bool get isMissing =>
      this == PredictionKind.missingItem ||
      this == PredictionKind.missingModifier;

  bool get isExtra =>
      this == PredictionKind.extraItem || this == PredictionKind.extraModifier;
}

/// A single ranked explanation for a weight discrepancy.
class Prediction {
  final PredictionKind kind;

  /// Human-readable headline, e.g. "Missing: Zinger burger".
  final String title;

  /// Optional supporting detail, e.g. "≈ 265 g would close the gap".
  final String detail;

  /// Calibrated probability in [0, 1] that this explanation is the right one.
  final double confidence;

  /// Grams this explanation accounts for (signed: negative = removes weight).
  final double weightAccountedGrams;

  /// The menu-item / modifier id this explanation refers to (null for order-
  /// level kinds). Used by the trainer to score which component was identified;
  /// the UI does not need it.
  final String? refId;

  /// For [PredictionKind.wrongOrder]: the id of the better-matching order.
  final String? relatedOrderId;

  /// For [PredictionKind.wrongOrder]: that order's staff-readable label (e.g.
  /// "Order 42 · Talabat #5070") — never the raw internal id.
  final String? relatedOrderLabel;

  /// A predefined reason tag that best matches this prediction, so the UI can
  /// pre-select the matching chip. Null when there is no natural mapping.
  final String? suggestedReasonTag;

  const Prediction({
    required this.kind,
    required this.title,
    required this.detail,
    required this.confidence,
    required this.weightAccountedGrams,
    this.refId,
    this.relatedOrderId,
    this.relatedOrderLabel,
    this.suggestedReasonTag,
  });
}

/// The full result of analysing one order against the measured weight.
class DiscrepancyResult {
  /// measured − expected (negative = under, positive = over).
  final double deltaGrams;

  /// Ranked explanations, most likely first (may be empty).
  final List<Prediction> predictions;

  /// True when a different order matched the weight far better — surfaced
  /// prominently as a mix-up warning.
  final bool wrongOrderSuspected;

  /// Model version that produced this result (for display / audit).
  final String modelVersion;

  const DiscrepancyResult({
    required this.deltaGrams,
    required this.predictions,
    required this.wrongOrderSuspected,
    required this.modelVersion,
  });

  bool get hasPredictions => predictions.isNotEmpty;

  Prediction? get top => predictions.isEmpty ? null : predictions.first;

  /// An empty result (used when the order is on-weight — nothing to explain).
  static const DiscrepancyResult none = DiscrepancyResult(
    deltaGrams: 0,
    predictions: [],
    wrongOrderSuspected: false,
    modelVersion: '—',
  );
}
