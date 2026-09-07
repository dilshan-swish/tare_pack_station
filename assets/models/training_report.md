# TARE discrepancy model — training report

- **Model version:** `1.0.0`
- **Trained at (UTC):** 2026-07-22T10:12:55.752323Z
- **Test samples:** 3000
- **RNG seed:** 20240722 (reproducible)

## Headline metrics (held-out test set)

| Metric | Value |
| --- | --- |
| Strict top-1 accuracy (class **and** component) | 84.5% |
| Class accuracy | 91.5% |
| Top-3 hit rate | 94.3% |
| Brier score (0 = perfect calibration) | 0.1159 |

## Detection rate by error type

| Error type | Support | Correctly identified |
| --- | --- | --- |
| extraItem | 714 | 69.6% |
| extraModifier | 26 | 15.4% |
| missingItem | 773 | 88.2% |
| missingModifier | 13 | 38.5% |
| naturalVariation | 720 | 96.8% |
| wrongOrder | 754 | 86.2% |

## Trained parameters

```json
{
  "version": "1.0.0",
  "trainedAt": "2026-07-22T10:12:55.752323Z",
  "priorMissingItem": 1.3853926036134756,
  "priorMissingModifier": 0.9714936298193377,
  "priorExtraItem": 0.7125566569558108,
  "priorExtraModifier": 1.0348865357196597,
  "priorWrongOrder": 1.4617843098817298,
  "priorNaturalVariation": 0.8873489163162314,
  "scaleNoiseGrams": 4.830284315678594,
  "confidenceTemperature": 0.8992820537175259,
  "minConfidenceToShow": 0.24161495442584313,
  "wrongOrderMarginGrams": 9.555896566863478,
  "maxSuggestions": 3
}
```

> Regenerate with `dart run tool/train_discrepancy_model.dart <version>`. The app loads `discrepancy_model.json`; swap that file to update the model with no code change.
