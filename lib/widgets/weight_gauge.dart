import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../util/format.dart';

/// The signature SmartScale weight gauge, rendered in the TARE neubrutalist
/// theme.
///
/// The bar itself carries no numbers or markings — it's always split into
/// exactly equal thirds (under · on-target · over), so its shape is
/// identical for every order; only the moving line shows where the current
/// scale reading falls. The on-target (green) third always corresponds
/// exactly to the order's real acceptance window [loGrams, hiGrams] — a
/// measured weight inside that window always lands the marker in the green
/// third, however wide or narrow that window actually is in grams. A small
/// caption below the bar still shows the measured/target figures.
class WeightGauge extends StatelessWidget {
  /// Lower bound of the acceptance window (grams).
  final double loGrams;

  /// Upper bound of the acceptance window (grams).
  final double hiGrams;

  /// The ideal / target weight (grams) — used only to size the gauge's right
  /// extreme, never displayed.
  final double idealGrams;

  /// The measured weight currently on the scale, or null when the scale is
  /// empty (no bag). Null hides the marker entirely.
  final double? measuredGrams;

  const WeightGauge({
    super.key,
    required this.loGrams,
    required this.hiGrams,
    required this.idealGrams,
    required this.measuredGrams,
  });

  /// The right extreme of the gauge's domain — comfortably past the on-target
  /// window (based on the order's own target weight) so an over-weight bag
  /// still has real room to move before pinning to the edge.
  double get _maxGrams => math.max(idealGrams * 2, hiGrams * 1.2);

  /// Maps a measured weight to a 0..1 position along the bar. The mapping is
  /// piecewise so the on-target window always occupies exactly the middle
  /// third, regardless of how wide that window is in grams: 0..lo maps to
  /// 0..⅓, lo..hi maps to ⅓..⅔, hi..max maps to ⅔..1.
  double _fracFor(double measured) {
    const third = 1 / 3;
    if (measured <= loGrams) {
      if (loGrams <= 0) return third;
      return (measured / loGrams).clamp(0.0, 1.0) * third;
    }
    if (measured <= hiGrams) {
      final span = hiGrams - loGrams;
      if (span <= 0) return 0.5;
      return third + ((measured - loGrams) / span) * third;
    }
    final span = _maxGrams - hiGrams;
    if (span <= 0) return 1.0;
    return (2 * third) + ((measured - hiGrams) / span).clamp(0.0, 1.0) * third;
  }

  @override
  Widget build(BuildContext context) {
    final measured = measuredGrams;
    final offLeft = measured != null && measured < 0;
    final offRight = measured != null && measured > _maxGrams;
    final frac = measured == null ? null : _fracFor(measured);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            const barH = 20.0;
            final markerX = frac == null ? null : frac * w;
            return SizedBox(
              height: barH + 22,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      height: barH,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppColors.ink, width: 2),
                      ),
                      child: const ClipRRect(
                        borderRadius: BorderRadius.all(Radius.circular(999)),
                        // Row's default cross-axis behavior gives each child
                        // a LOOSE height constraint — a childless ColoredBox
                        // has no intrinsic size, so without `stretch` it
                        // collapses to zero height and paints nothing
                        // (invisible fill, only the outer border showing).
                        // `stretch` forces each third to fill the bar's full
                        // height.
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Under (left) — matches the "Under" status pill.
                            Expanded(child: ColoredBox(color: AppColors.coral)),
                            // On target — always the exact middle third.
                            Expanded(child: ColoredBox(color: AppColors.green)),
                            // Over (right) — matches the "Over" status pill.
                            Expanded(child: ColoredBox(color: AppColors.amber)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (markerX != null)
                    Positioned(
                      left: (markerX - 8).clamp(0.0, w - 16),
                      bottom: 0,
                      child: _Marker(
                        height: barH,
                        arrow: offLeft
                            ? _Arrow.left
                            : (offRight ? _Arrow.right : _Arrow.none),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            // Expanded (not a Flexible + a competing Spacer — see the fix
            // that was needed here before) so this always gets the full
            // remaining width and wraps rather than truncates.
            Expanded(
              child: Text(
                measured == null
                    ? 'Place a bag on the scale'
                    : 'Measured ${formatGrams(measured)}',
                style: AppTextStyles.mono(
                  size: 12.5,
                  weight: FontWeight.w700,
                  color: AppColors.ink.withValues(alpha: 0.85),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Target ${formatGrams(idealGrams)}',
              style: AppTextStyles.mono(
                size: 12.5,
                weight: FontWeight.w400,
                color: AppColors.ink.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

enum _Arrow { none, left, right }

/// A hard ink pointer: a diamond knob on a vertical stem, in the neubrutalist
/// style. When the reading is off the visible scale it shows a directional
/// chevron instead of the diamond.
class _Marker extends StatelessWidget {
  final double height;
  final _Arrow arrow;
  const _Marker({required this.height, required this.arrow});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (arrow == _Arrow.none)
            Transform.rotate(
              angle: math.pi / 4,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: AppColors.ink,
                  border: Border.all(color: AppColors.cream, width: 1.5),
                ),
              ),
            )
          else
            Icon(
              arrow == _Arrow.left ? Icons.chevron_left : Icons.chevron_right,
              size: 18,
              color: AppColors.ink,
            ),
          Container(width: 3, height: height, color: AppColors.ink),
        ],
      ),
    );
  }
}
