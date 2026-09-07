import 'package:flutter/material.dart';

import '../models/order_status.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';

/// A rounded status badge in the brand style. Colours and prefix glyph follow
/// the order's weight-check status.
class StatusPill extends StatelessWidget {
  final OrderStatus status;

  /// Signed delta (measured - expected). Used to label under/over pills.
  final double? deltaGrams;
  final double fontSize;

  const StatusPill({
    super.key,
    required this.status,
    this.deltaGrams,
    this.fontSize = 13.5,
  });

  @override
  Widget build(BuildContext context) {
    final spec = _spec();

    return Container(
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: spec.bg,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        border: Border.all(color: spec.border, width: 2),
      ),
      child: Text(
        spec.label,
        style: AppTextStyles.body(
          size: fontSize,
          weight: FontWeight.w700,
          color: spec.fg,
        ),
      ),
    );
  }

  _PillSpec _spec() {
    final absDelta = deltaGrams == null ? null : formatGrams(deltaGrams!.abs());
    switch (status) {
      case OrderStatus.onWeight:
        return const _PillSpec(
          bg: AppColors.okGreenBg,
          fg: AppColors.okGreenText,
          border: AppColors.okGreenText,
          label: '✓ On weight',
        );
      case OrderStatus.under:
        return _PillSpec(
          bg: AppColors.underBg,
          fg: AppColors.underText,
          border: AppColors.underText,
          label: '↓ ${absDelta ?? ''} under'.trim(),
        );
      case OrderStatus.over:
        return _PillSpec(
          bg: AppColors.amber,
          fg: AppColors.ink,
          border: AppColors.ink,
          label: '↑ ${absDelta ?? ''} over'.trim(),
        );
      case OrderStatus.dispatched:
        return const _PillSpec(
          bg: AppColors.ink,
          fg: AppColors.cream,
          border: AppColors.ink,
          label: '✓ Dispatched',
        );
      case OrderStatus.pending:
        return const _PillSpec(
          bg: AppColors.cream,
          fg: AppColors.ink,
          border: AppColors.ink,
          label: '• Awaiting weight',
        );
    }
  }
}

class _PillSpec {
  final Color bg;
  final Color fg;
  final Color border;
  final String label;

  const _PillSpec({
    required this.bg,
    required this.fg,
    required this.border,
    required this.label,
  });
}
