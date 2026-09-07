import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// Design tokens shared across the clean SmartScale components.
class AppShapes {
  AppShapes._();

  /// Border radius for cards.
  static const double cardRadius = 20;

  /// Hairline border width for the light theme.
  static const double borderWidth = 1.0;

  /// Fully-rounded pill radius.
  static const double pillRadius = 999;

  /// A soft, diffuse card shadow (clean/light look).
  static List<BoxShadow> softShadow() => [
        BoxShadow(
          offset: const Offset(0, 1),
          blurRadius: 2,
          color: AppColors.ink.withValues(alpha: 0.05),
        ),
        BoxShadow(
          offset: const Offset(0, 10),
          blurRadius: 26,
          color: AppColors.ink.withValues(alpha: 0.07),
        ),
      ];
}

/// Builds the app [ThemeData]. We keep Material out of the way and rely on the
/// custom widgets for the brand look, but a coherent base theme keeps default
/// widgets (dialogs, text fields) on-brand.
ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.page,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.green,
      primary: AppColors.green,
      secondary: AppColors.ink,
      surface: AppColors.white,
    ),
    textTheme: GoogleFonts.interTextTheme(),
  );

  return base.copyWith(
    splashFactory: InkRipple.splashFactory,
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: AppColors.ink,
      contentTextStyle: GoogleFonts.inter(
        color: AppColors.cream,
        fontWeight: FontWeight.w600,
      ),
      behavior: SnackBarBehavior.floating,
    ),
    // A subtle, always-visible scrollbar with a soft green (brand) thumb — reads
    // cleanly on the light background without shouting.
    scrollbarTheme: ScrollbarThemeData(
      thumbVisibility: const WidgetStatePropertyAll(true),
      thickness: const WidgetStatePropertyAll(7),
      radius: const Radius.circular(999),
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.dragged) ||
            states.contains(WidgetState.hovered)) {
          return AppColors.green.withValues(alpha: 0.6);
        }
        return AppColors.green.withValues(alpha: 0.35);
      }),
      trackColor: WidgetStatePropertyAll(AppColors.ink.withValues(alpha: 0.05)),
      trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
      crossAxisMargin: 3,
      mainAxisMargin: 4,
    ),
  );
}
