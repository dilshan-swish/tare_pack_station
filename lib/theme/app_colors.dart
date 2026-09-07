import 'package:flutter/material.dart';

/// The SWiSH palette. Clean, light "SmartScale" look — a near-white page and
/// white cards — with the SWiSH green/amber used as accents, and the order
/// receipt rendered on warm "paper" (cream) so it reads like a real receipt.
class AppColors {
  AppColors._();

  // --- Surfaces ---
  /// The page background (very light, lets white cards lift off it).
  static const Color page = Color(0xFFF5F6F4);

  /// Card / panel surface.
  static const Color white = Color(0xFFFFFFFF);

  /// The receipt "paper" — warm off-white so the left panel looks printed.
  static const Color cream = Color(0xFFFBF8F0);

  /// Hairline borders / dividers.
  static const Color line = Color(0xFFE7E9E4);

  // --- Text ---
  /// Primary text, icons (near-black, not pure black).
  static const Color ink = Color(0xFF17211B);

  /// Secondary / muted text.
  static const Color muted = Color(0xFF5F6B63);

  // --- Brand accents ---
  static const Color green = Color(0xFF2F8F5B);
  static const Color greenDark = Color(0xFF256B45);
  static const Color amber = Color(0xFFF3A93B);

  /// Section headings on white/page backgrounds (e.g. Settings titles/tabs).
  /// Distinct from [green] — a deeper shade for strong contrast on white.
  static const Color heading = Color(0xFF0E8B51);

  // --- Status ---
  /// "Under weight".
  static const Color coral = Color(0xFFE8604C);

  /// Bright warning banner (order lighter/heavier than expected).
  static const Color yellow = Color(0xFFFFD64A);

  // On-weight.
  static const Color okGreenBg = Color(0xFFE7F6EE);
  static const Color okGreenText = Color(0xFF1C5C39);

  // Under / missing.
  static const Color underBg = Color(0xFFFDE7E1);
  static const Color underText = Color(0xFFA5341F);
}
