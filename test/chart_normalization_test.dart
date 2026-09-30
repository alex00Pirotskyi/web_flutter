import 'package:flutter_test/flutter_test.dart';
import 'package:plot_web/chart_normalization.dart';

void main() {
  double display(
    double value, {
    ChartNormalization mode = ChartNormalization.logicToVisibleMax,
    bool isLogical = true,
    double featureMaximum = 1,
    double visibleRawMaximum = 250,
  }) => normalizedChartValue(
    value,
    mode: mode,
    isLogical: isLogical,
    featureMaximum: featureMaximum,
    visibleRawMaximum: visibleRawMaximum,
  );

  test('logical 1 matches raw peak; zero stays zero; raw values stay raw', () {
    expect(display(1), 250);
    expect(display(0), 0);
    expect(display(-42, isLogical: false), -42);
    expect(display(8, isLogical: false), 8);
  });

  test('amplitudes below one are not inflated to one', () {
    expect(display(1, visibleRawMaximum: 0.025), 0.025);
  });

  test('no raw amplitude keeps logical values readable at 0/1', () {
    for (final peak in [0.0, double.nan, double.infinity]) {
      expect(display(1, visibleRawMaximum: peak), 1);
      expect(display(0, visibleRawMaximum: peak), 0);
    }
  });

  test('peak uses absolute amplitude and only the visible sample range', () {
    final raw = [10000.0, 2.0, -80.0, 3.0, 9000.0];
    expect(maximumAbsoluteValue(raw, 0, 4), 10000);
    expect(maximumAbsoluteValue(raw, 1, 3), 80);
    expect(maximumAbsoluteValue(raw, 3, 3), 3);
    expect(raw, [10000, 2, -80, 3, 9000]);
  });

  test('visible edge peaks survive independent of chart downsampling', () {
    final raw = List<double>.filled(65536, 2);
    raw[32767] = -350;
    raw[32768] = 1200;
    expect(maximumAbsoluteValue(raw, 1, 32767), 350);
    expect(maximumAbsoluteValue(raw, 32768, 65535), 1200);
  });

  test('empty ranges and non-finite samples do not corrupt the scale', () {
    expect(maximumAbsoluteValue([], 0, 0), 0);
    expect(maximumAbsoluteValue([1, 2], 2, 1), 0);
    expect(
      maximumAbsoluteValue([1, -7, double.nan, double.infinity], -1, 9),
      7,
    );
  });

  test('existing raw and per-feature modes preserve their behavior', () {
    expect(display(1, mode: ChartNormalization.raw), 1);
    expect(
      display(
        -60,
        mode: ChartNormalization.perFeature,
        isLogical: false,
        featureMaximum: 120,
      ),
      -0.5,
    );
    expect(display(1, mode: ChartNormalization.perFeature), 1);
    expect(
      display(0, mode: ChartNormalization.perFeature, featureMaximum: 0),
      0,
    );
  });
}
