/// Tolerance configuration used to decide whether a measured weight counts as
/// on / under / over the expected weight.
///
/// The allowed deviation for an order is the largest of three floors, so that
/// no single rule can make the window unreasonably tight:
///
///   tolerance = max(
///     stdDevMultiplier * combinedStdDev,
///     percentFloor% * expected,
///     absoluteGramFloor,
///   )
class ToleranceSettings {
  /// Multiplier applied to the combined standard deviation (default 2).
  final double stdDevMultiplier;

  /// Percentage-of-expected floor, expressed as a percent (default 5 = 5%).
  final double percentFloor;

  /// Absolute gram floor, matching a real scale's readability (default 5g).
  final double absoluteGramFloor;

  const ToleranceSettings({
    this.stdDevMultiplier = 2,
    this.percentFloor = 5,
    this.absoluteGramFloor = 5,
  });

  static const ToleranceSettings defaults = ToleranceSettings();

  /// Computes the tolerance window (in grams) for a given expected weight and
  /// combined standard deviation.
  double toleranceGrams({
    required double expectedGrams,
    required double combinedStdDev,
  }) {
    final fromStdDev = stdDevMultiplier * combinedStdDev;
    final fromPercent = (percentFloor / 100) * expectedGrams;
    return [fromStdDev, fromPercent, absoluteGramFloor]
        .reduce((a, b) => a > b ? a : b);
  }

  ToleranceSettings copyWith({
    double? stdDevMultiplier,
    double? percentFloor,
    double? absoluteGramFloor,
  }) {
    return ToleranceSettings(
      stdDevMultiplier: stdDevMultiplier ?? this.stdDevMultiplier,
      percentFloor: percentFloor ?? this.percentFloor,
      absoluteGramFloor: absoluteGramFloor ?? this.absoluteGramFloor,
    );
  }

  Map<String, dynamic> toJson() => {
        'stdDevMultiplier': stdDevMultiplier,
        'percentFloor': percentFloor,
        'absoluteGramFloor': absoluteGramFloor,
      };

  factory ToleranceSettings.fromJson(Map<String, dynamic> json) =>
      ToleranceSettings(
        stdDevMultiplier:
            (json['stdDevMultiplier'] as num?)?.toDouble() ?? 2,
        percentFloor: (json['percentFloor'] as num?)?.toDouble() ?? 5,
        absoluteGramFloor:
            (json['absoluteGramFloor'] as num?)?.toDouble() ?? 5,
      );
}
