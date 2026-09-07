import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// A weight prediction from the ML model, in the same shape the app already
/// uses for the statistical formula (mean grams + a standard deviation).
class ModelPrediction {
  final double grams;
  final double stdDevGrams;
  const ModelPrediction({required this.grams, required this.stdDevGrams});
}

/// Runs the optional ML weight-prediction model (see
/// docs/AI_MODEL_CONTRACT.md for the exact input/output shape a model must
/// implement). Every method is defensive: a missing, corrupted, or
/// wrong-shaped model — or an inference call that throws for any reason —
/// simply leaves this predictor unavailable, never crashes the weigh-check
/// flow. There is always a working statistical fallback; this is a pure
/// enhancement when present, never a hard dependency.
class WeightPredictor {
  Interpreter? _interpreter;

  bool get isAvailable => _interpreter != null;

  /// Loads (or replaces) the model from raw `.tflite` bytes. Returns true iff
  /// the file loaded AND its input/output tensor shapes match the documented
  /// contract — a mismatched model is rejected outright rather than run with
  /// silently wrong results.
  bool loadFromBytes(Uint8List bytes) {
    Interpreter? interpreter;
    try {
      interpreter = Interpreter.fromBuffer(bytes);
      interpreter.allocateTensors();

      final inputShape = interpreter.getInputTensor(0).shape;
      final outputShape = interpreter.getOutputTensor(0).shape;
      if (inputShape.isEmpty || inputShape.last != 6 ||
          outputShape.isEmpty || outputShape.last != 2) {
        debugPrint(
            'WeightPredictor: model shape mismatch (input=$inputShape, '
            'output=$outputShape), expected [.., 6] -> [.., 2]');
        interpreter.close();
        return false;
      }

      _interpreter?.close();
      _interpreter = interpreter;
      return true;
    } catch (e) {
      debugPrint('WeightPredictor: failed to load model: $e');
      try {
        interpreter?.close();
      } catch (_) {
        /* already invalid; nothing more to clean up */
      }
      return false;
    }
  }

  /// Predicts (grams, stdDevGrams) from the 6-feature vector documented in
  /// docs/AI_MODEL_CONTRACT.md, or null if no model is loaded, inference
  /// throws, or the model returns a non-finite/negative value (a garbage
  /// prediction is treated the same as no prediction at all).
  ModelPrediction? predict(List<double> features) {
    final interpreter = _interpreter;
    if (interpreter == null) return null;
    if (features.length != 6) {
      debugPrint('WeightPredictor: expected 6 features, got ${features.length}');
      return null;
    }
    try {
      final input = [features];
      final output = [List<double>.filled(2, 0.0)];
      interpreter.run(input, output);
      final grams = output[0][0];
      final stdDevGrams = output[0][1];
      if (!grams.isFinite || !stdDevGrams.isFinite || grams < 0 || stdDevGrams < 0) {
        debugPrint('WeightPredictor: rejected non-finite/negative prediction');
        return null;
      }
      return ModelPrediction(grams: grams, stdDevGrams: stdDevGrams);
    } catch (e) {
      debugPrint('WeightPredictor: inference failed: $e');
      return null;
    }
  }

  void dispose() {
    try {
      _interpreter?.close();
    } catch (_) {
      /* already closed/invalid */
    }
    _interpreter = null;
  }
}
