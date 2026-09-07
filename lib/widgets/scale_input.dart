import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/weight_reading.dart';
import '../state/scale_controller.dart';
import '../state/weight_providers.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import '../weight/manual_weight_source.dart';
import '../weight/weight_source.dart';

/// Maximum plausible weight for manual entry (50 kg), per the exception spec.
const double kMaxGrams = 50000;

/// The shared scale panel: a white readout showing the single measured weight
/// that is currently on the scale, plus (in manual test mode) the controls to
/// simulate it. Used on both the queue and the order detail screen; every
/// instance reads and writes the same global [scaleReadingProvider], so the
/// value stays consistent across screens and updates every order in realtime.
class ScaleInput extends ConsumerStatefulWidget {
  final String label;
  final Color valueColor;

  /// Compact horizontal layout — the readout and controls sit on one low row
  /// instead of a tall column. Used on the queue so it stays out of the way on
  /// short landscape tablet heights while orders remain visible below.
  final bool compact;

  const ScaleInput({
    super.key,
    this.label = 'MEASURED',
    this.valueColor = AppColors.ink,
    this.compact = false,
  });

  @override
  ConsumerState<ScaleInput> createState() => _ScaleInputState();
}

class _ScaleInputState extends ConsumerState<ScaleInput> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  WeightSource? _boundSource;

  @override
  void initState() {
    super.initState();
    final source = ref.read(weightSourceProvider);
    _boundSource = source;
    if (source is ManualWeightSource) {
      _controller.text = _fmt(source.grams);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  void _onChanged(String raw) {
    final source = _boundSource;
    if (source is! ManualWeightSource) return;
    final parsed = double.tryParse(raw.trim());
    setState(() {
      if (raw.trim().isEmpty) {
        _error = 'Enter a weight';
      } else if (parsed == null) {
        _error = 'Numbers only';
      } else if (parsed < 0) {
        _error = 'Weight cannot be negative';
      } else if (parsed > kMaxGrams) {
        _error = 'That is over 50 kg — check the scale';
      } else {
        _error = null;
      }
    });
    if (_error == null && parsed != null) {
      source.setGrams(parsed, stable: _currentStable());
    }
  }

  void _step(double delta) {
    final source = _boundSource;
    if (source is! ManualWeightSource) return;
    final current = double.tryParse(_controller.text.trim()) ?? source.grams;
    final next = (current + delta).clamp(0.0, kMaxGrams).toDouble();
    setState(() => _error = null);
    source.setGrams(next, stable: _currentStable());
  }

  bool _currentStable() {
    final source = _boundSource;
    if (source is ManualWeightSource) return source.stable;
    return ref.read(scaleReadingProvider)?.stable ?? true;
  }

  @override
  Widget build(BuildContext context) {
    // Re-seed if the active source changes (e.g. Manual -> Serial in Settings).
    ref.listen(weightSourceProvider, (prev, next) {
      _boundSource = next;
      if (next is ManualWeightSource && !_focus.hasFocus) {
        _controller.text = _fmt(next.grams);
      }
      setState(() => _error = null);
    });

    // Keep the field in sync when the value changes elsewhere (stepper, or the
    // other screen), but never fight the user while they are typing.
    ref.listen(scaleReadingProvider, (prev, next) {
      if (next != null && !_focus.hasFocus) {
        final t = _fmt(next.grams);
        if (_controller.text != t) _controller.text = t;
      }
    });

    final source = ref.watch(weightSourceProvider);
    final reading = ref.watch(scaleReadingProvider);
    final isManual = source is ManualWeightSource;

    if (widget.compact) return _compactPanel(reading, isManual);

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label, style: _labelStyle()),
          const SizedBox(height: 8),
          isManual ? _manualValue() : _serialValue(reading),
          if (isManual)
            _manualControls(reading)
          else
            _serialNote(reading),
        ],
      ),
    );
  }

  BoxDecoration _panelDecoration() => BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.ink, width: AppShapes.borderWidth),
      );

  TextStyle _labelStyle() => AppTextStyles.mono(
        size: 12,
        weight: FontWeight.w700,
        color: AppColors.ink.withValues(alpha: 0.6),
        letterSpacing: 1,
      );

  /// Single low row (readout · steppers · badge) that sits neatly in the header
  /// top-right. Pieces are separate Wrap items so they reflow to a second run
  /// only when the chip is squeezed (phone width) — never overflowing.
  Widget _compactPanel(WeightReading? reading, bool isManual) {
    final readout = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: _labelStyle()),
        const SizedBox(height: 2),
        SizedBox(
          width: 128,
          child: isManual
              ? _manualValue(fontSize: 34)
              : _serialValue(reading, fontSize: 34),
        ),
      ],
    );

    final children = <Widget>[readout];
    if (isManual) {
      children.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StepButton(icon: Icons.remove, onTap: () => _step(-5)),
            const SizedBox(width: 8),
            _StepButton(icon: Icons.add, onTap: () => _step(5)),
          ],
        ),
      );
      children.add(const _TestModeBadge(dense: true));
    } else {
      children.add(_serialNote(reading));
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          ),
          if (isManual && _error != null) ...[
            const SizedBox(height: 6),
            Text(
              _error!,
              style: AppTextStyles.body(
                size: 12.5,
                weight: FontWeight.w600,
                color: AppColors.underText,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _manualValue({double fontSize = 46}) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      onChanged: _onChanged,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      textInputAction: TextInputAction.done,
      cursorColor: AppColors.ink,
      style: AppTextStyles.mono(
        size: fontSize,
        weight: FontWeight.w700,
        color: widget.valueColor,
      ),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
        suffixText: 'g',
        suffixStyle: AppTextStyles.mono(
          size: fontSize * 0.56,
          weight: FontWeight.w700,
          color: AppColors.ink.withValues(alpha: 0.55),
        ),
      ),
    );
  }

  Widget _serialValue(WeightReading? reading, {double fontSize = 46}) {
    return Text(
      reading == null ? '— —' : '${_fmt(reading.grams)}g',
      style: AppTextStyles.mono(
        size: fontSize,
        weight: FontWeight.w700,
        color: widget.valueColor,
      ),
    );
  }

  Widget _manualControls(WeightReading? reading) {
    final stable = reading?.stable ?? true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        const _TestModeBadge(),
        const SizedBox(height: 10),
        Row(
          children: [
            _StepButton(icon: Icons.remove, onTap: () => _step(-5)),
            const SizedBox(width: 8),
            _StepButton(icon: Icons.add, onTap: () => _step(5)),
            const Spacer(),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            SizedBox(
              height: 30,
              width: 42,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Switch(
                  value: stable,
                  activeThumbColor: AppColors.cream,
                  activeTrackColor: AppColors.green,
                  onChanged: (v) {
                    final source = _boundSource;
                    if (source is ManualWeightSource) source.setStable(v);
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                stable ? 'Simulating a stable reading' : 'Simulating movement',
                style: AppTextStyles.body(
                  size: 13,
                  color: AppColors.ink.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: AppTextStyles.body(
              size: 13,
              weight: FontWeight.w600,
              color: AppColors.underText,
            ),
          ),
        ],
      ],
    );
  }

  Widget _serialNote(WeightReading? reading) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        reading == null
            ? 'No reading — connect a scale'
            : (reading.stable ? 'Stable reading' : 'Still settling…'),
        style: AppTextStyles.body(
          size: 13,
          weight: FontWeight.w600,
          color: reading?.stable == true
              ? AppColors.okGreenText
              : AppColors.ink.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.cream,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.ink, width: 2),
          ),
          child: Icon(icon, size: 20, color: AppColors.ink),
        ),
      ),
    );
  }
}

class _TestModeBadge extends StatelessWidget {
  /// Dense uses the shorter "TEST MODE" label for the compact header chip; the
  /// full "TEST MODE — manual entry" is kept for the roomier detail panel.
  final bool dense;
  const _TestModeBadge({this.dense = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.amber,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        border: Border.all(color: AppColors.ink, width: 2),
      ),
      child: Text(
        dense ? 'TEST MODE' : 'TEST MODE — manual entry',
        style: AppTextStyles.body(
          size: 11.5,
          weight: FontWeight.w700,
          color: AppColors.ink,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
