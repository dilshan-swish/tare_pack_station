import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

/// The SWiSH brand wordmark. Renders the approved logo image; if the asset
/// ever fails to load it falls back to the typographic wordmark so the header
/// never breaks or shows a broken-image glyph.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.height = 52});

  /// Rendered height of the logo. The image keeps its own aspect ratio.
  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/swish-logo.png',
      height: height,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      errorBuilder: (context, error, stackTrace) => _WordmarkFallback(
        fontSize: height * 0.42,
      ),
    );
  }
}

/// Typographic fallback matching the previous ink logo pill.
class _WordmarkFallback extends StatelessWidget {
  const _WordmarkFallback({required this.fontSize});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(18),
      ),
      child: RichText(
        text: TextSpan(
          style: AppTextStyles.display(size: fontSize, color: AppColors.cream),
          children: const [
            TextSpan(text: 'SWiSH'),
            TextSpan(text: '.', style: TextStyle(color: AppColors.amber)),
          ],
        ),
      ),
    );
  }
}

/// The "● Pack station 04 — weight check" status badge on the right.
class StationBadge extends StatelessWidget {
  const StationBadge({super.key, this.station = '04'});

  final String station;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: const BoxDecoration(
              color: AppColors.amber,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Pack station $station — weight check',
            style: AppTextStyles.body(
              size: 14,
              weight: FontWeight.w700,
              color: AppColors.cream,
            ),
          ),
        ],
      ),
    );
  }
}

/// Top header row: logo (+ optional leading action) on the left, trailing
/// widgets (station badge, settings) on the right. Wraps on narrow screens.
class BrandHeader extends StatelessWidget {
  final Widget? leading;
  final List<Widget> trailing;

  const BrandHeader({super.key, this.leading, this.trailing = const []});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 12,
      spacing: 12,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            const BrandLogo(),
            ?leading,
          ],
        ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: trailing,
        ),
      ],
    );
  }
}
