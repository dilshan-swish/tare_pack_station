import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// The clean surface used across the app: a white (or given colour) panel with
/// a hairline border, rounded corners and a soft, diffuse shadow.
class NeoCard extends StatelessWidget {
  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color borderColor;
  final VoidCallback? onTap;

  const NeoCard({
    super.key,
    required this.child,
    this.color = AppColors.white,
    this.padding = const EdgeInsets.all(20),
    this.radius = AppShapes.cardRadius,
    this.borderColor = AppColors.line,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: borderRadius,
        border: Border.all(color: borderColor, width: AppShapes.borderWidth),
        boxShadow: AppShapes.softShadow(),
      ),
      child: Padding(padding: padding, child: child),
    );

    if (onTap == null) return decorated;

    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        splashColor: AppColors.ink.withValues(alpha: 0.05),
        highlightColor: AppColors.ink.withValues(alpha: 0.03),
        child: decorated,
      ),
    );
  }
}
