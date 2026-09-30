import 'dart:math';

enum ChartNormalization { raw, perFeature, logicToVisibleMax }

/// Peak amplitude in an inclusive sample range. Non-finite values are ignored.
double maximumAbsoluteValue(List<double> values, int start, int end) {
  var peak = 0.0;
  for (var i = max(0, start); i <= min(end, values.length - 1); i++) {
    final value = values[i];
    if (value.isFinite) peak = max(peak, value.abs());
  }
  return peak;
}

/// Display-only transformation; source values and logical edits remain 0/1.
double normalizedChartValue(
  double value, {
  required ChartNormalization mode,
  required bool isLogical,
  required double featureMaximum,
  required double visibleRawMaximum,
}) {
  switch (mode) {
    case ChartNormalization.raw:
      return value;
    case ChartNormalization.perFeature:
      final scale = featureMaximum.isFinite && featureMaximum > 0
          ? featureMaximum
          : 1.0;
      return value / scale;
    case ChartNormalization.logicToVisibleMax:
      if (!isLogical) return value;
      // Keep logic readable when there are no raw signals or all are zero.
      final scale = visibleRawMaximum.isFinite && visibleRawMaximum > 0
          ? visibleRawMaximum
          : 1.0;
      return value * scale;
  }
}
