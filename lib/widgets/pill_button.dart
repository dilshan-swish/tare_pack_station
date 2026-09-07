import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';

enum PillButtonVariant {
  /// Solid green fill, white text — primary action.
  primary,

  /// White with a hairline border — secondary action.
  outline,

  /// Kept for compatibility; same as [primary].
  onGreen,
}

/// A fully-rounded button. Enforces a 44px+ tap target for wet/gloved hands.
class PillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final PillButtonVariant variant;
  final IconData? icon;
  final EdgeInsetsGeometry padding;

  const PillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = PillButtonVariant.primary,
    this.icon,
    this.padding = const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;

    late final Color bg;
    late final Color fg;
    late final Color border;
    late final double borderWidth;
    switch (variant) {
      case PillButtonVariant.primary:
      case PillButtonVariant.onGreen:
        bg = enabled ? AppColors.green : AppColors.green.withValues(alpha: 0.4);
        fg = AppColors.white;
        border = bg;
        borderWidth = 1.5;
      case PillButtonVariant.outline:
        bg = AppColors.white;
        fg = enabled ? AppColors.ink : AppColors.ink.withValues(alpha: 0.35);
        border = AppColors.line;
        borderWidth = 1.5;
    }

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppShapes.pillRadius),
          child: Container(
            constraints: const BoxConstraints(minHeight: 46, minWidth: 44),
            padding: padding,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(AppShapes.pillRadius),
              border: Border.all(color: border, width: borderWidth),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body(
                        size: 15, weight: FontWeight.w700, color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A circular outlined icon button.
class NeoIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final Color background;
  final Color foreground;

  const NeoIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.background = AppColors.white,
    this.foreground = AppColors.ink,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.line, width: 1.5),
            ),
            child: Icon(icon, size: 20, color: foreground),
          ),
        ),
      ),
    );
  }
}
