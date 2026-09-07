import 'package:flutter/material.dart';

import '../models/kitchen_stage.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

/// A small pill showing whether the kitchen is still preparing an order or it's
/// packed and ready to weigh (Foodics `status`) — shown on both the queue card
/// and the order detail header so staff always know at a glance which orders
/// are actually actionable right now.
class KitchenStagePill extends StatelessWidget {
  final KitchenStage stage;
  const KitchenStagePill({super.key, required this.stage});

  @override
  Widget build(BuildContext context) {
    final (String label, Color bg, Color fg) = switch (stage) {
      KitchenStage.preparing => (
          'Preparing',
          AppColors.amber.withValues(alpha: 0.22),
          AppColors.ink,
        ),
      KitchenStage.ready => ('Ready to weigh', AppColors.okGreenBg, AppColors.okGreenText),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
      ),
      child: Text(
        label,
        style: AppTextStyles.body(
          size: 10.5,
          weight: FontWeight.w700,
          color: fg,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
