import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// Typography for TARE.
///
/// - [display]  Archivo Black — blocky headings, used sparingly.
/// - [body]     Inter — general UI text.
/// - [mono]     Space Mono — every gram value / code-like figure.
class AppTextStyles {
  AppTextStyles._();

  /// Archivo Black display / heading style.
  static TextStyle display({
    double size = 32,
    Color color = AppColors.ink,
    double? height,
  }) {
    return GoogleFonts.archivoBlack(
      fontSize: size,
      color: color,
      height: height,
      letterSpacing: -0.5,
    );
  }

  /// Inter body / UI style.
  static TextStyle body({
    double size = 15,
    FontWeight weight = FontWeight.w500,
    Color color = AppColors.ink,
    double? height,
    double? letterSpacing,
  }) {
    return GoogleFonts.inter(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  /// Space Mono style for weight readouts and code-like figures.
  static TextStyle mono({
    double size = 15,
    FontWeight weight = FontWeight.w400,
    Color color = AppColors.ink,
    double? height,
    double? letterSpacing,
  }) {
    return GoogleFonts.spaceMono(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }
}
