/// The trained parameters of the discrepancy model.
///
/// This is the artifact that is *learned* by `tool/train_discrepancy_model.dart`
/// and saved to `assets/models/discrepancy_model.json`. The app loads it at
/// startup. Swapping that JSON file (or pointing the loader at a remote copy)
/// updates the model with no code change — see the guide in
/// `docs/AI_MODEL_AND_FOODICS_GUIDE.md`.
library;

/// Prior probabilities for each explanation class, plus the calibration knobs
/// the trainer tunes. Kept pure-Dart so the trainer and the app share exactly
/// the same inference code.
class DiscrepancyModelConfig {
  /// Semantic version of this trained model.
  final String version;

  /// ISO-8601 timestamp the model was trained (informational).
  final String trainedAt;

  /// Prior weight for a missing whole item (under).
  final double priorMissingItem;

  /// Prior weight for a missing modifier (under).
  final double priorMissingModifier;

  /// Prior weight for an extra whole item (over).
  final double priorExtraItem;

  /// Prior weight for an extra modifier / portion (over).
  final double priorExtraModifier;

  /// Prior weight for a mixed-up (wrong) order.
  final double priorWrongOrder;

  /// Prior weight for normal pack variation / scale still settling.
  final double priorNaturalVariation;

  /// Extra measurement-noise sigma (grams) folded into every likelihood, on
  /// top of each component's own natural standard deviation. Captures scale
  /// resolution + handling noise.
  final double scaleNoiseGrams;

  /// Softmax temperature used to turn scores into calibrated probabilities.
  /// Higher = softer (less overconfident).
  final double confidenceTemperature;

  /// A prediction below this probability is not shown; if nothing clears it the
  /// model reports "inconclusive" and asks for a manual check.
  final double minConfidenceToShow;

  /// How many grams better another order must fit before a wrong-order mix-up
  /// is flagged.
  final double wrongOrderMarginGrams;

  /// Maximum number of ranked suggestions to surface.
  final int maxSuggestions;

  const DiscrepancyModelConfig({
    required this.version,
    required this.trainedAt,
    required this.priorMissingItem,
    required this.priorMissingModifier,
    required this.priorExtraItem,
    required this.priorExtraModifier,
    required this.priorWrongOrder,
    required this.priorNaturalVariation,
    required this.scaleNoiseGrams,
    required this.confidenceTemperature,
    required this.minConfidenceToShow,
    required this.wrongOrderMarginGrams,
    required this.maxSuggestions,
  });

  /// Safe built-in defaults. These are sensible, hand-set values used if the
  /// trained asset is missing or corrupt, so the feature degrades gracefully
  /// instead of failing.
  static const DiscrepancyModelConfig fallback = DiscrepancyModelConfig(
    version: 'builtin-1.0.0',
    trainedAt: 'n/a',
    priorMissingItem: 1.0,
    priorMissingModifier: 0.6,
    priorExtraItem: 1.0,
    priorExtraModifier: 0.6,
    priorWrongOrder: 0.9,
    priorNaturalVariation: 0.4,
    scaleNoiseGrams: 6.0,
    confidenceTemperature: 1.0,
    minConfidenceToShow: 0.12,
    wrongOrderMarginGrams: 8.0,
    maxSuggestions: 3,
  );

  DiscrepancyModelConfig copyWith({
    String? version,
    String? trainedAt,
    double? priorMissingItem,
    double? priorMissingModifier,
    double? priorExtraItem,
    double? priorExtraModifier,
    double? priorWrongOrder,
    double? priorNaturalVariation,
    double? scaleNoiseGrams,
    double? confidenceTemperature,
    double? minConfidenceToShow,
    double? wrongOrderMarginGrams,
    int? maxSuggestions,
  }) {
    return DiscrepancyModelConfig(
      version: version ?? this.version,
      trainedAt: trainedAt ?? this.trainedAt,
      priorMissingItem: priorMissingItem ?? this.priorMissingItem,
      priorMissingModifier: priorMissingModifier ?? this.priorMissingModifier,
      priorExtraItem: priorExtraItem ?? this.priorExtraItem,
      priorExtraModifier: priorExtraModifier ?? this.priorExtraModifier,
      priorWrongOrder: priorWrongOrder ?? this.priorWrongOrder,
      priorNaturalVariation:
          priorNaturalVariation ?? this.priorNaturalVariation,
      scaleNoiseGrams: scaleNoiseGrams ?? this.scaleNoiseGrams,
      confidenceTemperature:
          confidenceTemperature ?? this.confidenceTemperature,
      minConfidenceToShow: minConfidenceToShow ?? this.minConfidenceToShow,
      wrongOrderMarginGrams:
          wrongOrderMarginGrams ?? this.wrongOrderMarginGrams,
      maxSuggestions: maxSuggestions ?? this.maxSuggestions,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'trainedAt': trainedAt,
        'priorMissingItem': priorMissingItem,
        'priorMissingModifier': priorMissingModifier,
        'priorExtraItem': priorExtraItem,
        'priorExtraModifier': priorExtraModifier,
        'priorWrongOrder': priorWrongOrder,
        'priorNaturalVariation': priorNaturalVariation,
        'scaleNoiseGrams': scaleNoiseGrams,
        'confidenceTemperature': confidenceTemperature,
        'minConfidenceToShow': minConfidenceToShow,
        'wrongOrderMarginGrams': wrongOrderMarginGrams,
        'maxSuggestions': maxSuggestions,
      };

  /// Parses a trained model. Any missing field falls back to the built-in
  /// default for that field, so a partial or older file still loads.
  factory DiscrepancyModelConfig.fromJson(Map<String, dynamic> json) {
    double d(String k, double fb) => (json[k] as num?)?.toDouble() ?? fb;
    const fb = fallback;
    return DiscrepancyModelConfig(
      version: json['version'] as String? ?? fb.version,
      trainedAt: json['trainedAt'] as String? ?? fb.trainedAt,
      priorMissingItem: d('priorMissingItem', fb.priorMissingItem),
      priorMissingModifier: d('priorMissingModifier', fb.priorMissingModifier),
      priorExtraItem: d('priorExtraItem', fb.priorExtraItem),
      priorExtraModifier: d('priorExtraModifier', fb.priorExtraModifier),
      priorWrongOrder: d('priorWrongOrder', fb.priorWrongOrder),
      priorNaturalVariation:
          d('priorNaturalVariation', fb.priorNaturalVariation),
      scaleNoiseGrams: d('scaleNoiseGrams', fb.scaleNoiseGrams),
      confidenceTemperature:
          d('confidenceTemperature', fb.confidenceTemperature),
      minConfidenceToShow: d('minConfidenceToShow', fb.minConfidenceToShow),
      wrongOrderMarginGrams:
          d('wrongOrderMarginGrams', fb.wrongOrderMarginGrams),
      maxSuggestions:
          (json['maxSuggestions'] as num?)?.toInt() ?? fb.maxSuggestions,
    );
  }
}
