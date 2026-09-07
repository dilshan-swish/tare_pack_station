import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/scale_controller.dart';
import '../state/weight_providers.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import '../weight/manual_weight_source.dart';
import 'neo_card.dart';
import 'pill_button.dart';
import 'scale_input.dart';

/// The floating live-weight readout, echoing the SmartScale on-screen weight
/// pill (bottom-centre), rendered in the TARE theme: a solid ink pill with an
/// amber scale glyph and a Space Mono readout of whatever is currently on the
/// scale — the single station-wide measured weight.
///
/// Tapping it opens the scale sheet. In manual test mode that sheet is where
/// staff type / step / simulate the weight (the physical scale needs no input);
/// in serial mode it shows the live connection state.
class ScalePill extends ConsumerWidget {
  const ScalePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reading = ref.watch(scaleReadingProvider);
    final grams = ref.watch(scaleGramsProvider);
    final source = ref.watch(weightSourceProvider);
    final isManual = source is ManualWeightSource;
    final settling = reading != null && !reading.stable;

    final label = grams == null ? '0 g' : formatGrams(grams);

    return Semantics(
      button: true,
      label: 'Scale — $label',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => showScaleSheet(context),
          borderRadius: BorderRadius.circular(AppShapes.pillRadius),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.fromLTRB(16, 10, 20, 10),
            decoration: BoxDecoration(
              color: AppColors.ink,
              borderRadius: BorderRadius.circular(AppShapes.pillRadius),
              border: Border.all(color: AppColors.ink, width: 2),
              boxShadow: AppShapes.softShadow(),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.scale, size: 20, color: AppColors.amber),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: AppTextStyles.mono(
                    size: 20,
                    weight: FontWeight.w700,
                    color: AppColors.cream,
                  ),
                ),
                if (settling) ...[
                  const SizedBox(width: 10),
                  Text(
                    'settling…',
                    style: AppTextStyles.body(
                      size: 12,
                      weight: FontWeight.w600,
                      color: AppColors.amber,
                    ),
                  ),
                ],
                if (isManual) ...[
                  const SizedBox(width: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.amber,
                      borderRadius: BorderRadius.circular(AppShapes.pillRadius),
                    ),
                    child: Text(
                      'TEST',
                      style: AppTextStyles.body(
                        size: 10.5,
                        weight: FontWeight.w700,
                        color: AppColors.ink,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the scale sheet: the full [ScaleInput] panel so staff can read (and,
/// in manual test mode, set) the weight currently on the scale.
void showScaleSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      return Padding(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
          top: 12,
        ),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: NeoCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text('Scale', style: AppTextStyles.display(size: 20)),
                      const Spacer(),
                      NeoIconButton(
                        icon: Icons.close,
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const ScaleInput(),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
