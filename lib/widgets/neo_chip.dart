import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

/// A rounded chip used for modifiers and (when [onTap] is set) as a selectable
/// reason button. Selected chips fill with SWiSH green; [accent] tints the
/// outline/text for callouts (e.g. an unconfigured-item chip).
class NeoChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Color accent;
  final double fontSize;

  const NeoChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.accent = AppColors.ink,
    this.fontSize = 13,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg = selected ? AppColors.green : AppColors.white;
    final Color fg = selected ? AppColors.white : accent;
    final Color border = selected ? AppColors.green : AppColors.line;

    final chip = Container(
      // maxWidth guards against an unusually long label (e.g. a raw item
      // name reported for one not yet in the synced menu) forcing the chip
      // — and the card around it — wider than the screen; it wraps onto a
      // second line instead of overflowing. Ordinary short labels never
      // approach this width, so they're unaffected.
      constraints: BoxConstraints(
          minHeight: onTap != null ? 44 : 28, maxWidth: 280),
      padding: EdgeInsets.symmetric(
        horizontal: 14,
        vertical: onTap != null ? 10 : 5,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        border: Border.all(color: border, width: 1.5),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: AppTextStyles.body(
              size: fontSize, weight: FontWeight.w600, color: fg),
        ),
      ),
    );

    if (onTap == null) return chip;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppShapes.pillRadius),
          child: chip,
        ),
      ),
    );
  }
}
