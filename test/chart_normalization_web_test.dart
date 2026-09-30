@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot_web/chart_normalization.dart';
import 'package:plot_web/main.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    // Chart preparation uses debounce timers and cooperatively yields.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets(
    'ten raw signals, visibility, zoom and logical edits share scale',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      final csv = StringBuffer('');
      csv.writeln('${List.generate(10, (i) => 'raw$i').join(',')},logic');
      for (var row = 0; row < 20; row++) {
        final values = List.generate(
          10,
          (i) => i == 9 && row == 0 ? 250 : (i + 1) * 2,
        );
        csv.writeln('${values.join(',')},${row % 2}');
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await state.selectFile(
          FileSystemItem(
            name: 'normalization.csv',
            content: Uint8List.fromList(utf8.encode(csv.toString())),
          ),
        );
      });
      expect(state.currentCsv, isNotNull);
      state.selectAllFeatures();
      state.setNormalization(ChartNormalization.logicToVisibleMax);
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: ChartArea())),
        ),
      );
      await settle(tester);

      SfCartesianChart chart() => tester.widget(find.byType(SfCartesianChart));
      double shown(String name, double value) {
        final series =
            chart().series.firstWhere((s) => s.name == name)
                as FastLineSeries<ChartSample, int>;
        return series.yValueMapper!(ChartSample(1, value), 0)!.toDouble();
      }

      expect(chart().series.length, 11);
      expect(shown('logic', 1), 250);
      expect(shown('logic', 0), 0);
      expect(shown('raw9', 20), 20);
      expect((chart().primaryYAxis as NumericAxis).maximum, isNull);

      state.toggleColumnVisibility('raw9');
      await settle(tester);
      expect(shown('logic', 1), 18);

      state.toggleColumnVisibility('raw9');
      await settle(tester);
      expect(shown('logic', 1), 250);
      chart().zoomPanBehavior!.zoomToSingleAxis(chart().primaryXAxis, 0.5, 0.5);
      await settle(tester);
      expect(shown('logic', 1), 20);

      state.unselectAllFeatures();
      state.toggleColumnVisibility('logic');
      await settle(tester);
      expect(shown('logic', 1), 1);
      expect(state.addLogicalFeatureRange('logic', 0, 0, 1), isNull);
      await settle(tester);
      expect(state.currentCsv!.data['logic']![0], 0);
      expect(state.logicalRangesFor('logic').single.value, 1);
      expect(shown('logic', 1), 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets(
    'legacy normalization preference migrates and new mode persists',
    (tester) async {
      SharedPreferences.setMockInitialValues({'is_normalized': true});
      final state = AppState();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      expect(state.normalization, ChartNormalization.perFeature);
      state.setNormalization(ChartNormalization.logicToVisibleMax);
      final restored = AppState();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      expect(restored.normalization, ChartNormalization.logicToVisibleMax);
      expect(restored.isNormalized, isFalse);
      state.dispose();
      restored.dispose();
    },
  );
}
