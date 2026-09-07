// Trainer / calibrator for the TARE discrepancy model.
//
// Run from the project root:
//     dart run tool/train_discrepancy_model.dart
//
// It builds a large synthetic, labelled dataset from the menu weights (each
// component sampled from its own Gaussian so the data looks like real packs +
// scale noise), induces known errors (missing item, extra item, mixed-up
// order, …), then calibrates the model parameters to best recover those
// errors. It uses the SAME inference code the app ships (WeightInferenceEngine)
// so what we measure here is exactly what runs on the tablet.
//
// Outputs (all under assets/models/):
//   • discrepancy_model.json   — the trained parameters (loaded by the app)
//   • training_metrics.json    — full evaluation metrics
//   • training_report.md       — human-readable summary
//
// Deterministic: a fixed RNG seed means re-running reproduces the same model.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:tare_pack_station/ai/discrepancy.dart';
import 'package:tare_pack_station/ai/discrepancy_engine.dart';
import 'package:tare_pack_station/ai/discrepancy_model_config.dart';
import 'package:tare_pack_station/data/menu_repository.dart';
import 'package:tare_pack_station/models/menu_item.dart';
import 'package:tare_pack_station/models/order.dart';
import 'package:tare_pack_station/models/order_item.dart';
import 'package:tare_pack_station/models/tolerance_settings.dart';

const int _seed = 20240722;
const int _valSize = 1500;
const int _testSize = 3000;
const int _searchIters = 240;
const double _trueScaleNoise = 4.0; // grams of sensor + handling noise
const ToleranceSettings _tolerance = ToleranceSettings.defaults;

void main(List<String> args) {
  stdout.writeln('TARE discrepancy model — training');
  stdout.writeln('=================================');

  final menu = MenuSeed.items();
  final menuIndex = {for (final m in menu) m.id: m};

  final rng = math.Random(_seed);
  final valSet = List.generate(_valSize, (_) => _makeSample(rng, menu, menuIndex));
  final testSet =
      List.generate(_testSize, (_) => _makeSample(rng, menu, menuIndex));
  stdout.writeln('Generated ${valSet.length} validation + '
      '${testSet.length} test samples.');

  // ---- Calibrate ---------------------------------------------------------
  final searchRng = math.Random(_seed + 1);
  DiscrepancyModelConfig best = DiscrepancyModelConfig.fallback;
  double bestObjective =
      _objective(_evaluate(WeightInferenceEngine(best), valSet, menuIndex));
  stdout.writeln('Baseline objective: ${bestObjective.toStringAsFixed(4)}');

  for (var i = 0; i < _searchIters; i++) {
    final candidate = _randomConfig(searchRng);
    final m = _evaluate(WeightInferenceEngine(candidate), valSet, menuIndex);
    final obj = _objective(m);
    if (obj > bestObjective) {
      bestObjective = obj;
      best = candidate;
      stdout.writeln('  iter $i: new best objective '
          '${obj.toStringAsFixed(4)} '
          '(top-1 ${(m.strictTop1 * 100).toStringAsFixed(1)}%)');
    }
  }

  // Stamp version + timestamp (passed in so the run stays reproducible).
  final now = DateTime.now().toUtc().toIso8601String();
  final version = args.isNotEmpty ? args.first : '1.0.0';
  best = best.copyWith(version: version, trainedAt: now);

  // ---- Final evaluation on held-out test set -----------------------------
  final metrics = _evaluate(WeightInferenceEngine(best), testSet, menuIndex);
  stdout.writeln('\nHeld-out test results:');
  stdout.writeln('  Strict top-1 accuracy : '
      '${(metrics.strictTop1 * 100).toStringAsFixed(1)}%');
  stdout.writeln('  Class accuracy        : '
      '${(metrics.classAccuracy * 100).toStringAsFixed(1)}%');
  stdout.writeln('  Top-3 hit rate        : '
      '${(metrics.top3 * 100).toStringAsFixed(1)}%');
  stdout.writeln('  Brier score (lower=better): '
      '${metrics.brier.toStringAsFixed(4)}');

  // ---- Save artifacts ----------------------------------------------------
  final dir = Directory('assets/models');
  dir.createSync(recursive: true);
  const encoder = JsonEncoder.withIndent('  ');

  File('assets/models/discrepancy_model.json')
      .writeAsStringSync(encoder.convert(best.toJson()));

  final metricsJson = metrics.toJson()
    ..addAll({
      'modelVersion': best.version,
      'trainedAt': best.trainedAt,
      'seed': _seed,
      'trueScaleNoiseGrams': _trueScaleNoise,
      'validationSize': _valSize,
      'testSize': _testSize,
      'searchIterations': _searchIters,
    });
  File('assets/models/training_metrics.json')
      .writeAsStringSync(encoder.convert(metricsJson));

  File('assets/models/training_report.md')
      .writeAsStringSync(_report(best, metrics));

  stdout.writeln('\nSaved:');
  stdout.writeln('  assets/models/discrepancy_model.json');
  stdout.writeln('  assets/models/training_metrics.json');
  stdout.writeln('  assets/models/training_report.md');
}

// ---------------------------------------------------------------------------
// Synthetic data
// ---------------------------------------------------------------------------

/// One labelled training example.
class _Sample {
  final Order selected;
  final List<Order> queue;
  final double measured;
  final PredictionKind label;
  final String? targetId;
  _Sample(this.selected, this.queue, this.measured, this.label, this.targetId);
}

int _orderCounter = 0;

Order _randomOrder(math.Random r, List<MenuItem> menu) {
  final k = 1 + r.nextInt(4); // 1..4 items
  final pool = [...menu]..shuffle(r);
  final chosen = pool.take(k).toList();
  final items = <OrderItem>[];
  for (final mi in chosen) {
    final mods = <String>[];
    for (final mod in mi.availableModifiers) {
      if (r.nextDouble() < 0.5) mods.add(mod.id);
    }
    items.add(OrderItem(menuItemId: mi.id, selectedModifierIds: mods));
  }
  _orderCounter++;
  return Order(
    id: '90${_orderCounter.toString().padLeft(5, '0')}',
    customerName: 'Test $_orderCounter',
    items: items,
    readyInMinutes: 5,
    dasherInMinutes: 5,
  );
}

double _gaussian(math.Random r, double mean, double sd) {
  if (sd <= 0) return mean;
  final u1 = r.nextDouble().clamp(1e-9, 1.0);
  final u2 = r.nextDouble();
  final z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  return mean + sd * z;
}

/// Flat sampled components of an order: (sampledGrams, lineIndex, refId, isMod).
class _SC {
  final double grams;
  final int line;
  final String refId;
  final bool isMod;
  _SC(this.grams, this.line, this.refId, this.isMod);
}

List<_SC> _sampleComponents(
  math.Random r,
  Order order,
  Map<String, MenuItem> menuIndex,
) {
  final out = <_SC>[];
  for (var i = 0; i < order.items.length; i++) {
    final line = order.items[i];
    final mi = menuIndex[line.menuItemId];
    if (mi == null) continue;
    final base = _gaussian(r, mi.baseWeightGrams, mi.baseWeightStdDev) +
        mi.packagingWeightGrams;
    out.add(_SC(base, i, mi.id, false));
    for (final modId in line.selectedModifierIds) {
      final mod = mi.modifierById(modId);
      if (mod?.weightGrams == null) continue;
      out.add(_SC(_gaussian(r, mod!.weightGrams!, mod.weightStdDev), i, mod.id,
          true));
    }
  }
  return out;
}

double _expected(Order o, Map<String, MenuItem> menuIndex) {
  double t = 0;
  for (final line in o.items) {
    final mi = menuIndex[line.menuItemId];
    if (mi == null) continue;
    t += mi.baseWeightGrams + mi.packagingWeightGrams;
    for (final modId in line.selectedModifierIds) {
      t += mi.modifierById(modId)?.weightGrams ?? 0;
    }
  }
  return t;
}

/// Combined standard deviation of an order (variances add in quadrature),
/// matching WeightEvaluator.
double _combinedSigma(Order o, Map<String, MenuItem> menuIndex) {
  double v = 0;
  for (final line in o.items) {
    final mi = menuIndex[line.menuItemId];
    if (mi == null) continue;
    v += mi.baseWeightStdDev * mi.baseWeightStdDev;
    for (final modId in line.selectedModifierIds) {
      final sd = mi.modifierById(modId)?.weightStdDev ?? 0;
      v += sd * sd;
    }
  }
  return math.sqrt(v);
}

/// The tolerance window for an order, so we can require that an induced error
/// is actually *detectable* (bigger than the window). A change inside the
/// window is, by definition, on-weight — there is nothing to detect, so we do
/// not label it as an error.
double _window(Order o, Map<String, MenuItem> menuIndex) => _tolerance
    .toleranceGrams(
        expectedGrams: _expected(o, menuIndex),
        combinedStdDev: _combinedSigma(o, menuIndex));

_Sample _makeSample(
  math.Random r,
  List<MenuItem> menu,
  Map<String, MenuItem> menuIndex,
) {
  // Build a queue: the selected order plus a few distractors.
  final selected = _randomOrder(r, menu);
  final queue = <Order>[selected];
  final qn = 3 + r.nextInt(3); // 3..5 distractors
  for (var i = 0; i < qn; i++) {
    queue.add(_randomOrder(r, menu));
  }

  final roll = r.nextInt(6);
  final noise = _gaussian(r, 0, _trueScaleNoise);

  double sum(List<_SC> cs) => cs.fold(0.0, (s, c) => s + c.grams);

  switch (roll) {
    case 0: // none / on-weight
      final cs = _sampleComponents(r, selected, menuIndex);
      return _Sample(
          selected, queue, sum(cs) + noise, PredictionKind.naturalVariation,
          null);

    case 1: // missing whole item
      final cs = _sampleComponents(r, selected, menuIndex);
      final lineIdx = r.nextInt(selected.items.length);
      final kept = cs.where((c) => c.line != lineIdx).toList();
      final refId = selected.items[lineIdx].menuItemId;
      final mi = menuIndex[refId]!;
      final removed = mi.baseWeightGrams + mi.packagingWeightGrams;
      // A whole item is essentially always above tolerance; guard anyway.
      if (removed <= _window(selected, menuIndex)) {
        return _makeSample(r, menu, menuIndex);
      }
      return _Sample(selected, queue, sum(kept) + noise,
          PredictionKind.missingItem, refId);

    case 2: // missing modifier (only label if the drop is detectable)
      final withMods = <int>[];
      for (var i = 0; i < selected.items.length; i++) {
        if (selected.items[i].selectedModifierIds.isNotEmpty) withMods.add(i);
      }
      if (withMods.isEmpty) return _makeSample(r, menu, menuIndex);
      final cs = _sampleComponents(r, selected, menuIndex);
      final lineIdx = withMods[r.nextInt(withMods.length)];
      final host = menuIndex[selected.items[lineIdx].menuItemId]!;
      final modIds = selected.items[lineIdx].selectedModifierIds;
      final dropMod = modIds[r.nextInt(modIds.length)];
      final modMean = host.modifierById(dropMod)?.weightGrams ?? 0;
      if (modMean <= _window(selected, menuIndex)) {
        // Below tolerance → genuinely undetectable; treat as on-weight instead.
        return _makeSample(r, menu, menuIndex);
      }
      final kept = cs
          .where((c) => !(c.line == lineIdx && c.isMod && c.refId == dropMod))
          .toList();
      return _Sample(selected, queue, sum(kept) + noise,
          PredictionKind.missingModifier, dropMod);

    case 3: // extra whole item
      final cs = _sampleComponents(r, selected, menuIndex);
      final extra = menu[r.nextInt(menu.length)];
      final extraMean = extra.baseWeightGrams + extra.packagingWeightGrams;
      if (extraMean <= _window(selected, menuIndex)) {
        return _makeSample(r, menu, menuIndex);
      }
      final extraGrams =
          _gaussian(r, extra.baseWeightGrams, extra.baseWeightStdDev) +
              extra.packagingWeightGrams;
      return _Sample(selected, queue, sum(cs) + extraGrams + noise,
          PredictionKind.extraItem, extra.id);

    case 4: // extra modifier (only label if the addition is detectable)
      final modsPool = <MenuItem>[for (final m in menu) if (m.availableModifiers.isNotEmpty) m];
      if (modsPool.isEmpty) return _makeSample(r, menu, menuIndex);
      final cs = _sampleComponents(r, selected, menuIndex);
      final host = modsPool[r.nextInt(modsPool.length)];
      final mod = host.availableModifiers[
          r.nextInt(host.availableModifiers.length)];
      final modWeight = mod.weightGrams ?? 0;
      if (modWeight <= _window(selected, menuIndex)) {
        return _makeSample(r, menu, menuIndex);
      }
      final extraGrams = _gaussian(r, modWeight, mod.weightStdDev);
      return _Sample(selected, queue, sum(cs) + extraGrams + noise,
          PredictionKind.extraModifier, mod.id);

    default: // wrong / mixed-up order
      final eSel = _expected(selected, menuIndex);
      final window = _tolerance.toleranceGrams(
          expectedGrams: eSel, combinedStdDev: 15);
      // Find a distractor that is distinguishable from the selected order.
      Order? bag;
      for (final cand in queue.skip(1)) {
        if ((_expected(cand, menuIndex) - eSel).abs() > window + 20) {
          bag = cand;
          break;
        }
      }
      if (bag == null) return _makeSample(r, menu, menuIndex);
      final cs = _sampleComponents(r, bag, menuIndex);
      return _Sample(
          selected, queue, sum(cs) + noise, PredictionKind.wrongOrder, bag.id);
  }
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

class _Metrics {
  final int n;
  final double strictTop1; // class + component both right
  final double classAccuracy; // class right
  final double top3; // correct explanation within top-3
  final double brier;
  final Map<String, int> support;
  final Map<String, double> recallByClass; // strict detection rate
  final Map<String, Map<String, int>> confusion; // true -> predicted -> count

  _Metrics({
    required this.n,
    required this.strictTop1,
    required this.classAccuracy,
    required this.top3,
    required this.brier,
    required this.support,
    required this.recallByClass,
    required this.confusion,
  });

  Map<String, dynamic> toJson() => {
        'samples': n,
        'strictTop1Accuracy': strictTop1,
        'classAccuracy': classAccuracy,
        'top3HitRate': top3,
        'brierScore': brier,
        'supportByClass': support,
        'recallByClass': recallByClass,
        'confusionMatrix': confusion,
      };
}

String _labelName(PredictionKind k) => k.name;

_Metrics _evaluate(
  WeightInferenceEngine engine,
  List<_Sample> samples,
  Map<String, MenuItem> menuIndex,
) {
  var strict = 0;
  var classRight = 0;
  var top3 = 0;
  var brierSum = 0.0;
  var brierN = 0;
  final support = <String, int>{};
  final recallHits = <String, int>{};
  final confusion = <String, Map<String, int>>{};

  for (final s in samples) {
    final label = _labelName(s.label);
    support[label] = (support[label] ?? 0) + 1;

    final result = engine.analyze(
      order: s.selected,
      measuredGrams: s.measured,
      menuIndex: menuIndex,
      tolerance: _tolerance,
      otherOrders: s.queue,
    );

    // Determine predicted class.
    final PredictionKind predKind;
    if (result.predictions.isEmpty) {
      predKind = PredictionKind.naturalVariation;
    } else {
      predKind = result.top!.kind;
    }
    final predLabel = _labelName(predKind);
    confusion.putIfAbsent(label, () => {});
    confusion[label]![predLabel] = (confusion[label]![predLabel] ?? 0) + 1;

    final classOk = predKind == s.label ||
        // "naturalVariation" and an empty result both mean "no fault".
        (s.label == PredictionKind.naturalVariation &&
            result.predictions.isEmpty);
    if (classOk) classRight++;

    // Strict: class right AND the identified component/order matches.
    bool strictOk;
    if (s.label == PredictionKind.naturalVariation) {
      strictOk = result.predictions.isEmpty ||
          result.top!.kind == PredictionKind.naturalVariation;
    } else {
      final top = result.top;
      strictOk = top != null &&
          top.kind == s.label &&
          (top.refId == s.targetId || top.relatedOrderId == s.targetId);
    }
    if (strictOk) strict++;
    if (strictOk) recallHits[label] = (recallHits[label] ?? 0) + 1;

    // Top-3: correct explanation anywhere in the top-3.
    bool in3;
    if (s.label == PredictionKind.naturalVariation) {
      in3 = strictOk;
    } else {
      in3 = result.predictions.take(3).any((p) =>
          p.kind == s.label &&
          (p.refId == s.targetId || p.relatedOrderId == s.targetId));
    }
    if (in3) top3++;

    // Brier on the top prediction's confidence vs. whether it was correct.
    final top = result.top;
    if (top != null && top.kind != PredictionKind.inconclusive) {
      final p = top.confidence;
      final y = strictOk ? 1.0 : 0.0;
      brierSum += (p - y) * (p - y);
      brierN++;
    }
  }

  final recallByClass = <String, double>{};
  support.forEach((k, v) {
    recallByClass[k] = v == 0 ? 0 : (recallHits[k] ?? 0) / v;
  });

  return _Metrics(
    n: samples.length,
    strictTop1: strict / samples.length,
    classAccuracy: classRight / samples.length,
    top3: top3 / samples.length,
    brier: brierN == 0 ? 0 : brierSum / brierN,
    support: support,
    recallByClass: recallByClass,
    confusion: confusion,
  );
}

/// Objective the search maximises: accuracy first, calibration as a tie-break.
double _objective(_Metrics m) => m.strictTop1 - 0.15 * m.brier;

// ---------------------------------------------------------------------------
// Parameter search
// ---------------------------------------------------------------------------

double _uni(math.Random r, double lo, double hi) => lo + r.nextDouble() * (hi - lo);

DiscrepancyModelConfig _randomConfig(math.Random r) {
  return DiscrepancyModelConfig(
    version: 'search',
    trainedAt: 'search',
    priorMissingItem: _uni(r, 0.5, 1.5),
    priorMissingModifier: _uni(r, 0.3, 1.1),
    priorExtraItem: _uni(r, 0.5, 1.5),
    priorExtraModifier: _uni(r, 0.3, 1.1),
    priorWrongOrder: _uni(r, 0.4, 1.6),
    priorNaturalVariation: _uni(r, 0.2, 1.2),
    scaleNoiseGrams: _uni(r, 2, 12),
    confidenceTemperature: _uni(r, 0.5, 2.0),
    minConfidenceToShow: _uni(r, 0.05, 0.25),
    wrongOrderMarginGrams: _uni(r, 2, 20),
    maxSuggestions: 3,
  );
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

String _report(DiscrepancyModelConfig c, _Metrics m) {
  final b = StringBuffer();
  b.writeln('# TARE discrepancy model — training report');
  b.writeln();
  b.writeln('- **Model version:** `${c.version}`');
  b.writeln('- **Trained at (UTC):** ${c.trainedAt}');
  b.writeln('- **Test samples:** ${m.n}');
  b.writeln('- **RNG seed:** $_seed (reproducible)');
  b.writeln();
  b.writeln('## Headline metrics (held-out test set)');
  b.writeln();
  b.writeln('| Metric | Value |');
  b.writeln('| --- | --- |');
  b.writeln('| Strict top-1 accuracy (class **and** component) | ${_pct(m.strictTop1)} |');
  b.writeln('| Class accuracy | ${_pct(m.classAccuracy)} |');
  b.writeln('| Top-3 hit rate | ${_pct(m.top3)} |');
  b.writeln('| Brier score (0 = perfect calibration) | ${m.brier.toStringAsFixed(4)} |');
  b.writeln();
  b.writeln('## Detection rate by error type');
  b.writeln();
  b.writeln('| Error type | Support | Correctly identified |');
  b.writeln('| --- | --- | --- |');
  final keys = m.support.keys.toList()..sort();
  for (final k in keys) {
    b.writeln('| $k | ${m.support[k]} | ${_pct(m.recallByClass[k] ?? 0)} |');
  }
  b.writeln();
  b.writeln('## Trained parameters');
  b.writeln();
  b.writeln('```json');
  b.writeln(const JsonEncoder.withIndent('  ').convert(c.toJson()));
  b.writeln('```');
  b.writeln();
  b.writeln('> Regenerate with `dart run tool/train_discrepancy_model.dart '
      '<version>`. The app loads `discrepancy_model.json`; swap that file to '
      'update the model with no code change.');
  return b.toString();
}
