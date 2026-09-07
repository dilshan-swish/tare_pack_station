import 'package:flutter/material.dart';

/// Wraps a scrollable with an always-visible, theme-styled scrollbar (amber,
/// via [ScrollbarThemeData] in the app theme). The [controller] must be the
/// same one passed to the child scroll view.
///
/// On touch platforms Material scrollbars are hidden by default; this makes the
/// scrollbar visible everywhere so staff can always see their scroll position.
class ThemedScrollbar extends StatelessWidget {
  final ScrollController controller;
  final Widget child;
  const ThemedScrollbar({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      child: child,
    );
  }
}
