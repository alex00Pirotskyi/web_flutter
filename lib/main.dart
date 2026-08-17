import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:html' as html; // Only works on Flutter Web
import 'dart:ui' show FontFeature;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:yaml/yaml.dart'; // REQUIRED: Add 'yaml: ^3.1.2' to pubspec.yaml

// -----------------------------------------------------------------------------
// 1. DATA MODELS
// -----------------------------------------------------------------------------

enum FileStatus { unmarked, pass, fail }

enum FileVisualState { unmarked, cleanPass, editedPass, fail }

// Pantone-inspired workspace palette. Color is used as a restrained
// navigation/accent system; technical surfaces and typography stay neutral.
class WorkspaceColors {
  static const explorer = Color(0xFF0F4C81); // Classic Blue inspired
  static const features = Color(0xFF88B04B); // Greenery inspired
  static const logic = Color(0xFFFF6F61); // Living Coral inspired
  static const process = Color(0xFF5F4B8B); // Ultra Violet inspired
  static const settings = Color(0xFFF5DF4D); // Illuminating inspired

  static Color forIndex(int index) {
    switch (index) {
      case 0:
        return explorer;
      case 1:
        return features;
      case 2:
        return logic;
      case 3:
        return process;
      case 4:
        return settings;
      default:
        return explorer;
    }
  }
}

class LogicalFeatureRange {
  final int start;
  final int end;
  final int value;

  const LogicalFeatureRange({
    required this.start,
    required this.end,
    required this.value,
  });
}

class FileSystemItem {
  String name;
  bool isFolder;
  List<FileSystemItem> children;
  Uint8List? content;
  PlatformFile? pickedFile; // Lazy/streamed standalone CSV source.
  ArchiveFile? archiveEntry; // Fallback path when the web worker is unavailable.
  String? zipArchiveId;
  int? zipEntryId;
  String? path;
  bool isExpanded;
  FileStatus status;
  List<List<int>> invalidRanges;
  Map<String, List<LogicalFeatureRange>> logicalFeatureRanges;

  bool get hasChanges =>
      invalidRanges.isNotEmpty ||
      logicalFeatureRanges.values.any((ranges) => ranges.isNotEmpty);

  FileVisualState get visualState {
    if (status == FileStatus.fail) return FileVisualState.fail;
    if (status == FileStatus.pass && hasChanges) {
      return FileVisualState.editedPass;
    }
    if (status == FileStatus.pass) return FileVisualState.cleanPass;
    return FileVisualState.unmarked;
  }

  FileSystemItem({
    required this.name,
    this.isFolder = false,
    List<FileSystemItem>? children,
    this.content,
    this.pickedFile,
    this.archiveEntry,
    this.zipArchiveId,
    this.zipEntryId,
    this.path,
    this.isExpanded = false,
    this.status = FileStatus.unmarked,
    List<List<int>>? invalidRanges,
    Map<String, List<LogicalFeatureRange>>? logicalFeatureRanges,
  })  : children = children ?? <FileSystemItem>[],
        invalidRanges = invalidRanges ?? <List<int>>[],
        logicalFeatureRanges =
            logicalFeatureRanges ?? <String, List<LogicalFeatureRange>>{};
}

class CsvDataSet {
  final String fileName;
  final List<String> headers;
  final Map<String, Float64List> data;
  final Set<String> logicalHeaders;
  final Map<String, double> _normalizationScales = {};
  final Map<String, double> _minimumValues = {};
  final Map<String, double> _maximumValues = {};

  CsvDataSet(
    this.fileName,
    this.headers,
    this.data,
    this.logicalHeaders, {
    Map<String, double>? normalizationScales,
    Map<String, double>? minimumValues,
    Map<String, double>? maximumValues,
  }) {
    if (normalizationScales != null) {
      _normalizationScales.addAll(normalizationScales);
    }
    if (minimumValues != null) _minimumValues.addAll(minimumValues);
    if (maximumValues != null) _maximumValues.addAll(maximumValues);

    for (final header in headers) {
      final values = data[header];
      if (values == null || values.isEmpty) {
        _normalizationScales.putIfAbsent(header, () => 1.0);
        _minimumValues.putIfAbsent(header, () => 0.0);
        _maximumValues.putIfAbsent(header, () => 0.0);
        continue;
      }

      final needsScale = !_normalizationScales.containsKey(header);
      final needsMin = !_minimumValues.containsKey(header);
      final needsMax = !_maximumValues.containsKey(header);
      if (!needsScale && !needsMin && !needsMax) continue;

      var scale = 0.0;
      var minimum = double.infinity;
      var maximum = double.negativeInfinity;
      for (final value in values) {
        if (needsScale) scale = max(scale, value.abs());
        if (needsMin) minimum = min(minimum, value);
        if (needsMax) maximum = max(maximum, value);
      }
      if (needsScale) {
        _normalizationScales[header] = scale == 0.0 ? 1.0 : scale;
      }
      if (needsMin) {
        _minimumValues[header] = minimum.isFinite ? minimum : 0.0;
      }
      if (needsMax) {
        _maximumValues[header] = maximum.isFinite ? maximum : 0.0;
      }
    }
  }

  int get rowCount => data.isEmpty ? 0 : data.values.first.length;

  double normalizationScaleFor(String header) =>
      _normalizationScales[header] ?? 1.0;
  double minimumFor(String header) => _minimumValues[header] ?? 0.0;
  double maximumFor(String header) => _maximumValues[header] ?? 0.0;
}


class _Float64ColumnBuilder {
  static const int _chunkSize = 8192;
  final List<Float64List> _fullChunks = <Float64List>[];
  Float64List _active = Float64List(_chunkSize);
  int _activeLength = 0;
  int _length = 0;

  int get length => _length;

  void add(double value) {
    if (_activeLength == _active.length) {
      _fullChunks.add(_active);
      _active = Float64List(_chunkSize);
      _activeLength = 0;
    }
    _active[_activeLength++] = value;
    _length++;
  }

  Float64List finish() {
    final result = Float64List(_length);
    var offset = 0;
    for (final chunk in _fullChunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    if (_activeLength > 0) {
      result.setRange(offset, offset + _activeLength, _active, 0);
    }
    return result;
  }
}

class ChartSample {
  final int x;
  final double y;

  const ChartSample(this.x, this.y);
}

class _LogicalValueCursor {
  final List<LogicalFeatureRange> ranges;
  int _rangeIndex = 0;

  _LogicalValueCursor(this.ranges);

  double valueAt(Float64List raw, int index) {
    while (_rangeIndex < ranges.length &&
        ranges[_rangeIndex].end < index) {
      _rangeIndex++;
    }
    if (_rangeIndex < ranges.length) {
      final range = ranges[_rangeIndex];
      if (index >= range.start && index <= range.end) {
        return range.value.toDouble();
      }
    }
    return raw[index];
  }
}

class _CsvApplyPlan {
  final int column;
  final List<LogicalFeatureRange> ranges;
  int cursor = 0;

  _CsvApplyPlan(this.column, this.ranges);
}

class _ZipWorkerEntry {
  final int id;
  final String path;
  final int compressedSize;
  final int uncompressedSize;

  const _ZipWorkerEntry({
    required this.id,
    required this.path,
    required this.compressedSize,
    required this.uncompressedSize,
  });

  String get name => path.split('/').last;
}

class _WorkerParsedCsv {
  final List<String> headers;
  final List<Float64List> columns;
  final Set<String> logicalHeaders;
  final List<double> normalizationScales;
  final List<double> minimumValues;
  final List<double> maximumValues;

  const _WorkerParsedCsv({
    required this.headers,
    required this.columns,
    required this.logicalHeaders,
    required this.normalizationScales,
    required this.minimumValues,
    required this.maximumValues,
  });

  CsvDataSet toDataSet(String fileName) {
    final data = <String, Float64List>{};
    final scales = <String, double>{};
    final minimums = <String, double>{};
    final maximums = <String, double>{};
    for (var i = 0; i < headers.length; i++) {
      data[headers[i]] = columns[i];
      final scale = i < normalizationScales.length
          ? normalizationScales[i]
          : 1.0;
      scales[headers[i]] = scale == 0.0 ? 1.0 : scale;
      if (i < minimumValues.length) minimums[headers[i]] = minimumValues[i];
      if (i < maximumValues.length) maximums[headers[i]] = maximumValues[i];
    }
    return CsvDataSet(
      fileName,
      headers,
      data,
      logicalHeaders,
      normalizationScales: scales,
      minimumValues: minimums,
      maximumValues: maximums,
    );
  }
}

class _ZipIndexFailure implements Exception {
  final String message;
  final Uint8List bytes;

  const _ZipIndexFailure(this.message, this.bytes);

  @override
  String toString() => message;
}

/// Optional web-worker client used to keep ZIP directory parsing and DEFLATE
/// extraction off Flutter's UI event loop. If the worker asset is unavailable,
/// AppState transparently falls back to package:archive.
class _ZipWorkerClient {
  html.Worker? _worker;
  int _nextRequestId = 1;
  final Map<int, Completer<List<dynamic>>> _pending = {};

  _ZipWorkerClient() {
    try {
      final worker = html.Worker(Uri.base.resolve('data_worker.js').toString());
      worker.onMessage.listen(_handleMessage);
      worker.onError.listen((event) {
        _failAll('ZIP worker failed: ${event.toString()}');
        _worker = null;
      });
      _worker = worker;
    } catch (_) {
      _worker = null;
    }
  }

  bool get available => _worker != null;

  void _handleMessage(html.MessageEvent event) {
    final dynamic raw = event.data;
    if (raw is! List || raw.length < 2) return;
    final requestId = (raw[1] as num?)?.toInt();
    if (requestId == null) return;
    final completer = _pending.remove(requestId);
    if (completer == null) return;
    final response = List<dynamic>.from(raw);
    if (response.first == 'error') {
      completer.completeError(
        response.length > 2 ? response[2].toString() : 'ZIP worker error',
      );
    } else {
      completer.complete(response);
    }
  }

  void _failAll(String message) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(message);
    }
  }

  Future<List<dynamic>> _request(
    List<dynamic> message, {
    List<Object>? transfer,
  }) {
    final worker = _worker;
    if (worker == null) {
      return Future<List<dynamic>>.error('ZIP worker unavailable');
    }
    final requestId = _nextRequestId++;
    message.insert(1, requestId);
    final completer = Completer<List<dynamic>>();
    _pending[requestId] = completer;
    try {
      worker.postMessage(message, transfer);
    } catch (e) {
      _pending.remove(requestId);
      completer.completeError(e);
    }
    return completer.future;
  }

  Uint8List _decodeWorkerBytes(dynamic payload) {
    if (payload is Uint8List) return payload;
    if (payload is ByteBuffer) return Uint8List.view(payload);
    if (payload is List<int>) return Uint8List.fromList(payload);
    if (payload is List) {
      return Uint8List.fromList(
        payload.cast<num>().map((value) => value.toInt()).toList(),
      );
    }
    throw StateError('Worker returned an unsupported byte payload.');
  }

  Future<List<_ZipWorkerEntry>> indexZip(
    String archiveId,
    Uint8List bytes,
  ) async {
    final response = await _request(
      <dynamic>['index', archiveId, bytes],
      transfer: <Object>[bytes.buffer],
    );
    if (response.first == 'indexError') {
      final returned = response.length > 3
          ? _decodeWorkerBytes(response[3])
          : Uint8List(0);
      throw _ZipIndexFailure(
        response.length > 2 ? response[2].toString() : 'ZIP worker error',
        returned,
      );
    }
    final decoded = jsonDecode(response[2].toString());
    if (decoded is! List) return const <_ZipWorkerEntry>[];
    return decoded.map((dynamic raw) {
      final map = Map<String, dynamic>.from(raw as Map);
      return _ZipWorkerEntry(
        id: (map['id'] as num).toInt(),
        path: map['path'].toString(),
        compressedSize: (map['compressedSize'] as num).toInt(),
        uncompressedSize: (map['uncompressedSize'] as num).toInt(),
      );
    }).toList(growable: false);
  }

  Future<Uint8List> extract(String archiveId, int entryId) async {
    final response = await _request(<dynamic>['extract', archiveId, entryId]);
    return _decodeWorkerBytes(response[2]);
  }

  Future<_WorkerParsedCsv> parseCsv(Uint8List bytes) async {
    final response = await _request(<dynamic>['parseCsv', bytes]);
    return _decodeParsedCsv(response);
  }

  Future<_WorkerParsedCsv> parseZipEntry(
    String archiveId,
    int entryId,
  ) async {
    final response =
        await _request(<dynamic>['parseZipEntry', archiveId, entryId]);
    return _decodeParsedCsv(response);
  }

  _WorkerParsedCsv _decodeParsedCsv(List<dynamic> response) {
    final metadata =
        Map<String, dynamic>.from(jsonDecode(response[2].toString()) as Map);
    final headers = (metadata['headers'] as List)
        .map((value) => value.toString())
        .toList(growable: false);
    final logical = (metadata['logicalHeaders'] as List? ?? const <dynamic>[])
        .map((value) => value.toString())
        .toSet();
    final scales = (metadata['normalizationScales'] as List? ??
            const <dynamic>[])
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
    final minimums = (metadata['minimumValues'] as List? ?? const <dynamic>[])
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
    final maximums = (metadata['maximumValues'] as List? ?? const <dynamic>[])
        .map((value) => (value as num).toDouble())
        .toList(growable: false);

    final dynamic payload = response[3];
    if (payload is! List) {
      throw StateError('CSV worker returned an unsupported column payload.');
    }
    final columns = <Float64List>[];
    for (final dynamic raw in payload) {
      if (raw is Float64List) {
        columns.add(raw);
      } else if (raw is ByteBuffer) {
        columns.add(Float64List.view(raw));
      } else if (raw is List) {
        columns.add(
          Float64List.fromList(
            raw.cast<num>().map((value) => value.toDouble()).toList(),
          ),
        );
      } else {
        throw StateError('Unsupported CSV worker column type: ${raw.runtimeType}');
      }
    }
    if (columns.length != headers.length) {
      throw StateError(
        'CSV worker returned ${columns.length} columns for ${headers.length} headers.',
      );
    }
    return _WorkerParsedCsv(
      headers: headers,
      columns: columns,
      logicalHeaders: logical,
      normalizationScales: scales,
      minimumValues: minimums,
      maximumValues: maximums,
    );
  }

  Future<void> processCsvToOutput(
    String sessionId,
    String path,
    Uint8List bytes,
    String rulesJson,
  ) async {
    await _request(<dynamic>[
      'processCsvToOutput',
      sessionId,
      path,
      bytes,
      rulesJson,
    ]);
  }

  Future<void> processZipEntryToOutput(
    String sessionId,
    String archiveId,
    int entryId,
    String path,
    String rulesJson,
  ) async {
    await _request(<dynamic>[
      'processZipEntryToOutput',
      sessionId,
      archiveId,
      entryId,
      path,
      rulesJson,
    ]);
  }

  Future<void> addTextToOutput(
    String sessionId,
    String path,
    String text,
  ) async {
    await _request(<dynamic>['addTextToOutput', sessionId, path, text]);
  }

  Future<Uint8List> finalizeOutput(String sessionId) async {
    final response = await _request(<dynamic>['finalizeOutput', sessionId]);
    return _decodeWorkerBytes(response[2]);
  }

  Future<void> discardOutput(String sessionId) async {
    try {
      await _request(<dynamic>['discardOutput', sessionId]);
    } catch (_) {}
  }

  void releaseArchive(String archiveId) {
    try {
      _worker?.postMessage(<dynamic>['release', 0, archiveId]);
    } catch (_) {}
  }

  void clear() {
    try {
      _worker?.postMessage(<dynamic>['clear', 0]);
    } catch (_) {}
  }
}

// -----------------------------------------------------------------------------
// 2. APP STATE (PROVIDER)
// -----------------------------------------------------------------------------

class AppState extends ChangeNotifier {
  SharedPreferences? _prefs;
  bool _isLoading = false;
  double? _loadingProgress;
  String _loadingMessage = '';
  int _loadedFileCount = 0;

  int _selectedIndex = 0;
  List<FileSystemItem> _rootItems = [];
  FileSystemItem? _selectedFileItem;
  CsvDataSet? _currentCsv;
  Set<String> _visibleColumns = {};
  int _chartRevision = 0;
  int _dataRevision = 0;
  int _explorerRevision = 0;
  int _featureRevision = 0;

  // Lightweight workspace state. These values survive navigation between
  // sidebars without invalidating chart data or forcing expensive rebuilds.
  double _explorerScrollOffset = 0.0;
  String _explorerSearchQuery = '';
  String? _preferredLogicalFeature;

  final _zipWorker = _ZipWorkerClient();
  final Map<String, Uint8List> _zipFallbackBytes = {};
  final Map<String, int> _zipItemCounts = {};
  int _nextZipArchiveId = 1;

  bool _isNormalized = false;
  bool _showTooltip = true;
  bool _showMarkers = false;
  double _markerSize = 4.0;
  bool _isLegendExpanded = true;

  bool get isLoading => _isLoading;
  double? get loadingProgress => _loadingProgress;
  String get loadingMessage => _loadingMessage;
  int get loadedFileCount => _loadedFileCount;
  int get selectedIndex => _selectedIndex;
  List<FileSystemItem> get rootItems => _rootItems;
  FileSystemItem? get selectedFileItem => _selectedFileItem;
  CsvDataSet? get currentCsv => _currentCsv;
  Set<String> get visibleColumns => _visibleColumns;
  bool get isNormalized => _isNormalized;
  bool get showTooltip => _showTooltip;
  bool get showMarkers => _showMarkers;
  double get markerSize => _markerSize;
  bool get isLegendExpanded => _isLegendExpanded;
  int get chartRevision => _chartRevision;
  int get dataRevision => _dataRevision;
  int get explorerRevision => _explorerRevision;
  int get featureRevision => _featureRevision;
  double get explorerScrollOffset => _explorerScrollOffset;
  String get explorerSearchQuery => _explorerSearchQuery;
  String? get preferredLogicalFeature => _preferredLogicalFeature;
  int get selectedRowCount => _currentCsv?.rowCount ?? 0;
  List<String> get logicalFeatureHeaders {
    final features = _currentCsv?.logicalHeaders.toList() ?? <String>[];
    features.sort();
    return features;
  }

  String? get effectiveLogicalFeature {
    final features = logicalFeatureHeaders;
    if (features.isEmpty) return null;
    final preferred = _preferredLogicalFeature;
    if (preferred != null && features.contains(preferred)) return preferred;
    return features.first;
  }

  AppState() {
    _initPrefs();
  }

  void _notifyChart({
    bool dataChanged = false,
    bool explorerChanged = false,
    bool featuresChanged = false,
  }) {
    _chartRevision++;
    if (dataChanged) _dataRevision++;
    if (explorerChanged) _explorerRevision++;
    if (featuresChanged) _featureRevision++;
    notifyListeners();
  }

  void _notifyUi({
    bool explorerChanged = false,
    bool featuresChanged = false,
  }) {
    if (explorerChanged) _explorerRevision++;
    if (featuresChanged) _featureRevision++;
    notifyListeners();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _isNormalized = _prefs?.getBool('is_normalized') ?? false;
    _preferredLogicalFeature = _prefs?.getString('preferred_logical_feature');
    _notifyChart();
  }

  void setExplorerScrollOffset(double offset) {
    if (!offset.isFinite) return;
    _explorerScrollOffset = max(0.0, offset);
  }

  void setExplorerSearchQuery(String query) {
    _explorerSearchQuery = query;
  }

  void setPreferredLogicalFeature(String feature) {
    if (feature.isEmpty || _preferredLogicalFeature == feature) return;
    _preferredLogicalFeature = feature;
    _prefs?.setString('preferred_logical_feature', feature);
    _notifyUi();
  }

  void setNavIndex(int index) {
    _selectedIndex = index;
    notifyListeners();
  }

  void toggleLegend() {
    _isLegendExpanded = !_isLegendExpanded;
    _notifyUi();
  }

  void setFolderExpansion(FileSystemItem item, bool expanded) {
    item.isExpanded = expanded;
  }

  void setFileStatus(FileSystemItem item, FileStatus status) {
    item.status = item.status == status ? FileStatus.unmarked : status;
    _notifyUi(explorerChanged: true);
  }

  // --- Range and logical-feature management ---
  String? addInvalidRange(int start, int end) {
    if (_selectedFileItem == null || _currentCsv == null) {
      return 'Select a CSV file first.';
    }
    if (start < 0 || end < start || end >= _currentCsv!.rowCount) {
      return 'Use a range between 0 and ${_currentCsv!.rowCount - 1}.';
    }
    _selectedFileItem!.invalidRanges.add([start, end]);
    _selectedFileItem!.invalidRanges.sort((a, b) => a[0].compareTo(b[0]));
    _notifyChart();
    return null;
  }

  void removeInvalidRange(int index) {
    if (_selectedFileItem != null &&
        index >= 0 &&
        index < _selectedFileItem!.invalidRanges.length) {
      _selectedFileItem!.invalidRanges.removeAt(index);
      _notifyChart();
    }
  }

  String? addLogicalFeatureRange(
    String feature,
    int start,
    int end,
    int value,
  ) {
    if (_selectedFileItem == null || _currentCsv == null) {
      return 'Select a CSV file first.';
    }
    if (!_currentCsv!.logicalHeaders.contains(feature)) {
      return '“$feature” is not a Boolean feature. Only 0/1 or true/false columns can be edited.';
    }
    if (value != 0 && value != 1) {
      return 'Logical value must be 0 or 1.';
    }
    if (start < 0 || end < start || end >= _currentCsv!.rowCount) {
      return 'Use a range between 0 and ${_currentCsv!.rowCount - 1}.';
    }

    final ranges = _selectedFileItem!.logicalFeatureRanges.putIfAbsent(
      feature,
      () => <LogicalFeatureRange>[],
    );
    final overlaps = ranges.any(
      (range) => !(end < range.start || start > range.end),
    );
    if (overlaps) {
      return 'This range overlaps an existing edit for $feature. Remove the old range first.';
    }

    ranges.add(LogicalFeatureRange(start: start, end: end, value: value));
    ranges.sort((a, b) => a.start.compareTo(b.start));
    _notifyChart(dataChanged: true);
    return null;
  }

  void removeLogicalFeatureRange(String feature, int index) {
    final ranges = _selectedFileItem?.logicalFeatureRanges[feature];
    if (ranges == null || index < 0 || index >= ranges.length) return;
    ranges.removeAt(index);
    if (ranges.isEmpty) {
      _selectedFileItem!.logicalFeatureRanges.remove(feature);
    }
    _notifyChart(dataChanged: true);
  }

  List<LogicalFeatureRange> logicalRangesFor(String feature) =>
      List.unmodifiable(
        _selectedFileItem?.logicalFeatureRanges[feature] ??
            const <LogicalFeatureRange>[],
      );

  // --- YAML export/import ---
  String _yamlKey(String value) {
    final escaped = value.replaceAll("'", "''");
    return "'$escaped'";
  }

  String _buildYamlContent() {
    final yamlContent = StringBuffer();

    void traverse(List<FileSystemItem> items) {
      for (final item in items) {
        if (!item.isFolder) {
          String statusStr = 'UNMARKED';
          if (item.status == FileStatus.pass) statusStr = 'PASS';
          if (item.status == FileStatus.fail) statusStr = 'FAIL';

          final fileKey = item.path?.isNotEmpty == true ? item.path! : item.name;
          yamlContent.writeln('${_yamlKey(fileKey)}:');
          yamlContent.writeln('  status: $statusStr');

          if (item.invalidRanges.isNotEmpty) {
            yamlContent.writeln('  invalid_ranges:');
            for (final range in item.invalidRanges) {
              yamlContent.writeln('    - [${range[0]}, ${range[1]}]');
            }
          }

          if (item.logicalFeatureRanges.isNotEmpty) {
            yamlContent.writeln('  logical_features:');
            final features = item.logicalFeatureRanges.keys.toList()..sort();
            for (final feature in features) {
              final ranges = item.logicalFeatureRanges[feature]!;
              if (ranges.isEmpty) continue;
              yamlContent.writeln('    ${_yamlKey(feature)}:');
              for (final range in ranges) {
                yamlContent.writeln('      - start: ${range.start}');
                yamlContent.writeln('        end: ${range.end}');
                yamlContent.writeln('        value: ${range.value}');
              }
            }
          }
        }
        if (item.children.isNotEmpty) traverse(item.children);
      }
    }

    traverse(_rootItems);
    return yamlContent.toString();
  }

  void _downloadBytes(Uint8List bytes, String fileName, String mimeType) {
    final blob = html.Blob(<Object>[bytes], mimeType);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  void downloadTagInfo() {
    final bytes = Uint8List.fromList(utf8.encode(_buildYamlContent()));
    _downloadBytes(bytes, 'tag_info.yaml', 'application/x-yaml');
  }

  List<FileSystemItem> _allLeafItems() {
    final out = <FileSystemItem>[];
    void collect(List<FileSystemItem> items) {
      for (final item in items) {
        if (item.isFolder) {
          collect(item.children);
        } else {
          out.add(item);
        }
      }
    }
    collect(_rootItems);
    return out;
  }

  String _rulesJsonFor(FileSystemItem item) {
    final logical = <String, List<List<int>>>{};
    for (final entry in item.logicalFeatureRanges.entries) {
      if (entry.value.isEmpty) continue;
      logical[entry.key] = entry.value
          .map((range) => <int>[range.start, range.end, range.value])
          .toList(growable: false);
    }
    return jsonEncode(<String, Object>{
      'logical': logical,
      'invalid': item.invalidRanges,
    });
  }

  String _uniqueOutputPath(
    FileSystemItem item,
    Set<String> usedPaths,
  ) {
    var path = (item.path?.isNotEmpty == true ? item.path! : item.name)
        .replaceAll('\\', '/');
    while (path.startsWith('/')) path = path.substring(1);
    final safeSegments = path
        .split('/')
        .where((segment) => segment.isNotEmpty && segment != '.' && segment != '..')
        .toList(growable: false);
    path = safeSegments.join('/');
    if (path.isEmpty) path = item.name;
    if (usedPaths.add(path)) return path;

    final slash = path.lastIndexOf('/');
    final dir = slash >= 0 ? path.substring(0, slash + 1) : '';
    final leaf = slash >= 0 ? path.substring(slash + 1) : path;
    final dot = leaf.lastIndexOf('.');
    final stem = dot > 0 ? leaf.substring(0, dot) : leaf;
    final ext = dot > 0 ? leaf.substring(dot) : '';
    var suffix = 2;
    while (true) {
      final candidate = '$dir${stem}__$suffix$ext';
      if (usedPaths.add(candidate)) return candidate;
      suffix++;
    }
  }

  Future<void> applyYamlAndDownloadZip() async {
    final allItems = _allLeafItems();
    if (allItems.isEmpty || _isLoading) return;

    // FAIL is a file-level rejection. Rejected datasets must never be included
    // in the processed output archive. Filter them before any parsing, logical
    // edits, invalid-range removal, or worker work is started.
    final failedItemCount =
        allItems.where((item) => item.status == FileStatus.fail).length;
    final items = allItems
        .where((item) => item.status != FileStatus.fail)
        .toList(growable: false);

    _setLoadingState(
      loading: true,
      message: failedItemCount == 0
          ? 'Preparing YAML application…'
          : 'Preparing YAML application • $failedItemCount FAIL excluded',
      progress: 0,
      loadedFileCount: 0,
    );

    // Keep failed entries in the audit manifest so the downloaded package
    // records why those source datasets are absent from the processed ZIP.
    final yamlManifest = _buildYamlContent();
    final sessionId = 'yaml_apply_${DateTime.now().microsecondsSinceEpoch}';
    final usedPaths = <String>{};

    try {
      Uint8List? zipBytes;

      if (_zipWorker.available) {
        try {
          for (var i = 0; i < items.length; i++) {
            final item = items[i];
            final outputPath = _uniqueOutputPath(item, usedPaths);
            _loadingMessage = 'Applying YAML • ${i + 1}/${items.length} • ${item.name}';
            _loadingProgress = i / max(1, items.length);
            notifyListeners();
            await Future<void>.delayed(Duration.zero);

            final rules = _rulesJsonFor(item);
            final archiveId = item.zipArchiveId;
            final entryId = item.zipEntryId;
            if (archiveId != null && entryId != null) {
              await _zipWorker.processZipEntryToOutput(
                sessionId,
                archiveId,
                entryId,
                outputPath,
                rules,
              );
            } else {
              final bytes = await _materializeItemContent(item);
              if (bytes == null) {
                throw StateError('Unable to read ${item.name}.');
              }
              await _zipWorker.processCsvToOutput(
                sessionId,
                outputPath,
                bytes,
                rules,
              );
            }
          }

          await _zipWorker.addTextToOutput(
            sessionId,
            'applied_tag_info.yaml',
            yamlManifest,
          );
          _loadingMessage = 'Building processed ZIP…';
          _loadingProgress = 0.98;
          notifyListeners();
          zipBytes = await _zipWorker.finalizeOutput(sessionId);
        } catch (e) {
          debugPrint('Worker YAML application fallback: $e');
          await _zipWorker.discardOutput(sessionId);
          zipBytes = null;
        }
      }

      if (zipBytes == null) {
        // Compatibility fallback. The normal web path above performs both the
        // transformation and ZIP creation in the Web Worker.
        final archive = Archive();
        usedPaths.clear();
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
          final outputPath = _uniqueOutputPath(item, usedPaths);
          _loadingMessage = 'Applying YAML (fallback) • ${i + 1}/${items.length} • ${item.name}';
          _loadingProgress = i / max(1, items.length);
          notifyListeners();
          final bytes = await _materializeItemContent(item);
          if (bytes == null) throw StateError('Unable to read ${item.name}.');
          final processed = await _transformCsvForYamlApply(bytes, item);
          archive.addFile(ArchiveFile(outputPath, processed.length, processed));
          await Future<void>.delayed(Duration.zero);
        }
        final manifestBytes = Uint8List.fromList(utf8.encode(yamlManifest));
        archive.addFile(
          ArchiveFile(
            'applied_tag_info.yaml',
            manifestBytes.length,
            manifestBytes,
          ),
        );
        final encoded = ZipEncoder().encode(archive);
        if (encoded == null) throw StateError('Could not encode output ZIP.');
        zipBytes = encoded is Uint8List
            ? encoded
            : Uint8List.fromList(encoded);
      }

      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');
      final stamp = '${now.year}${two(now.month)}${two(now.day)}_'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}';
      _downloadBytes(
        zipBytes!,
        'signal_analysis_applied_$stamp.zip',
        'application/zip',
      );
      _loadingProgress = 1.0;
      _loadingMessage = 'Processed ZIP downloaded';
      notifyListeners();
      await Future<void>.delayed(Duration.zero);
    } catch (e) {
      debugPrint('Error applying YAML: $e');
      _loadingMessage = 'Apply YAML failed: $e';
      notifyListeners();
      await Future<void>.delayed(Duration.zero);
    } finally {
      _setLoadingState(
        loading: false,
        message: '',
        progress: null,
      );
    }
  }

  Future<Uint8List> _transformCsvForYamlApply(
    Uint8List bytes,
    FileSystemItem item,
  ) async {
    if (item.logicalFeatureRanges.isEmpty && item.invalidRanges.isEmpty) {
      return Uint8List.fromList(bytes);
    }

    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.isEmpty) return Uint8List.fromList(bytes);

    List<String>? headers;
    final output = StringBuffer();
    final row = <String>[];
    var field = StringBuffer();
    var inQuotes = false;
    var sampleIndex = 0;
    var invalidCursor = 0;
    final invalid = item.invalidRanges.toList()
      ..sort((a, b) => a[0].compareTo(b[0]));
    final plans = <_CsvApplyPlan>[];

    String escapeCell(String value) {
      if (!value.contains(',') &&
          !value.contains('"') &&
          !value.contains('\n') &&
          !value.contains('\r')) {
        return value;
      }
      final escaped = value.replaceAll('"', '""');
      return '"$escaped"';
    }

    void writeRow(List<String> cells) {
      for (var i = 0; i < cells.length; i++) {
        if (i > 0) output.write(',');
        output.write(escapeCell(cells[i]));
      }
      output.writeln();
    }

    void commitField() {
      row.add(field.toString());
      field = StringBuffer();
    }

    void consumeRow() {
      if (row.isEmpty) return;
      if (headers == null) {
        headers = row.map((value) => value.trim()).toList(growable: false);
        for (final entry in item.logicalFeatureRanges.entries) {
          final column = headers!.indexOf(entry.key);
          if (column >= 0 && entry.value.isNotEmpty) {
            final ranges = entry.value.toList()
              ..sort((a, b) => a.start.compareTo(b.start));
            plans.add(_CsvApplyPlan(column, ranges));
          }
        }
        writeRow(row);
        row.clear();
        return;
      }

      if (row.length == 1 && row.first.trim().isEmpty) {
        row.clear();
        return;
      }

      // IMPORTANT: logical edits use original sample indexes and are applied
      // before invalid ranges remove rows. This preserves YAML index meaning.
      for (final plan in plans) {
        while (plan.cursor < plan.ranges.length &&
            plan.ranges[plan.cursor].end < sampleIndex) {
          plan.cursor++;
        }
        if (plan.cursor < plan.ranges.length) {
          final range = plan.ranges[plan.cursor];
          if (sampleIndex >= range.start && sampleIndex <= range.end) {
            while (row.length <= plan.column) row.add('');
            row[plan.column] = range.value.toString();
          }
        }
      }

      while (invalidCursor < invalid.length &&
          invalid[invalidCursor][1] < sampleIndex) {
        invalidCursor++;
      }
      final remove = invalidCursor < invalid.length &&
          sampleIndex >= invalid[invalidCursor][0] &&
          sampleIndex <= invalid[invalidCursor][1];
      if (!remove) writeRow(row);
      sampleIndex++;
      row.clear();
    }

    var lastYield = 0;
    for (var i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if (code == 34) {
        if (inQuotes && i + 1 < text.length && text.codeUnitAt(i + 1) == 34) {
          field.writeCharCode(34);
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (!inQuotes && code == 44) {
        commitField();
      } else if (!inQuotes && (code == 10 || code == 13)) {
        commitField();
        consumeRow();
        if (code == 13 && i + 1 < text.length && text.codeUnitAt(i + 1) == 10) {
          i++;
        }
      } else {
        field.writeCharCode(code);
      }

      if (i - lastYield >= 300000) {
        lastYield = i;
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (field.length > 0 || row.isNotEmpty) {
      commitField();
      consumeRow();
    }
    return Uint8List.fromList(utf8.encode(output.toString()));
  }

  Future<void> uploadTagInfo() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['yaml', 'yml', 'txt'],
        withData: true,
      );
      if (result != null &&
          result.files.isNotEmpty &&
          result.files.first.bytes != null) {
        final content = utf8.decode(result.files.first.bytes!);
        _syncTags(content);
      }
    } catch (e) {
      debugPrint('Error uploading tags: $e');
    }
  }

  int? _yamlInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  int? _yamlBinaryValue(dynamic value) {
    if (value is bool) return value ? 1 : 0;
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'true') return 1;
    if (normalized == 'false') return 0;
    final number = _yamlInt(value);
    return number == 0 || number == 1 ? number : null;
  }

  void _syncTags(String yamlContent) {
    try {
      final doc = loadYaml(yamlContent);
      if (doc is! YamlMap) return;

      final tagMap = <String, FileStatus>{};
      final rangesMap = <String, List<List<int>>>{};
      final logicalMap =
          <String, Map<String, List<LogicalFeatureRange>>>{};

      for (final rawKey in doc.keys) {
        final key = rawKey.toString();
        final val = doc[rawKey];

        if (val is YamlMap) {
          final statusStr =
              val['status']?.toString().trim().toUpperCase() ?? 'UNMARKED';
          if (statusStr == 'PASS') {
            tagMap[key] = FileStatus.pass;
          } else if (statusStr == 'FAIL') {
            tagMap[key] = FileStatus.fail;
          } else {
            tagMap[key] = FileStatus.unmarked;
          }

          final ranges = val['invalid_ranges'];
          if (ranges is YamlList) {
            final parsedRanges = <List<int>>[];
            for (final r in ranges) {
              if (r is YamlList && r.length == 2) {
                final start = _yamlInt(r[0]);
                final end = _yamlInt(r[1]);
                if (start != null && end != null && start <= end) {
                  parsedRanges.add([start, end]);
                }
              }
            }
            rangesMap[key] = parsedRanges;
          }

          final logicalFeatures = val['logical_features'];
          if (logicalFeatures is YamlMap) {
            final parsedFeatures = <String, List<LogicalFeatureRange>>{};
            for (final rawFeature in logicalFeatures.keys) {
              final feature = rawFeature.toString();
              final edits = logicalFeatures[rawFeature];
              if (edits is! YamlList) continue;
              final parsedEdits = <LogicalFeatureRange>[];
              for (final edit in edits) {
                int? start;
                int? end;
                int? value;
                if (edit is YamlMap) {
                  start = _yamlInt(edit['start']);
                  end = _yamlInt(edit['end']);
                  value = _yamlBinaryValue(edit['value']);
                } else if (edit is YamlList && edit.length == 3) {
                  start = _yamlInt(edit[0]);
                  end = _yamlInt(edit[1]);
                  value = _yamlBinaryValue(edit[2]);
                }
                if (start != null &&
                    end != null &&
                    value != null &&
                    start <= end) {
                  parsedEdits.add(
                    LogicalFeatureRange(start: start, end: end, value: value),
                  );
                }
              }
              if (parsedEdits.isNotEmpty) {
                parsedEdits.sort((a, b) => a.start.compareTo(b.start));
                parsedFeatures[feature] = parsedEdits;
              }
            }
            logicalMap[key] = parsedFeatures;
          }
        } else {
          final statusStr =
              val?.toString().trim().toUpperCase() ?? 'UNMARKED';
          if (statusStr == 'PASS') {
            tagMap[key] = FileStatus.pass;
          } else if (statusStr == 'FAIL') {
            tagMap[key] = FileStatus.fail;
          } else {
            tagMap[key] = FileStatus.unmarked;
          }
        }
      }

      void updateItems(List<FileSystemItem> items) {
        for (final item in items) {
          if (!item.isFolder) {
            final primaryKey =
                item.path?.isNotEmpty == true ? item.path! : item.name;
            final status = tagMap[primaryKey] ?? tagMap[item.name];
            final invalid = rangesMap[primaryKey] ?? rangesMap[item.name];
            final logical = logicalMap[primaryKey] ?? logicalMap[item.name];
            if (status != null) item.status = status;
            if (invalid != null) item.invalidRanges = invalid;
            if (logical != null) item.logicalFeatureRanges = logical;
          }
          if (item.children.isNotEmpty) updateItems(item.children);
        }
      }

      updateItems(_rootItems);
      _notifyChart(dataChanged: true, explorerChanged: true);
    } catch (e) {
      debugPrint('Error parsing YAML: $e');
    }
  }

  void _setLoadingState({
    required bool loading,
    String message = '',
    double? progress,
    int? loadedFileCount,
  }) {
    _isLoading = loading;
    _loadingMessage = message;
    _loadingProgress = progress;
    if (loadedFileCount != null) {
      _loadedFileCount = loadedFileCount;
    }
    notifyListeners();
  }

  Future<void> uploadFiles() async {
    _setLoadingState(
      loading: true,
      message: 'Choose CSV or ZIP files…',
      progress: null,
      loadedFileCount: 0,
    );

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['csv', 'zip'],
        // Do not eagerly materialize every selected file. This is critical
        // when users select hundreds of CSVs at once on Flutter Web.
        withData: false,
        withReadStream: true,
      );

      if (result == null || result.files.isEmpty) return;

      final files = result.files;
      var completedInputs = 0;
      var discoveredCsvFiles = 0;

      // Give Flutter a frame to paint the loading UI before heavier ZIP work.
      await Future<void>.delayed(Duration.zero);

      for (final file in files) {
        final ext = (file.extension ?? '').toLowerCase();

        if (ext == 'zip') {
          _setLoadingState(
            loading: true,
            message: 'Reading ${file.name}…',
            progress: completedInputs / files.length,
            loadedFileCount: discoveredCsvFiles,
          );
          await Future<void>.delayed(Duration.zero);
          final bytes = await _readPlatformFileBytes(file);
          if (bytes != null) {
            discoveredCsvFiles += await _handleZip(bytes, file.name);
          }
        } else if (ext == 'csv') {
          _addPickedFileToRoot(file);
          discoveredCsvFiles++;
        }

        completedInputs++;

        // Rebuild/yield in batches for large multi-file selections. Updating
        // after every individual file makes imports measurably slower.
        final shouldYield = ext == 'zip' ||
            completedInputs == files.length ||
            completedInputs % 25 == 0;
        if (shouldYield) {
          _setLoadingState(
            loading: true,
            message: 'Loaded $discoveredCsvFiles CSV file'
                '${discoveredCsvFiles == 1 ? '' : 's'}',
            progress: completedInputs / files.length,
            loadedFileCount: discoveredCsvFiles,
          );
          await Future<void>.delayed(Duration.zero);
        }
      }
    } catch (e) {
      debugPrint('Error uploading file: $e');
    } finally {
      _setLoadingState(
        loading: false,
        message: '',
        progress: null,
      );
    }
  }

  Future<int> _handleZip(Uint8List bytes, String zipName) async {
    final archiveId = 'zip_${_nextZipArchiveId++}';
    var fallbackBytes = bytes;

    // Preferred path: transfer the archive into a browser Web Worker. This
    // avoids a second long-lived copy of a potentially huge ZIP on the UI
    // thread. On index failure the worker transfers the buffer back.
    if (_zipWorker.available) {
      try {
        _loadingMessage = 'Indexing $zipName in background…';
        notifyListeners();
        final entries = await _zipWorker.indexZip(archiveId, bytes);
        var added = 0;
        for (final entry in entries) {
          final leafName = entry.name;
          if (entry.path.contains('__MACOSX') || leafName.startsWith('._')) {
            continue;
          }
          if (!entry.path.toLowerCase().endsWith('.csv')) continue;
          _rootItems.add(
            FileSystemItem(
              name: leafName,
              isFolder: false,
              zipArchiveId: archiveId,
              zipEntryId: entry.id,
              path: entry.path,
            ),
          );
          added++;
        }
        if (added > 0) {
          _zipItemCounts[archiveId] = added;
        } else {
          _zipWorker.releaseArchive(archiveId);
        }
        _notifyUi(explorerChanged: true);
        return added;
      } on _ZipIndexFailure catch (e) {
        if (e.bytes.isNotEmpty) fallbackBytes = e.bytes;
        debugPrint('ZIP worker fallback for $zipName: $e');
      } catch (e) {
        debugPrint('ZIP worker unavailable for $zipName, using fallback: $e');
      }
    }

    // Compatibility fallback. This can briefly occupy the UI thread, but only
    // when the worker asset/browser path is unavailable or rejects the archive.
    _zipFallbackBytes[archiveId] = fallbackBytes;
    final archive = ZipDecoder().decodeBytes(fallbackBytes);
    var added = 0;
    var scanned = 0;
    for (final file in archive) {
      scanned++;
      final leafName = file.name.split('/').last;
      if (file.name.contains('__MACOSX') || leafName.startsWith('._')) continue;
      if (file.isFile && file.name.toLowerCase().endsWith('.csv')) {
        _rootItems.add(
          FileSystemItem(
            name: leafName,
            isFolder: false,
            archiveEntry: file,
            path: file.name,
          ),
        );
        added++;
      }
      if (scanned % 100 == 0) {
        _loadingMessage = 'Indexing $zipName • $added CSV files found';
        _notifyUi(explorerChanged: true);
        await Future<void>.delayed(Duration.zero);
      }
    }
    _notifyUi(explorerChanged: true);
    return added;
  }

  void _addPickedFileToRoot(PlatformFile file) {
    _rootItems.add(
      FileSystemItem(
        name: file.name,
        isFolder: false,
        pickedFile: file,
        path: file.name,
      ),
    );
    _explorerRevision++;
  }

  Future<Uint8List?> _readPlatformFileBytes(PlatformFile file) async {
    final eager = file.bytes;
    if (eager != null) return eager;
    final stream = file.readStream;
    if (stream == null) {
      debugPrint('No byte stream is available for ${file.name}.');
      return null;
    }

    final builder = BytesBuilder(copy: false);
    var read = 0;
    await for (final chunk in stream) {
      builder.add(chunk);
      read += chunk.length;
      if (read == file.size || read % (4 * 1024 * 1024) < chunk.length) {
        _loadingMessage = 'Reading ${file.name} • '
            '${(100 * read / max(1, file.size)).clamp(0, 100).toStringAsFixed(0)}%';
        notifyListeners();
        await Future<void>.delayed(Duration.zero);
      }
    }
    return builder.takeBytes();
  }

  Future<Uint8List?> _materializeItemContent(FileSystemItem item) async {
    if (item.content != null) return item.content;

    final pickedFile = item.pickedFile;
    if (pickedFile != null) {
      final bytes = await _readPlatformFileBytes(pickedFile);
      if (bytes != null) item.content = bytes;
      return bytes;
    }

    final archiveId = item.zipArchiveId;
    final entryId = item.zipEntryId;
    if (archiveId != null && entryId != null) {
      try {
        final decoded = await _zipWorker.extract(archiveId, entryId);
        item.content = decoded;
        return decoded;
      } catch (e) {
        debugPrint('Worker extraction fallback for ${item.path}: $e');
        final zipBytes = _zipFallbackBytes[archiveId];
        if (zipBytes != null) {
          final archive = ZipDecoder().decodeBytes(zipBytes);
          for (final file in archive) {
            if (file.isFile && file.name == item.path) {
              final content = file.content as List<int>;
              item.content = content is Uint8List
                  ? content
                  : Uint8List.fromList(content);
              return item.content;
            }
          }
        }
      }
    }

    final archiveEntry = item.archiveEntry;
    if (archiveEntry == null) return null;
    final decoded = archiveEntry.content as List<int>;
    item.content = decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
    item.archiveEntry = null;
    return item.content;
  }

  void clearAllFiles() {
    _rootItems.clear();
    _currentCsv = null;
    _selectedFileItem = null;
    _visibleColumns.clear();
    _explorerScrollOffset = 0.0;
    _zipFallbackBytes.clear();
    _zipItemCounts.clear();
    _zipWorker.clear();
    _notifyChart(dataChanged: true, explorerChanged: true, featuresChanged: true);
  }

  void removeFile(FileSystemItem itemToRemove) {
    final archiveId = itemToRemove.zipArchiveId;
    if (archiveId != null) {
      final remaining = (_zipItemCounts[archiveId] ?? 1) - 1;
      if (remaining <= 0) {
        _zipItemCounts.remove(archiveId);
        _zipFallbackBytes.remove(archiveId);
        _zipWorker.releaseArchive(archiveId);
      } else {
        _zipItemCounts[archiveId] = remaining;
      }
    }

    if (_rootItems.contains(itemToRemove)) {
      _rootItems.remove(itemToRemove);
    } else {
      for (var root in _rootItems) {
        _removeFromChildren(root, itemToRemove);
      }
    }
    if (_selectedFileItem == itemToRemove) {
      _currentCsv = null;
      _selectedFileItem = null;
      _visibleColumns.clear();
      _notifyChart(
        dataChanged: true,
        explorerChanged: true,
        featuresChanged: true,
      );
      return;
    }
    _notifyUi(explorerChanged: true);
  }

  bool _removeFromChildren(FileSystemItem parent, FileSystemItem target) {
    if (parent.children.contains(target)) {
      parent.children.remove(target);
      return true;
    }
    for (var child in parent.children) {
      bool found = _removeFromChildren(child, target);
      if (found) return true;
    }
    return false;
  }

  double? _parseCsvCell(dynamic raw) {
    if (raw is bool) return raw ? 1.0 : 0.0;
    if (raw is num) {
      final value = raw.toDouble();
      return value.isFinite ? value : null;
    }
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return null;
    final lower = value.toLowerCase();
    if (lower == 'true') return 1.0;
    if (lower == 'false') return 0.0;
    final parsed = double.tryParse(value);
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  Future<String> _decodeUtf8Incrementally(
    Uint8List bytes,
    String fileName,
  ) async {
    final buffer = StringBuffer();
    final output = StringConversionSink.fromStringSink(buffer);
    final input = const Utf8Decoder().startChunkedConversion(output);
    const chunkSize = 512 * 1024;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = min(bytes.length, offset + chunkSize);
      input.add(Uint8List.sublistView(bytes, offset, end));
      _loadingProgress = bytes.isEmpty ? 0.0 : 0.18 * end / bytes.length;
      _loadingMessage =
          'Decoding $fileName • ${(100 * end / max(1, bytes.length)).toStringAsFixed(0)}%';
      notifyListeners();
      await Future<void>.delayed(Duration.zero);
    }
    input.close();
    return buffer.toString();
  }

  Future<CsvDataSet?> _parseCsvIncrementally(
    Uint8List bytes,
    String fileName,
  ) async {
    // Avoid CsvToListConverter's full List<List<dynamic>> materialization.
    // This parser supports quoted fields, escaped quotes and newlines inside
    // quoted fields while yielding to the browser between chunks.
    final csvString = await _decodeUtf8Incrementally(bytes, fileName);
    if (csvString.isEmpty) return null;

    List<String>? headers;
    List<_Float64ColumnBuilder>? columns;
    List<double>? maxAbsByColumn;
    List<double>? minimumByColumn;
    List<double>? maximumByColumn;
    Set<String>? logicalCandidates;
    final logicalValueSeen = <String>{};

    final row = <String>[];
    var field = StringBuffer();
    var inQuotes = false;
    var processedChars = 0;

    void commitField() {
      row.add(field.toString());
      field = StringBuffer();
    }

    void consumeRow() {
      if (row.isEmpty) return;
      if (headers == null) {
        headers = row.map((value) => value.trim()).toList(growable: false);
        columns = List<_Float64ColumnBuilder>.generate(
          headers!.length,
          (_) => _Float64ColumnBuilder(),
          growable: false,
        );
        maxAbsByColumn = List<double>.filled(headers!.length, 0.0);
        minimumByColumn = List<double>.filled(headers!.length, double.infinity);
        maximumByColumn = List<double>.filled(headers!.length, double.negativeInfinity);
        logicalCandidates = headers!.toSet();
        row.clear();
        return;
      }

      // Ignore a completely empty trailing line.
      if (row.length == 1 && row.first.trim().isEmpty) {
        row.clear();
        return;
      }

      for (var j = 0; j < headers!.length; j++) {
        final header = headers![j];
        final parsed = j < row.length ? _parseCsvCell(row[j]) : null;
        if (parsed == null) {
          columns![j].add(0.0);
          minimumByColumn![j] = min(minimumByColumn![j], 0.0);
          maximumByColumn![j] = max(maximumByColumn![j], 0.0);
          logicalCandidates!.remove(header);
          continue;
        }
        columns![j].add(parsed);
        maxAbsByColumn![j] = max(maxAbsByColumn![j], parsed.abs());
        minimumByColumn![j] = min(minimumByColumn![j], parsed);
        maximumByColumn![j] = max(maximumByColumn![j], parsed);
        if (parsed == 0.0 || parsed == 1.0) {
          logicalValueSeen.add(header);
        } else {
          logicalCandidates!.remove(header);
        }
      }
      row.clear();
    }

    for (var i = 0; i < csvString.length; i++) {
      final code = csvString.codeUnitAt(i);
      if (code == 34) { // quote
        if (inQuotes && i + 1 < csvString.length &&
            csvString.codeUnitAt(i + 1) == 34) {
          field.writeCharCode(34);
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (!inQuotes && code == 44) { // comma
        commitField();
      } else if (!inQuotes && (code == 10 || code == 13)) { // newline
        commitField();
        consumeRow();
        if (code == 13 && i + 1 < csvString.length &&
            csvString.codeUnitAt(i + 1) == 10) {
          i++;
        }
      } else {
        field.writeCharCode(code);
      }

      if (i - processedChars >= 250000) {
        processedChars = i;
        _loadingProgress = 0.18 + 0.74 * i / csvString.length;
        _loadingMessage = 'Parsing $fileName • ${(100 * i / csvString.length).toStringAsFixed(0)}%';
        notifyListeners();
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (field.length > 0 || row.isNotEmpty) {
      commitField();
      consumeRow();
    }
    if (headers == null || columns == null) return null;

    logicalCandidates!.removeWhere(
      (header) => !logicalValueSeen.contains(header),
    );

    final typedData = <String, Float64List>{};
    final normalizationScales = <String, double>{};
    final minimumValues = <String, double>{};
    final maximumValues = <String, double>{};
    for (var j = 0; j < headers!.length; j++) {
      final header = headers![j];
      typedData[header] = columns![j].finish();
      final scale = maxAbsByColumn![j];
      normalizationScales[header] = scale == 0.0 ? 1.0 : scale;
      final columnMin = minimumByColumn![j];
      final columnMax = maximumByColumn![j];
      minimumValues[header] = columnMin.isFinite ? columnMin : 0.0;
      maximumValues[header] = columnMax.isFinite ? columnMax : 0.0;
      if (j % 8 == 7) await Future<void>.delayed(Duration.zero);
    }

    return CsvDataSet(
      fileName,
      headers!,
      typedData,
      logicalCandidates!,
      normalizationScales: normalizationScales,
      minimumValues: minimumValues,
      maximumValues: maximumValues,
    );
  }

  Future<void> selectFile(FileSystemItem item) async {
    if (item.isFolder) return;

    _selectedFileItem = item;
    _notifyUi(explorerChanged: true);

    final previousLoading = _isLoading;
    final previousMessage = _loadingMessage;
    final previousProgress = _loadingProgress;
    final previousCount = _loadedFileCount;

    _setLoadingState(
      loading: true,
      message: item.zipArchiveId != null
          ? 'Opening ${item.name} from ZIP…'
          : item.content == null
              ? 'Reading ${item.name}…'
              : 'Parsing ${item.name}…',
      progress: 0,
    );
    await Future<void>.delayed(Duration.zero);

    try {
      CsvDataSet? parsed;

      if (_zipWorker.available) {
        try {
          _loadingMessage = 'Analyzing ${item.name} in background…';
          _loadingProgress = null;
          notifyListeners();
          final archiveId = item.zipArchiveId;
          final entryId = item.zipEntryId;
          _WorkerParsedCsv? workerResult;
          if (archiveId != null && entryId != null) {
            workerResult = await _zipWorker.parseZipEntry(archiveId, entryId);
          } else {
            final bytes = item.content ?? await _materializeItemContent(item);
            if (bytes != null) {
              workerResult = await _zipWorker.parseCsv(bytes);
            }
          }
          parsed = workerResult?.toDataSet(item.name);
        } catch (e) {
          debugPrint('CSV worker fallback for ${item.name}: $e');
        }
      }

      if (parsed == null) {
        final bytes = await _materializeItemContent(item);
        if (bytes == null) return;
        parsed = await _parseCsvIncrementally(bytes, item.name);
      }
      if (parsed == null) return;
      _currentCsv = parsed;

      final savedSelection = await _loadSelectionFromPrefs();
      final candidateSelection =
          _visibleColumns.isNotEmpty ? _visibleColumns : savedSelection;
      _visibleColumns = candidateSelection
          .where((column) => parsed!.headers.contains(column))
          .toSet();
      _saveSelectionToPrefs();
    } catch (e) {
      debugPrint('Error parsing: $e');
    } finally {
      _setLoadingState(
        loading: previousLoading,
        message: previousMessage,
        progress: previousProgress,
        loadedFileCount: previousCount,
      );
    }
    _notifyChart(
      dataChanged: true,
      explorerChanged: true,
      featuresChanged: true,
    );
  }

  void toggleColumnVisibility(String header) {
    if (_visibleColumns.contains(header)) {
      _visibleColumns.remove(header);
    } else {
      _visibleColumns.add(header);
    }
    _saveSelectionToPrefs();
    _notifyChart(featuresChanged: true);
  }

  void selectAllFeatures() {
    if (_currentCsv != null) {
      _visibleColumns = Set.from(_currentCsv!.headers);
      _saveSelectionToPrefs();
      _notifyChart(featuresChanged: true);
    }
  }

  void unselectAllFeatures() {
    _visibleColumns.clear();
    _saveSelectionToPrefs();
    _notifyChart(featuresChanged: true);
  }

  Future<void> _saveSelectionToPrefs() async {
    if (_prefs == null) return;
    await _prefs!.setStringList('selected_features', _visibleColumns.toList());
  }

  Future<Set<String>> _loadSelectionFromPrefs() async {
    if (_prefs == null) return {};
    List<String>? saved = _prefs!.getStringList('selected_features');
    return saved != null ? Set.from(saved) : {};
  }

  void setNormalization(bool value) {
    _isNormalized = value;
    _prefs?.setBool('is_normalized', value);
    _notifyChart();
  }

  void setTooltipEnabled(bool value) {
    _showTooltip = value;
    _notifyChart();
  }

  void setShowMarkers(bool value) {
    _showMarkers = value;
    _notifyChart();
  }

  void setMarkerSize(double value) {
    _markerSize = value;
    _notifyChart();
  }

}

// -----------------------------------------------------------------------------
// 3. MAIN UI
// -----------------------------------------------------------------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => AppState())],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const base = Color(0xFF0B0F14);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Signal Analysis Studio',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: base,
        canvasColor: const Color(0xFF0F141B),
        dividerColor: const Color(0xFF242B35),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8EA7C2),
          secondary: Color(0xFFA9B4C0),
          surface: Color(0xFF11171F),
          error: Color(0xFFFF6B6B),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0D1218),
          isDense: true,
          hintStyle: const TextStyle(color: Color(0xFF687483)),
          labelStyle: const TextStyle(color: Color(0xFFA8B1BD)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: Color(0xFF2A323D)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: Color(0xFF2A323D)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: Color(0xFF7E93AA), width: 1.2),
          ),
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: const Color(0xFF202833),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF394452)),
          ),
          textStyle: const TextStyle(color: Colors.white, fontSize: 11.5),
        ),
      ),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final existingScale = media.textScaler.scale(1.0);
        final readableScale = max(1.15, existingScale);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(readableScale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const MainLayout(),
    );
  }
}

class MainLayout extends StatelessWidget {
  const MainLayout({super.key});

  @override
  Widget build(BuildContext context) {
    final selectedIndex = context.select<AppState, int>((s) => s.selectedIndex);
    final fileName = context.select<AppState, String>(
      (s) => s.currentCsv?.fileName ?? 'No dataset selected',
    );
    final metrics = context.select<AppState, String>((s) {
      final csv = s.currentCsv;
      if (csv == null) return 'Ready';
      return '${_formatCount(csv.rowCount)} samples   •   '
          '${csv.headers.length} features   •   '
          '${s.visibleColumns.length} visible   •   '
          '${csv.logicalHeaders.length} logical';
    });
    final accent = WorkspaceColors.forIndex(selectedIndex);
    final viewportWidth = MediaQuery.of(context).size.width;
    final sideWidth = viewportWidth < 1180 ? 314.0 : 352.0;

    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(painter: _AbstractAnalysisBackdropPainter()),
            ),
          ),
          Positioned.fill(
            child: Column(
              children: [
                _ApplicationTopBar(fileName: fileName, metrics: metrics),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                    child: Row(
                      children: [
                        _WorkspaceNavigation(
                          selectedIndex: selectedIndex,
                          onSelected: context.read<AppState>().setNavIndex,
                        ),
                        const SizedBox(width: 9),
                        SizedBox(
                          width: sideWidth,
                          child: _WorkspacePanel(
                            title: _getSidebarTitle(selectedIndex),
                            accent: accent,
                            child: _buildSidebarContent(selectedIndex),
                          ),
                        ),
                        const SizedBox(width: 9),
                        const Expanded(child: _ChartWorkspaceSurface()),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatCount(int value) {
    final text = value.toString();
    final out = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) out.write(',');
      out.write(text[i]);
    }
    return out.toString();
  }

  String _getSidebarTitle(int index) {
    switch (index) {
      case 0:
        return 'DATASETS';
      case 1:
        return 'VISIBLE FEATURES';
      case 2:
        return 'LOGICAL FEATURE EDITOR';
      case 3:
        return 'DATA PROCESSING';
      case 4:
        return 'SETTINGS';
      default:
        return '';
    }
  }

  Widget _buildSidebarContent(int index) {
    switch (index) {
      case 0:
        return const ExplorerSidebar();
      case 1:
        return const FeatureSelectorSidebar();
      case 2:
        return const LogicalFeatureSidebar();
      case 3:
        return const ProcessSidebar();
      case 4:
        return const SettingsSidebar();
      default:
        return const SizedBox();
    }
  }
}

class _ApplicationTopBar extends StatelessWidget {
  final String fileName;
  final String metrics;

  const _ApplicationTopBar({required this.fileName, required this.metrics});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 68,
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 9),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xEE10161D),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF252E39)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFF17202A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF34404D)),
            ),
            child: const Icon(Icons.show_chart_rounded, size: 19),
          ),
          const SizedBox(width: 11),
          const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SIGNAL ANALYSIS STUDIO',
                style: TextStyle(
                  fontSize: 11.5,
                  letterSpacing: 1.45,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFEBF0F5),
                ),
              ),
              SizedBox(height: 2),
              Text(
                'Inspection • labeling • logical annotation',
                style: TextStyle(fontSize: 11, color: Color(0xFF7F8B99)),
              ),
            ],
          ),
          const SizedBox(width: 26),
          Container(width: 1, height: 28, color: const Color(0xFF2A323D)),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFF3F6F9),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  metrics,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8793A1),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspacePanel extends StatelessWidget {
  final String title;
  final Color accent;
  final Widget child;

  const _WorkspacePanel({
    required this.title,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xF211171F),
          border: Border.all(color: const Color(0xFF252E39)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 45,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF252E39))),
              ),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 20,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFFE8EDF3),
                        fontSize: 10.5,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _ChartWorkspaceSurface extends StatelessWidget {
  const _ChartWorkspaceSurface();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFA0D1218),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF252E39)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 22,
            offset: Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: const ChartArea(),
    );
  }
}

class _WorkspaceNavItem {
  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;

  const _WorkspaceNavItem(this.label, this.subtitle, this.icon, this.color);
}

class _WorkspaceNavigation extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _WorkspaceNavigation({
    required this.selectedIndex,
    required this.onSelected,
  });

  static const _items = <_WorkspaceNavItem>[
    _WorkspaceNavItem('Explorer', 'Datasets', Icons.folder_open_rounded, WorkspaceColors.explorer),
    _WorkspaceNavItem('Features', 'Signals', Icons.view_list_rounded, WorkspaceColors.features),
    _WorkspaceNavItem('Logic', '0 / 1 ranges', Icons.toggle_on_rounded, WorkspaceColors.logic),
    _WorkspaceNavItem('Process', 'Validation', Icons.tune_rounded, WorkspaceColors.process),
    _WorkspaceNavItem('Settings', 'Display', Icons.settings_rounded, WorkspaceColors.settings),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 170,
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xF20D1218),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF252E39)),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 4, 8, 11),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'WORKSPACES',
                style: TextStyle(
                  color: Color(0xFF6E7B89),
                  fontSize: 9.5,
                  letterSpacing: 1.35,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          for (var i = 0; i < _items.length; i++) ...[
            _ProfessionalNavCard(
              item: _items[i],
              selected: selectedIndex == i,
              onTap: () => onSelected(i),
            ),
            if (i != _items.length - 1) const SizedBox(height: 7),
          ],
          const Spacer(),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'ANALYSIS MODE',
              style: TextStyle(
                color: Color(0xFF53606D),
                fontSize: 9,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfessionalNavCard extends StatelessWidget {
  final _WorkspaceNavItem item;
  final bool selected;
  final VoidCallback onTap;

  const _ProfessionalNavCard({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 64,
          decoration: BoxDecoration(
            color: selected
                ? item.color.withOpacity(0.115)
                : const Color(0xFF111820),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? item.color.withOpacity(0.58)
                  : const Color(0xFF252F3A),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: selected ? 4 : 3,
                margin: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: item.color,
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(3),
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: item.color.withOpacity(0.28),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                item.icon,
                size: 21,
                color: selected
                    ? const Color(0xFFF4F7FA)
                    : const Color(0xFF98A3AF),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label,
                      style: TextStyle(
                        color: selected
                            ? const Color(0xFFF4F7FA)
                            : const Color(0xFFCBD2D9),
                        fontSize: 12.5,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle,
                      style: const TextStyle(
                        color: Color(0xFF687583),
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AbstractAnalysisBackdropPainter extends CustomPainter {
  const _AbstractAnalysisBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF090D12),
    );

    final blue = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = WorkspaceColors.explorer.withOpacity(0.075);
    final violet = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = WorkspaceColors.process.withOpacity(0.060);
    final green = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = WorkspaceColors.features.withOpacity(0.040);

    final p1 = Path()
      ..moveTo(size.width * 0.02, size.height * 0.72)
      ..cubicTo(
        size.width * 0.22,
        size.height * 0.43,
        size.width * 0.33,
        size.height * 0.95,
        size.width * 0.55,
        size.height * 0.67,
      )
      ..cubicTo(
        size.width * 0.69,
        size.height * 0.49,
        size.width * 0.83,
        size.height * 0.71,
        size.width * 1.02,
        size.height * 0.37,
      );
    canvas.drawPath(p1, blue);

    for (var i = 1; i <= 5; i++) {
      canvas.save();
      canvas.translate(0, i * 18.0);
      canvas.drawPath(p1, blue..color = WorkspaceColors.explorer.withOpacity(0.020));
      canvas.restore();
    }

    final p2 = Path()
      ..moveTo(size.width * 0.32, -30)
      ..cubicTo(
        size.width * 0.42,
        size.height * 0.18,
        size.width * 0.72,
        size.height * 0.06,
        size.width * 0.89,
        size.height * 0.30,
      );
    canvas.drawPath(p2, violet);

    canvas.drawCircle(
      Offset(size.width * 0.91, size.height * 0.13),
      160,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = WorkspaceColors.logic.withOpacity(0.035),
    );
    canvas.drawCircle(
      Offset(size.width * 0.13, size.height * 0.19),
      90,
      green,
    );
  }

  @override
  bool shouldRepaint(covariant _AbstractAnalysisBackdropPainter oldDelegate) => false;
}

// -----------------------------------------------------------------------------
// 4. SIDEBAR CONTENTS
// -----------------------------------------------------------------------------

class ExplorerSidebar extends StatefulWidget {
  const ExplorerSidebar({super.key});

  @override
  State<ExplorerSidebar> createState() => _ExplorerSidebarState();
}

class _ExplorerSidebarState extends State<ExplorerSidebar> {
  final TextEditingController _searchCtrl = TextEditingController();
  late ScrollController _scrollController;
  Timer? _searchDebounce;
  String _query = '';
  int _lastExplorerRevision = -1;
  String _lastFilter = '';
  List<FileSystemItem> _visibleItems = const <FileSystemItem>[];
  bool _workspaceStateInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_workspaceStateInitialized) return;

    final state = context.read<AppState>();
    final savedSearch = state.explorerSearchQuery;
    _searchCtrl.text = savedSearch;
    _query = savedSearch.trim().toLowerCase();
    _scrollController = ScrollController(
      initialScrollOffset: max(0.0, state.explorerScrollOffset),
    );
    _scrollController.addListener(_rememberScrollOffset);
    _workspaceStateInitialized = true;

    WidgetsBinding.instance.addPostFrameCallback((_) => _clampScrollOffset());
  }

  void _rememberScrollOffset() {
    if (!_scrollController.hasClients) return;
    context.read<AppState>().setExplorerScrollOffset(_scrollController.offset);
  }

  void _clampScrollOffset() {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final clamped = _scrollController.offset
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((clamped - _scrollController.offset).abs() > 0.5) {
      _scrollController.jumpTo(clamped);
    }
    context.read<AppState>().setExplorerScrollOffset(clamped);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    if (_workspaceStateInitialized) {
      _scrollController.removeListener(_rememberScrollOffset);
      _scrollController.dispose();
    }
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matches(FileSystemItem item, String query) {
    if (query.isEmpty) return true;
    final name = item.name.toLowerCase();
    final path = item.path?.toLowerCase() ?? '';
    if (name.contains(query) || path.contains(query)) return true;
    return item.children.any((child) => _matches(child, query));
  }

  void _queueSearch(String value) {
    // Store the exact text immediately so navigation away during the debounce
    // window cannot lose what the user typed. Filtering itself stays debounced.
    context.read<AppState>().setExplorerSearchQuery(value);
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() => _query = value.trim().toLowerCase());
      WidgetsBinding.instance.addPostFrameCallback((_) => _clampScrollOffset());
    });
  }

  List<FileSystemItem> _filteredItems(
    List<FileSystemItem> roots,
    int revision,
  ) {
    if (_lastExplorerRevision != revision || _lastFilter != _query) {
      _lastExplorerRevision = revision;
      _lastFilter = _query;
      _visibleItems = _query.isEmpty
          ? List<FileSystemItem>.unmodifiable(roots)
          : roots.where((item) => _matches(item, _query)).toList(growable: false);
    }
    return _visibleItems;
  }

  @override
  Widget build(BuildContext context) {
    final explorerRevision =
        context.select<AppState, int>((s) => s.explorerRevision);
    final isLoading = context.select<AppState, bool>((s) => s.isLoading);
    final loadingProgress =
        context.select<AppState, double?>((s) => s.loadingProgress);
    final loadingMessage =
        context.select<AppState, String>((s) => s.loadingMessage);
    final roots = context.read<AppState>().rootItems;
    final visibleItems = _filteredItems(roots, explorerRevision);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 11, 10, 8),
          child: Column(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.add_rounded, size: 17),
                label: const Text('Add CSV / ZIP'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 38),
                  backgroundColor: const Color(0xFF182534),
                  foregroundColor: const Color(0xFFF0F4F8),
                  side: BorderSide(
                    color: WorkspaceColors.explorer.withOpacity(0.72),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
                onPressed: isLoading
                    ? null
                    : () => context.read<AppState>().uploadFiles(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _CompactActionButton(
                      icon: Icons.file_upload_outlined,
                      label: 'Import YAML',
                      onPressed: isLoading
                          ? null
                          : () => context.read<AppState>().uploadTagInfo(),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: _CompactActionButton(
                      icon: Icons.file_download_outlined,
                      label: 'Export YAML',
                      onPressed: isLoading
                          ? null
                          : () => context.read<AppState>().downloadTagInfo(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Tooltip(
                message: 'Apply logical 0/1 edits first, then remove invalid-range rows, and download processed CSVs as a new ZIP.',
                child: FilledButton.icon(
                  icon: const Icon(Icons.inventory_2_outlined, size: 17),
                  label: const Text('Apply YAML  →  Download ZIP'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 39),
                    backgroundColor: const Color(0xFF1A2925),
                    foregroundColor: const Color(0xFFF2F6F4),
                    side: BorderSide(
                      color: WorkspaceColors.features.withOpacity(0.58),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  onPressed: isLoading || roots.isEmpty
                      ? null
                      : () => context.read<AppState>().applyYamlAndDownloadZip(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _searchCtrl,
                onChanged: _queueSearch,
                decoration: InputDecoration(
                  hintText: 'Search datasets or paths',
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 17,
                    color: Color(0xFF7D8997),
                  ),
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _searchDebounce?.cancel();
                            _searchCtrl.clear();
                            context.read<AppState>().setExplorerSearchQuery('');
                            setState(() => _query = '');
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => _clampScrollOffset(),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Text(
                    _query.isEmpty
                        ? '${roots.length} datasets'
                        : '${visibleItems.length} of ${roots.length}',
                    style: const TextStyle(
                      color: Color(0xFF788593),
                      fontSize: 10.5,
                    ),
                  ),
                  const Spacer(),
                  if (roots.isNotEmpty)
                    TextButton.icon(
                      onPressed: isLoading
                          ? null
                          : () => context.read<AppState>().clearAllFiles(),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 15),
                      label: const Text('Clear'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFC97B7B),
                        visualDensity: VisualDensity.compact,
                        textStyle: const TextStyle(fontSize: 10.5),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (isLoading) ...[
          LinearProgressIndicator(
            value: loadingProgress,
            minHeight: 2,
            color: WorkspaceColors.explorer,
            backgroundColor: const Color(0xFF1D2630),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(11, 7, 11, 7),
            child: Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    loadingMessage.isEmpty ? 'Processing…' : loadingMessage,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF8A96A3),
                      fontSize: 10.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const Divider(height: 1),
        Expanded(
          child: roots.isEmpty
              ? const _SidebarEmptyState(
                  icon: Icons.folder_open_outlined,
                  title: 'No datasets',
                  message: 'Add CSV files or a ZIP archive to begin analysis.',
                )
              : visibleItems.isEmpty
                  ? const _SidebarEmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No matches',
                      message: 'No dataset matches the current search.',
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: visibleItems.length,
                      itemExtent: 48,
                      cacheExtent: 420,
                      itemBuilder: (ctx, i) => FileNode(item: visibleItems[i]),
                    ),
        ),
      ],
    );
  }
}

class _CompactActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _CompactActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 15),
      label: Text(label, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFD6DCE2),
        side: const BorderSide(color: Color(0xFF303A46)),
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        textStyle: const TextStyle(fontSize: 11.25),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    );
  }
}

class FileNode extends StatelessWidget {
  final FileSystemItem item;
  const FileNode({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    // A compact selector means thousands of file rows do not rebuild when an
    // unrelated chart/settings notification is sent through AppState.
    context.select<AppState, int>((state) {
      var stamp = identical(state.selectedFileItem, item) ? 1 : 0;
      stamp |= item.status.index << 1;
      if (item.hasChanges) stamp |= 1 << 4;
      if (state.isLoading) stamp |= 1 << 5;
      return stamp;
    });
    final state = context.read<AppState>();
    final isSelected = identical(state.selectedFileItem, item);

    if (item.isFolder) {
      return ExpansionTile(
        key: PageStorageKey(item.path ?? item.name),
        leading: const Icon(Icons.folder_outlined, size: 17),
        title: Text(
          item.name,
          style: const TextStyle(fontSize: 11.5),
          overflow: TextOverflow.ellipsis,
        ),
        initiallyExpanded: item.isExpanded,
        onExpansionChanged: (expanded) =>
            state.setFolderExpansion(item, expanded),
        children: item.children.map((child) => FileNode(item: child)).toList(),
      );
    }

    final visualState = item.visualState;
    late final Color statusColor;
    late final Color statusSurface;
    late final String statusLabel;
    switch (visualState) {
      case FileVisualState.cleanPass:
        statusColor = const Color(0xFF79C99E);
        statusSurface = const Color(0xFF79C99E).withOpacity(0.085);
        statusLabel = 'PASS';
        break;
      case FileVisualState.editedPass:
        statusColor = const Color(0xFFE8A64B);
        statusSurface = const Color(0xFFE8A64B).withOpacity(0.11);
        statusLabel = 'EDITED';
        break;
      case FileVisualState.fail:
        statusColor = const Color(0xFFE27D7D);
        statusSurface = const Color(0xFFE27D7D).withOpacity(0.105);
        statusLabel = 'FAIL';
        break;
      case FileVisualState.unmarked:
        statusColor = const Color(0xFF788593);
        statusSurface = Colors.transparent;
        statusLabel = 'NEW';
        break;
    }

    final rowColor = isSelected
        ? Color.alphaBlend(
            WorkspaceColors.explorer.withOpacity(0.13),
            statusSurface,
          )
        : statusSurface;

    return Material(
      color: rowColor,
      child: InkWell(
        onTap: state.isLoading ? null : () => state.selectFile(item),
        child: Row(
          children: [
            Container(
              width: 3,
              height: double.infinity,
              color: isSelected ? WorkspaceColors.explorer : Colors.transparent,
            ),
            const SizedBox(width: 9),
            Icon(
              Icons.insert_drive_file_outlined,
              size: 16,
              color: isSelected
                  ? const Color(0xFFDDE8F2)
                  : const Color(0xFF718090),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.name,
                style: TextStyle(
                  fontSize: isSelected ? 13.0 : 11.25,
                  color: isSelected
                      ? const Color(0xFFF7FAFC)
                      : const Color(0xFFBFC7D0),
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Tooltip(
              message: visualState == FileVisualState.editedPass
                  ? 'PASS with YAML changes'
                  : statusLabel,
              child: Container(
                constraints: const BoxConstraints(minWidth: 38),
                margin: const EdgeInsets.only(left: 4, right: 2),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.12),
                  border: Border.all(color: statusColor.withOpacity(0.68)),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  statusLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: statusLabel == 'EDITED' ? 8.3 : 8.8,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.35,
                  ),
                ),
              ),
            ),
            _FileRowAction(
              tooltip: 'Pass',
              icon: Icons.check_rounded,
              color: const Color(0xFF79C99E),
              onTap: () => state.setFileStatus(item, FileStatus.pass),
            ),
            _FileRowAction(
              tooltip: 'Fail',
              icon: Icons.close_rounded,
              color: const Color(0xFFE27D7D),
              onTap: () => state.setFileStatus(item, FileStatus.fail),
            ),
            _FileRowAction(
              tooltip: 'Remove',
              icon: Icons.delete_outline_rounded,
              color: const Color(0xFF7D8996),
              onTap: () => state.removeFile(item),
            ),
            const SizedBox(width: 3),
          ],
        ),
      ),
    );
  }
}

class _FileRowAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _FileRowAction({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
          child: Icon(icon, size: 14, color: color),
        ),
      ),
    );
  }
}

class FeatureSelectorSidebar extends StatefulWidget {
  const FeatureSelectorSidebar({super.key});

  @override
  State<FeatureSelectorSidebar> createState() => _FeatureSelectorSidebarState();
}

class _FeatureSelectorSidebarState extends State<FeatureSelectorSidebar> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';
  CsvDataSet? _lastCsv;
  String _lastQuery = '';
  List<String> _filtered = const <String>[];

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _queueSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _query = value.trim().toLowerCase());
    });
  }

  List<String> _featuresFor(CsvDataSet csv) {
    if (!identical(csv, _lastCsv) || _lastQuery != _query) {
      _lastCsv = csv;
      _lastQuery = _query;
      _filtered = _query.isEmpty
          ? csv.headers
          : csv.headers
              .where((header) => header.toLowerCase().contains(_query))
              .toList(growable: false);
    }
    return _filtered;
  }

  @override
  Widget build(BuildContext context) {
    context.select<AppState, int>((s) => s.featureRevision);
    final state = context.read<AppState>();
    final csv = state.currentCsv;

    if (csv == null) {
      return const _SidebarEmptyState(
        icon: Icons.view_list_outlined,
        title: 'No CSV selected',
        message: 'Choose a dataset in Explorer to inspect its features.',
      );
    }

    final headers = _featuresFor(csv);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(11),
          child: Column(
            children: [
              TextField(
                controller: _searchCtrl,
                onChanged: _queueSearch,
                decoration: InputDecoration(
                  hintText: 'Search ${csv.headers.length} features',
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 17,
                    color: Color(0xFF7D8997),
                  ),
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _searchDebounce?.cancel();
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  Expanded(
                    child: _CompactActionButton(
                      icon: Icons.done_all_rounded,
                      label: 'Select all',
                      onPressed: state.selectAllFeatures,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: _CompactActionButton(
                      icon: Icons.layers_clear_outlined,
                      label: 'Clear',
                      onPressed: state.unselectAllFeatures,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${state.visibleColumns.length} visible   •   '
                  '${csv.logicalHeaders.length} logical',
                  style: const TextStyle(
                    color: Color(0xFF788593),
                    fontSize: 10.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: headers.isEmpty
              ? const _SidebarEmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'No matching features',
                  message: 'Try a different feature name.',
                )
              : ListView.builder(
                  itemCount: headers.length,
                  itemExtent: 45,
                  cacheExtent: 390,
                  itemBuilder: (context, index) {
                    final header = headers[index];
                    return _FeatureRow(
                      header: header,
                      isLogical: csv.logicalHeaders.contains(header),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final String header;
  final bool isLogical;

  const _FeatureRow({required this.header, required this.isLogical});

  @override
  Widget build(BuildContext context) {
    final checked = context.select<AppState, bool>(
      (state) => state.visibleColumns.contains(header),
    );
    return InkWell(
      onTap: () => context.read<AppState>().toggleColumnVisibility(header),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Checkbox(
                value: checked,
                onChanged: (_) =>
                    context.read<AppState>().toggleColumnVisibility(header),
                activeColor: WorkspaceColors.features,
                side: const BorderSide(color: Color(0xFF53606D)),
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                header,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.25,
                  color: checked
                      ? const Color(0xFFF0F3F6)
                      : const Color(0xFF9AA5B0),
                ),
              ),
            ),
            if (isLogical)
              const Tooltip(
                message: 'Logical 0/1 feature',
                child: Icon(
                  Icons.toggle_on_outlined,
                  size: 17,
                  color: Color(0xFFA7B0BA),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class LogicalFeatureSidebar extends StatefulWidget {
  const LogicalFeatureSidebar({super.key});

  @override
  State<LogicalFeatureSidebar> createState() =>
      _LogicalFeatureSidebarState();
}

class _LogicalFeatureSidebarState extends State<LogicalFeatureSidebar> {
  final TextEditingController _startCtrl = TextEditingController();
  final TextEditingController _endCtrl = TextEditingController();
  int _value = 1;

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  void _addEdit(AppState state) {
    final feature = state.effectiveLogicalFeature;
    final start = int.tryParse(_startCtrl.text.trim());
    final end = int.tryParse(_endCtrl.text.trim());
    if (feature == null || start == null || end == null) {
      _showMessage('Choose a feature and enter valid start/end indexes.');
      return;
    }
    final error = state.addLogicalFeatureRange(feature, start, end, _value);
    if (error != null) {
      _showMessage(error);
      return;
    }
    _startCtrl.clear();
    _endCtrl.clear();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final features = state.logicalFeatureHeaders;
    final csv = state.currentCsv;

    if (csv == null) {
      return const _SidebarEmptyState(
        icon: Icons.toggle_on_outlined,
        title: 'No CSV selected',
        message: 'Choose a dataset first. Logical features are detected automatically.',
      );
    }
    if (features.isEmpty) {
      return const _SidebarEmptyState(
        icon: Icons.toggle_off_outlined,
        title: 'No logical features found',
        message: 'A logical feature must contain only 0/1 or true/false values.',
      );
    }

    final currentFeature = state.effectiveLogicalFeature!;
    final ranges = state.logicalRangesFor(currentFeature);

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: WorkspaceColors.logic.withOpacity(0.07),
            border: Border.all(color: WorkspaceColors.logic.withOpacity(0.24)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Text(
            'Edit Boolean features by index range. Changes are previewed on the chart and saved in YAML; the original CSV bytes stay untouched.',
            style: TextStyle(fontSize: 12, height: 1.35),
          ),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          value: currentFeature,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Logical feature',
            prefixIcon: Icon(Icons.toggle_on_outlined, size: 18, color: Color(0xFF9DA8B3)),
          ),
          items: features
              .map(
                (feature) => DropdownMenuItem(
                  value: feature,
                  child: Text(feature, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) state.setPreferredLogicalFeature(value);
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _startCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Start index'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _endCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'End index'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Valid index range: 0–${max(0, csv.rowCount - 1)}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white54,
              ),
        ),
        const SizedBox(height: 12),
        const Text('Set value', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: ChoiceChip(
                label: const Text('0 / false'),
                selected: _value == 0,
                onSelected: (_) => setState(() => _value = 0),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ChoiceChip(
                label: const Text('1 / true'),
                selected: _value == 1,
                onSelected: (_) => setState(() => _value = 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => _addEdit(state),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF221A1B),
            foregroundColor: const Color(0xFFF2ECEC),
            side: BorderSide(color: WorkspaceColors.logic.withOpacity(0.58)),
          ),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add logical range'),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Saved edits',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${ranges.length}',
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (ranges.isEmpty)
          const Text(
            'No edits for this feature.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          )
        else
          ...ranges.asMap().entries.map((entry) {
            final index = entry.key;
            final range = entry.value;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.035),
                border: Border.all(color: Colors.white10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: range.value == 1
                          ? Colors.greenAccent.withOpacity(0.14)
                          : Colors.white10,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('${range.value}'),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '${range.start} → ${range.end}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove range',
                    icon: const Icon(Icons.close, size: 17),
                    onPressed: () =>
                        state.removeLogicalFeatureRange(currentFeature, index),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

class _SidebarEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _SidebarEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelSectionTitle extends StatelessWidget {
  final String label;
  final Color accent;

  const _PanelSectionTitle({required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFD7DDE3),
            fontSize: 10,
            letterSpacing: 1.0,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

// --- Data processing and validation ---
class ProcessSidebar extends StatefulWidget {
  const ProcessSidebar({super.key});

  @override
  State<ProcessSidebar> createState() => _ProcessSidebarState();
}

class _ProcessSidebarState extends State<ProcessSidebar> {
  final TextEditingController _startCtrl = TextEditingController();
  final TextEditingController _endCtrl = TextEditingController();

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  void _addRange(AppState state) {
    final start = int.tryParse(_startCtrl.text.trim());
    final end = int.tryParse(_endCtrl.text.trim());
    if (start == null || end == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter valid start and end indexes.')),
      );
      return;
    }
    final error = state.addInvalidRange(start, end);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }
    _startCtrl.clear();
    _endCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        // 1. Normalization (Kept from old layout)
        const _PanelSectionTitle(
          label: 'NORMALIZATION',
          accent: WorkspaceColors.process,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            "Normalize [-1.0, 1.0]",
            style: TextStyle(fontSize: 13),
          ),
          value: state.isNormalized,
          activeColor: WorkspaceColors.process,
          onChanged: (val) => state.setNormalization(val),
        ),
        const Divider(height: 30),

        // 2. Data Validation Tagging
        const _PanelSectionTitle(
          label: 'INVALID DATA RANGES',
          accent: WorkspaceColors.process,
        ),
        const SizedBox(height: 8),
        if (state.selectedFileItem == null)
          const Text(
            "Please select a file from the explorer to flag data.",
            style: TextStyle(color: Colors.grey, fontSize: 12),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _startCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Start Index',
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _endCtrl,
                  decoration: const InputDecoration(
                    labelText: 'End Index',
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Valid index range: 0–${max(0, state.selectedRowCount - 1)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white54,
                ),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text("Add Range"),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red[900],
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 35),
            ),
            onPressed: () => _addRange(state),
          ),
          const SizedBox(height: 16),
          const Text(
            "Current Invalid Ranges:",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          if (state.selectedFileItem!.invalidRanges.isEmpty)
            const Text(
              "None",
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            )
          else
            ...state.selectedFileItem!.invalidRanges.asMap().entries.map((
              entry,
            ) {
              int idx = entry.key;
              List<int> range = entry.value;
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "[ ${range[0]} to ${range[1]} ]",
                      style: const TextStyle(fontSize: 13),
                    ),
                    InkWell(
                      onTap: () => state.removeInvalidRange(idx),
                      child: const Icon(
                        Icons.close,
                        size: 16,
                        color: Colors.redAccent,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
        ],
      ],
    );
  }
}

class SettingsSidebar extends StatelessWidget {
  const SettingsSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final showTooltip =
        context.select<AppState, bool>((state) => state.showTooltip);
    final showMarkers =
        context.select<AppState, bool>((state) => state.showMarkers);
    final markerSize =
        context.select<AppState, double>((state) => state.markerSize);
    final state = context.read<AppState>();

    return ListView(
      padding: const EdgeInsets.all(15),
      children: [
        const _PanelSectionTitle(
          label: 'INTERACTION',
          accent: WorkspaceColors.settings,
        ),
        const SizedBox(height: 7),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Point tooltip',
            style: TextStyle(fontSize: 11.5),
          ),
          subtitle: const Text(
            'Show exact index/value information on hover.',
            style: TextStyle(fontSize: 9.5, color: Color(0xFF74818E)),
          ),
          value: showTooltip,
          activeColor: const Color(0xFFD4BF55),
          onChanged: state.setTooltipEnabled,
        ),
        const Divider(height: 24),
        const _PanelSectionTitle(
          label: 'DATA POINTS',
          accent: WorkspaceColors.settings,
        ),
        const SizedBox(height: 7),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Show point markers',
            style: TextStyle(fontSize: 11.5),
          ),
          subtitle: const Text(
            'Markers are automatically suppressed on very dense views.',
            style: TextStyle(fontSize: 9.5, color: Color(0xFF74818E)),
          ),
          value: showMarkers,
          activeColor: const Color(0xFFD4BF55),
          onChanged: state.setShowMarkers,
        ),
        if (showMarkers) ...[
          const SizedBox(height: 5),
          Row(
            children: [
              const Text(
                'Marker size',
                style: TextStyle(fontSize: 10.5, color: Color(0xFFAAB3BC)),
              ),
              const Spacer(),
              Text(
                markerSize.toStringAsFixed(0),
                style: const TextStyle(
                  fontSize: 10.5,
                  color: Color(0xFFD2D8DE),
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Slider(
            min: 2,
            max: 10,
            activeColor: const Color(0xFFD4BF55),
            value: markerSize,
            onChanged: state.setMarkerSize,
          ),
        ],
        const Divider(height: 24),
        const _PanelSectionTitle(
          label: 'RENDERING',
          accent: WorkspaceColors.settings,
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: const Color(0xFF0D1319),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: const Color(0xFF2A343F)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.speed_rounded,
                size: 17,
                color: Color(0xFF9AA6B2),
              ),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Adaptive render budget is enabled. Overview views preserve '
                  'min/max extrema; exact raw samples return automatically as '
                  'you zoom in.',
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.4,
                    color: Color(0xFF8B97A4),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// 5. CHART AREA
// -----------------------------------------------------------------------------

const List<Color> _chartPalette = <Color>[
  Color(0xFF65C7D4),
  Color(0xFFE4A15B),
  Color(0xFFB39DDB),
  Color(0xFF80C99B),
  Color(0xFFE27D7D),
  Color(0xFFD6C86E),
  Color(0xFFD990B4),
  Color(0xFF64B5A7),
  Color(0xFF8EA7C2),
  Color(0xFFC6A0D5),
  Color(0xFF9FC56E),
  Color(0xFFE6B17E),
];

class ChartArea extends StatefulWidget {
  const ChartArea({super.key});

  @override
  State<ChartArea> createState() => _ChartAreaState();
}

class _ChartAreaState extends State<ChartArea> {
  late final ZoomPanBehavior _zoomPanBehavior;
  late final TrackballBehavior _trackballBehavior;

  CsvDataSet? _lastCsv;
  int _lastDataRevision = -1;
  String _lastRenderKey = '';
  int _renderToken = 0;
  Timer? _renderDebounce;

  double _visibleStart = 0;
  double _visibleEnd = 0;
  double _pendingVisibleStart = 0;
  double _pendingVisibleEnd = 0;
  bool _viewportUpdateScheduled = false;
  double _lastChartWidth = 1000;

  bool _preparing = false;
  double _prepareProgress = 0;
  int _preparedPointCount = 0;
  Map<String, List<ChartSample>> _prepared = const {};

  // header -> block size -> min/max representation for the entire column.
  // These levels are built lazily and reused during pan/zoom.
  final Map<String, Map<int, List<ChartSample>>> _levelCache = {};
  int _cachedLevelPoints = 0;
  static const int _maxCachedLevelPoints = 650000;

  @override
  void initState() {
    super.initState();
    _zoomPanBehavior = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableSelectionZooming: true,
      enableMouseWheelZooming: true,
      enableDoubleTapZooming: true,
      zoomMode: ZoomMode.x,
      selectionRectColor: const Color(0x225F7D9B),
      selectionRectBorderColor: const Color(0xFF718DAA),
      selectionRectBorderWidth: 1,
    );
    _trackballBehavior = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      shouldAlwaysShow: true,
      lineType: TrackballLineType.vertical,
      lineColor: const Color(0xFF7E8995),
      lineWidth: 1,
      tooltipDisplayMode: TrackballDisplayMode.nearestPoint,
      tooltipSettings: const InteractiveTooltip(
        enable: true,
        format: 'Index point.x   •   point.y',
        color: Color(0xFF202832),
        borderColor: Color(0xFF3A4653),
        borderWidth: 1,
        textStyle: TextStyle(
          color: Color(0xFFF1F4F7),
          fontSize: 12,
          fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
      markerSettings: const TrackballMarkerSettings(
        markerVisibility: TrackballVisibilityMode.visible,
        height: 7,
        width: 7,
      ),
    );
  }

  @override
  void dispose() {
    _renderDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.select<AppState, int>((state) => state.chartRevision);
    final dataRevision =
        context.select<AppState, int>((state) => state.dataRevision);
    final featureRevision =
        context.select<AppState, int>((state) => state.featureRevision);
    final state = context.read<AppState>();
    final csv = state.currentCsv;

    if (csv == null) {
      return const _ChartEmptyState(
        icon: Icons.monitor_heart_outlined,
        title: 'No active dataset',
        message: 'Choose a CSV dataset from Explorer to start analysis.',
      );
    }

    if (!identical(csv, _lastCsv)) {
      _renderToken++;
      _renderDebounce?.cancel();
      _preparing = false;
      _lastCsv = csv;
      _visibleStart = 0;
      _visibleEnd = max(0, csv.rowCount - 1).toDouble();
      _prepared = const {};
      _clearLevelCache();
      _lastRenderKey = '';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _zoomPanBehavior.reset();
      });
    }

    if (dataRevision != _lastDataRevision) {
      _renderToken++;
      _renderDebounce?.cancel();
      _preparing = false;
      _prepared = const {};
      _lastDataRevision = dataRevision;
      _clearLevelCache();
      _lastRenderKey = '';
    }

    final visibleHeaders = _orderedVisibleHeaders(state, csv);
    if (visibleHeaders.isEmpty) {
      return const _ChartEmptyState(
        icon: Icons.stacked_line_chart_rounded,
        title: 'No visible features',
        message: 'Select one or more signals in the Features workspace.',
      );
    }

    final normalizedMinimum = _normalizedAxisMinimum(state, csv, visibleHeaders);
    final normalizedMaximum = _normalizedAxisMaximum(state, csv, visibleHeaders);

    return Column(
      children: [
        _ChartToolbar(
          csv: csv,
          visibleStart: _visibleStart,
          visibleEnd: _visibleEnd,
          preparing: _preparing,
          prepareProgress: _prepareProgress,
          preparedPoints: _preparedPointCount,
          featureCount: visibleHeaders.length,
          onReset: _resetView,
          onZoomIn: _zoomPanBehavior.zoomIn,
          onZoomOut: _zoomPanBehavior.zoomOut,
        ),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _lastChartWidth = max(320.0, constraints.maxWidth - 70.0);
              _schedulePreparation(
                state,
                csv,
                visibleHeaders,
                dataRevision,
                featureRevision,
                _lastChartWidth,
              );

              final invalidPlotBands =
                  state.selectedFileItem?.invalidRanges.map((range) {
                        return PlotBand(
                          isVisible: true,
                          start: range[0],
                          end: range[1],
                          color: const Color(0x22E76060),
                          borderColor: const Color(0x88E76060),
                          borderWidth: 0.7,
                        );
                      }).toList() ??
                      const <PlotBand>[];

              return Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 10, 2),
                      child: SfCartesianChart(
                        margin: EdgeInsets.zero,
                        plotAreaBackgroundColor: const Color(0xFF0B1016),
                        plotAreaBorderColor: const Color(0xFF2A333E),
                        plotAreaBorderWidth: 0.8,
                        legend: const Legend(isVisible: false),
                        zoomPanBehavior: _zoomPanBehavior,
                        trackballBehavior: _trackballBehavior,
                        onActualRangeChanged: (args) {
                          _snapSampleIndexAxis(
                            args,
                            csv.rowCount,
                            _lastChartWidth,
                          );
                        },
                        tooltipBehavior: TooltipBehavior(
                          enable: state.showTooltip,
                          color: const Color(0xFF202832),
                          borderColor: const Color(0xFF3A4653),
                          borderWidth: 1,
                          textStyle: const TextStyle(
                            color: Color(0xFFF1F4F7),
                            fontSize: 12,
                            fontFeatures: <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                          format: 'Index point.x  •  point.y',
                        ),
                        primaryXAxis: NumericAxis(
                          name: 'sampleIndexAxis',
                          title: const AxisTitle(
                            text: 'SAMPLE INDEX  •  ZERO BASED',
                            textStyle: TextStyle(
                              color: Color(0xFF697684),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                            ),
                          ),
                          minimum: 0,
                          maximum: csv.rowCount > 1
                              ? (csv.rowCount - 1).toDouble()
                              : 1.0,
                          rangePadding: ChartRangePadding.none,
                          decimalPlaces: 0,
                          enableAutoIntervalOnZooming: true,
                          // Syncfusion's maximumLabels is per 100 logical px.
                          // Keep it above our width-derived density so it never
                          // becomes a second, hidden limiter on the index grid.
                          maximumLabels: 10,
                          labelIntersectAction: AxisLabelIntersectAction.hide,
                          axisLine: const AxisLine(
                            color: Color(0xFF39434E),
                            width: 0.8,
                          ),
                          majorTickLines: const MajorTickLines(
                            color: Color(0xFF4B5663),
                            size: 4,
                            width: 0.8,
                          ),
                          majorGridLines: const MajorGridLines(
                            width: 0.55,
                            color: Color(0xFF252D36),
                          ),
                          labelStyle: const TextStyle(
                            color: Color(0xFF96A1AD),
                            fontSize: 11.5,
                            fontFeatures: <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                          plotBands: invalidPlotBands,
                          axisLabelFormatter: (details) {
                            final raw = details.value.toDouble();
                            final nearest = raw.round();
                            if ((raw - nearest).abs() > 0.000001) {
                              // Expose, never disguise, an unexpected fractional
                              // coordinate. Under the snapped range policy this
                              // path should not be reached.
                              return ChartAxisLabel(
                                raw.toStringAsFixed(3),
                                details.textStyle.copyWith(
                                  color: const Color(0xFFE2A45D),
                                ),
                              );
                            }
                            return ChartAxisLabel(
                              _formatIndex(nearest),
                              details.textStyle,
                            );
                          },
                        ),
                        primaryYAxis: NumericAxis(
                          title: AxisTitle(
                            text: state.isNormalized ? 'NORMALIZED' : 'RAW VALUE',
                            textStyle: const TextStyle(
                              color: Color(0xFF697684),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.0,
                            ),
                          ),
                          majorGridLines: const MajorGridLines(
                            width: 0.45,
                            color: Color(0xFF202832),
                          ),
                          axisLine: const AxisLine(
                            color: Color(0xFF39434E),
                            width: 0.8,
                          ),
                          labelStyle: const TextStyle(
                            color: Color(0xFF87939F),
                            fontSize: 11,
                            fontFeatures: <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                          minimum: normalizedMinimum,
                          maximum: normalizedMaximum,
                        ),
                        series: _buildFastSeries(
                          state,
                          csv,
                          visibleHeaders,
                        ),
                      ),
                    ),
                  ),
                  if (_preparing)
                    Positioned(
                      right: 18,
                      top: 15,
                      child: _RenderProgressBadge(progress: _prepareProgress),
                    ),
                ],
              );
            },
          ),
        ),
        const Divider(height: 1),
        const _ChartLegendStrip(),
      ],
    );
  }

  List<String> _orderedVisibleHeaders(AppState state, CsvDataSet csv) {
    final visible = state.visibleColumns;
    return csv.headers
        .where((header) => visible.contains(header))
        .toList(growable: false);
  }

  void _resetView() {
    final csv = _lastCsv;
    if (csv == null) return;
    _zoomPanBehavior.reset();
    setState(() {
      _visibleStart = 0;
      _visibleEnd = max(0, csv.rowCount - 1).toDouble();
      _lastRenderKey = '';
    });
  }

  void _schedulePreparation(
    AppState state,
    CsvDataSet csv,
    List<String> headers,
    int dataRevision,
    int featureRevision,
    double width,
  ) {
    final start = _visibleStart.floor().clamp(0, max(0, csv.rowCount - 1)).toInt();
    final end = _visibleEnd.ceil().clamp(0, max(0, csv.rowCount - 1)).toInt();
    final key = '${identityHashCode(csv)}|$dataRevision|$featureRevision|'
        '$start|$end|${width.round()}|${headers.length}';
    if (key == _lastRenderKey) return;
    _lastRenderKey = key;
    _renderDebounce?.cancel();
    final token = ++_renderToken;
    _renderDebounce = Timer(const Duration(milliseconds: 45), () {
      _prepareSeries(
        state,
        csv,
        headers,
        start,
        end,
        width,
        token,
      );
    });
  }

  Future<void> _prepareSeries(
    AppState state,
    CsvDataSet csv,
    List<String> headers,
    int start,
    int end,
    double width,
    int token,
  ) async {
    if (headers.isEmpty || csv.rowCount == 0) return;
    if (mounted) {
      setState(() {
        _preparing = true;
        _prepareProgress = 0;
      });
    }

    final safeStart = start.clamp(0, csv.rowCount - 1).toInt();
    final safeEnd = end.clamp(safeStart, csv.rowCount - 1).toInt();
    final screenBudget = max(320, (width * 2.2).round());
    const totalPointBudget = 120000;
    final perSeriesBudget = max(
      96,
      min(screenBudget, totalPointBudget ~/ max(1, headers.length)),
    );

    final next = <String, List<ChartSample>>{};
    var totalPoints = 0;
    for (var i = 0; i < headers.length; i++) {
      if (token != _renderToken) return;
      final header = headers[i];
      final raw = csv.data[header];
      if (raw == null || raw.isEmpty) continue;
      final logicalRanges = state.logicalRangesFor(header);
      final samples = await _samplesForViewport(
        header,
        raw,
        logicalRanges,
        safeStart,
        safeEnd,
        perSeriesBudget,
        token,
      );
      if (token != _renderToken) return;
      next[header] = samples;
      totalPoints += samples.length;

      if (mounted && (i % 2 == 1 || i == headers.length - 1)) {
        setState(() {
          _prepareProgress = (i + 1) / headers.length;
        });
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (!mounted || token != _renderToken) return;
    setState(() {
      _prepared = next;
      _preparedPointCount = totalPoints;
      _prepareProgress = 1;
      _preparing = false;
    });
  }

  Future<List<ChartSample>> _samplesForViewport(
    String header,
    Float64List raw,
    List<LogicalFeatureRange> logicalRanges,
    int start,
    int end,
    int pointBudget,
    int token,
  ) async {
    final visibleCount = end - start + 1;
    if (visibleCount <= pointBudget) {
      final out = <ChartSample>[];
      final cursor = _LogicalValueCursor(logicalRanges);
      for (var x = start; x <= end; x++) {
        out.add(ChartSample(x, cursor.valueAt(raw, x)));
      }
      return out;
    }

    // Min/max needs up to two points per bucket. A power-of-two block gives a
    // reusable multiresolution pyramid during subsequent pan/zoom operations.
    final requiredBlock =
        max(2, (visibleCount / max(1, pointBudget ~/ 2)).ceil());
    final blockSize = _nextPowerOfTwo(requiredBlock);
    final estimatedFullLevelPoints =
        2 * ((raw.length + blockSize - 1) ~/ blockSize);

    final List<ChartSample> out;
    if (estimatedFullLevelPoints <= 50000) {
      final level = await _levelFor(
        header,
        raw,
        logicalRanges,
        blockSize,
        token,
      );
      if (token != _renderToken) return const <ChartSample>[];
      out = <ChartSample>[];
      for (final sample in level) {
        if (sample.x < start) continue;
        if (sample.x > end) break;
        out.add(sample);
      }
    } else {
      // A fine-grained level for an enormous column would itself be enormous.
      // Compute only the current viewport in that case instead of polluting the
      // cache with hundreds of thousands of render objects.
      out = await _rangeLevel(
        raw,
        logicalRanges,
        start,
        end,
        blockSize,
        token,
      );
    }

    // Keep viewport edges represented by exact original samples.
    if (out.isEmpty || out.first.x != start) {
      out.insert(
        0,
        ChartSample(start, _effectiveValue(raw, logicalRanges, start)),
      );
    }
    if (out.last.x != end) {
      out.add(ChartSample(end, _effectiveValue(raw, logicalRanges, end)));
    }
    return out;
  }

  double _effectiveValue(
    Float64List raw,
    List<LogicalFeatureRange> ranges,
    int index,
  ) {
    // Range counts are normally tiny, so a direct lookup is ideal for the two
    // viewport edge samples. Sequential scans use _LogicalValueCursor instead.
    for (final range in ranges) {
      if (index < range.start) break;
      if (index <= range.end) return range.value.toDouble();
    }
    return raw[index];
  }

  Future<List<ChartSample>> _rangeLevel(
    Float64List raw,
    List<LogicalFeatureRange> logicalRanges,
    int start,
    int end,
    int blockSize,
    int token,
  ) async {
    final out = <ChartSample>[];
    final cursor = _LogicalValueCursor(logicalRanges);
    var processedSinceYield = 0;
    final alignedStart = (start ~/ blockSize) * blockSize;
    for (var blockStart = alignedStart;
        blockStart <= end;
        blockStart += blockSize) {
      if (token != _renderToken) return const <ChartSample>[];
      final localStart = max(start, blockStart);
      final localEnd = min(end + 1, blockStart + blockSize);
      if (localStart >= localEnd) continue;

      var minValue = cursor.valueAt(raw, localStart);
      var maxValue = minValue;
      var minIndex = localStart;
      var maxIndex = localStart;
      for (var i = localStart + 1; i < localEnd; i++) {
        final value = cursor.valueAt(raw, i);
        if (value < minValue) {
          minValue = value;
          minIndex = i;
        }
        if (value > maxValue) {
          maxValue = value;
          maxIndex = i;
        }
      }
      if (minIndex == maxIndex) {
        out.add(ChartSample(minIndex, minValue));
      } else if (minIndex < maxIndex) {
        out
          ..add(ChartSample(minIndex, minValue))
          ..add(ChartSample(maxIndex, maxValue));
      } else {
        out
          ..add(ChartSample(maxIndex, maxValue))
          ..add(ChartSample(minIndex, minValue));
      }

      processedSinceYield += localEnd - localStart;
      if (processedSinceYield >= 180000) {
        processedSinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    return out;
  }

  Future<List<ChartSample>> _levelFor(
    String header,
    Float64List raw,
    List<LogicalFeatureRange> logicalRanges,
    int blockSize,
    int token,
  ) async {
    final headerCache =
        _levelCache.putIfAbsent(header, () => <int, List<ChartSample>>{});
    final cached = headerCache[blockSize];
    if (cached != null) {
      // Refresh this level within the per-header insertion order.
      headerCache.remove(blockSize);
      headerCache[blockSize] = cached;
      return cached;
    }

    final out = <ChartSample>[];
    final cursor = _LogicalValueCursor(logicalRanges);
    var processedSinceYield = 0;
    for (var blockStart = 0;
        blockStart < raw.length;
        blockStart += blockSize) {
      if (token != _renderToken) return const <ChartSample>[];
      final blockEnd = min(raw.length, blockStart + blockSize);
      var minValue = cursor.valueAt(raw, blockStart);
      var maxValue = minValue;
      var minIndex = blockStart;
      var maxIndex = blockStart;
      for (var i = blockStart + 1; i < blockEnd; i++) {
        final value = cursor.valueAt(raw, i);
        if (value < minValue) {
          minValue = value;
          minIndex = i;
        }
        if (value > maxValue) {
          maxValue = value;
          maxIndex = i;
        }
      }

      if (minIndex == maxIndex) {
        out.add(ChartSample(minIndex, minValue));
      } else if (minIndex < maxIndex) {
        out
          ..add(ChartSample(minIndex, minValue))
          ..add(ChartSample(maxIndex, maxValue));
      } else {
        out
          ..add(ChartSample(maxIndex, maxValue))
          ..add(ChartSample(minIndex, minValue));
      }

      processedSinceYield += blockEnd - blockStart;
      if (processedSinceYield >= 180000) {
        processedSinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (token == _renderToken) {
      final immutable = List<ChartSample>.unmodifiable(out);
      headerCache[blockSize] = immutable;
      _cachedLevelPoints += immutable.length;
      while (headerCache.length > 4) {
        final oldestKey = headerCache.keys.first;
        final removed = headerCache.remove(oldestKey);
        _cachedLevelPoints -= removed?.length ?? 0;
      }
      _enforceGlobalLevelCacheBudget();
    }
    return out;
  }

  void _clearLevelCache() {
    _levelCache.clear();
    _cachedLevelPoints = 0;
  }

  void _enforceGlobalLevelCacheBudget() {
    while (_cachedLevelPoints > _maxCachedLevelPoints &&
        _levelCache.isNotEmpty) {
      final header = _levelCache.keys.first;
      final levels = _levelCache[header]!;
      if (levels.isEmpty) {
        _levelCache.remove(header);
        continue;
      }
      final levelKey = levels.keys.first;
      final removed = levels.remove(levelKey);
      _cachedLevelPoints -= removed?.length ?? 0;
      if (levels.isEmpty) _levelCache.remove(header);
    }
  }

  int _nextPowerOfTwo(int value) {
    var power = 1;
    while (power < value) power <<= 1;
    return power;
  }

  double? _normalizedAxisMinimum(
    AppState state,
    CsvDataSet csv,
    List<String> visibleHeaders,
  ) {
    if (!state.isNormalized) return null;
    final hasNegative = visibleHeaders.any((header) => csv.minimumFor(header) < 0);
    return hasNegative ? -1.1 : 0.0;
  }

  double? _normalizedAxisMaximum(
    AppState state,
    CsvDataSet csv,
    List<String> visibleHeaders,
  ) {
    if (!state.isNormalized) return null;
    final hasPositive = visibleHeaders.any((header) => csv.maximumFor(header) > 0);
    final hasNegative = visibleHeaders.any((header) => csv.minimumFor(header) < 0);
    if (hasPositive) return 1.1;
    if (hasNegative) return 0.0;
    // All visible values are zero: keep a useful non-degenerate positive axis.
    return 1.0;
  }

  List<CartesianSeries<ChartSample, int>> _buildFastSeries(
    AppState state,
    CsvDataSet csv,
    List<String> visibleHeaders,
  ) {
    final series = <CartesianSeries<ChartSample, int>>[];
    for (var i = 0; i < visibleHeaders.length; i++) {
      final header = visibleHeaders[i];
      final samples = _prepared[header];
      if (samples == null || samples.isEmpty) continue;
      final scale = csv.normalizationScaleFor(header);
      series.add(
        FastLineSeries<ChartSample, int>(
          name: header,
          dataSource: samples,
          xValueMapper: (sample, _) => sample.x,
          yValueMapper: (sample, _) =>
              state.isNormalized ? sample.y / scale : sample.y,
          color: _chartPalette[i % _chartPalette.length],
          width: 1.25,
          animationDuration: 0,
          enableTooltip: state.showTooltip,
          markerSettings: MarkerSettings(
            isVisible: state.showMarkers &&
                visibleHeaders.length <= 8 &&
                samples.length <= 2500,
            width: state.markerSize,
            height: state.markerSize,
          ),
        ),
      );
    }
    return series;
  }

  void _snapSampleIndexAxis(
    ActualRangeChangedArgs args,
    int rowCount,
    double chartWidth,
  ) {
    if (args.axisName != 'sampleIndexAxis' || rowCount <= 0) return;
    if (rowCount == 1) {
      args.visibleMin = 0.0;
      args.visibleMax = 1.0;
      args.visibleInterval = 1.0;
      _scheduleViewportUpdate(0, 0);
      return;
    }

    final currentMin = (args.visibleMin as num?)?.toDouble();
    final currentMax = (args.visibleMax as num?)?.toDouble();
    if (currentMin == null ||
        currentMax == null ||
        !currentMin.isFinite ||
        !currentMax.isFinite) {
      return;
    }

    final last = (rowCount - 1).toDouble();
    var minSample = currentMin.floorToDouble().clamp(0.0, last).toDouble();
    var maxSample = currentMax.ceilToDouble().clamp(0.0, last).toDouble();
    if (maxSample <= minSample) {
      maxSample = min(last, minSample + 1.0);
      if (maxSample <= minSample) minSample = max(0.0, maxSample - 1.0);
    }

    final span = max(1.0, maxSample - minSample);
    final interval = _densestSafeIntegerInterval(
      span,
      chartWidth,
      minSample.round(),
      maxSample.round(),
    );
    args.visibleMin = minSample;
    args.visibleMax = maxSample;
    args.visibleInterval = interval.toDouble();
    _scheduleViewportUpdate(minSample, maxSample);
  }

  int _densestSafeIntegerInterval(
    double visibleSpan,
    double chartWidth,
    int minIndex,
    int maxIndex,
  ) {
    if (visibleSpan <= 1) return 1;
    final maxCharacters = max(
      _formatIndex(minIndex).length,
      _formatIndex(maxIndex).length,
    );
    // Conservative width estimate for the larger V4.1 tabular labels
    // (including comma separators) plus a small breathing gap. Unlike a fixed desired-label
    // count, this directly uses the physical viewport and therefore always
    // chooses the smallest safe integer interval for the current zoom level.
    final labelFootprint = max(34.0, maxCharacters * 8.25 + 15.0);
    final maxLabels = max(2, (chartWidth / labelFootprint).floor());
    return max(1, (visibleSpan / max(1, maxLabels - 1)).ceil());
  }

  void _scheduleViewportUpdate(double start, double end) {
    _pendingVisibleStart = start;
    _pendingVisibleEnd = end;
    if (_viewportUpdateScheduled) return;
    _viewportUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportUpdateScheduled = false;
      if (!mounted) return;
      if ((_visibleStart - _pendingVisibleStart).abs() < 0.01 &&
          (_visibleEnd - _pendingVisibleEnd).abs() < 0.01) {
        return;
      }
      setState(() {
        _visibleStart = _pendingVisibleStart;
        _visibleEnd = _pendingVisibleEnd;
        _lastRenderKey = '';
      });
    });
  }

  static String _formatIndex(int value) {
    final text = value.toString();
    final out = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) out.write(',');
      out.write(text[i]);
    }
    return out.toString();
  }
}

class _ChartToolbar extends StatelessWidget {
  final CsvDataSet csv;
  final double visibleStart;
  final double visibleEnd;
  final bool preparing;
  final double prepareProgress;
  final int preparedPoints;
  final int featureCount;
  final VoidCallback onReset;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  const _ChartToolbar({
    required this.csv,
    required this.visibleStart,
    required this.visibleEnd,
    required this.preparing,
    required this.prepareProgress,
    required this.preparedPoints,
    required this.featureCount,
    required this.onReset,
    required this.onZoomIn,
    required this.onZoomOut,
  });

  @override
  Widget build(BuildContext context) {
    final start = visibleStart.round().clamp(0, max(0, csv.rowCount - 1)).toInt();
    final end = visibleEnd.round().clamp(0, max(0, csv.rowCount - 1)).toInt();
    final visibleCount = max(0, end - start + 1);
    final zoom = csv.rowCount <= 0
        ? 1.0
        : max(1.0, csv.rowCount / max(1, visibleCount));

    return Container(
      height: 49,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: const Color(0xFF10161D),
      child: Row(
        children: [
          const Icon(
            Icons.query_stats_rounded,
            size: 17,
            color: Color(0xFF9BA7B4),
          ),
          const SizedBox(width: 8),
          const Text(
            'ANALYSIS VIEW',
            style: TextStyle(
              color: Color(0xFFDDE3E9),
              fontSize: 10,
              letterSpacing: 1.15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 16),
          _ToolbarDivider(),
          const SizedBox(width: 10),
          _ChartToolButton(
            tooltip: 'Reset / fit full dataset',
            icon: Icons.fit_screen_rounded,
            onPressed: onReset,
          ),
          _ChartToolButton(
            tooltip: 'Zoom in',
            icon: Icons.zoom_in_rounded,
            onPressed: onZoomIn,
          ),
          _ChartToolButton(
            tooltip: 'Zoom out',
            icon: Icons.zoom_out_rounded,
            onPressed: onZoomOut,
          ),
          const SizedBox(width: 10),
          _ToolbarDivider(),
          const SizedBox(width: 12),
          _MetricReadout(
            label: 'RANGE',
            value: '${_ChartAreaState._formatIndex(start)} – '
                '${_ChartAreaState._formatIndex(end)}',
          ),
          const SizedBox(width: 18),
          _MetricReadout(
            label: 'ZOOM',
            value: '${zoom.toStringAsFixed(1)}×',
          ),
          const Spacer(),
          _MetricReadout(
            label: 'RENDER',
            value: preparing
                ? '${(prepareProgress * 100).round()}%'
                : '${_formatCompact(preparedPoints)} pts',
          ),
          const SizedBox(width: 18),
          _MetricReadout(label: 'SERIES', value: '$featureCount'),
        ],
      ),
    );
  }

  static String _formatCompact(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return value.toString();
  }
}

class _ToolbarDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 22, color: const Color(0xFF2B343F));
}

class _ChartToolButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const _ChartToolButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        color: const Color(0xFFA9B4C0),
        hoverColor: const Color(0xFF202A35),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _MetricReadout extends StatelessWidget {
  final String label;
  final String value;

  const _MetricReadout({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF65717E),
            fontSize: 8.5,
            letterSpacing: 1.0,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          value,
          style: const TextStyle(
            color: Color(0xFFCDD5DD),
            fontSize: 10.5,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _RenderProgressBadge extends StatelessWidget {
  final double progress;
  const _RenderProgressBadge({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xE61A222C),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF394552)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 1.4),
          ),
          const SizedBox(width: 7),
          Text(
            'Optimizing viewport ${(progress * 100).round()}%',
            style: const TextStyle(
              color: Color(0xFFB9C2CB),
              fontSize: 9.5,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartLegendStrip extends StatelessWidget {
  const _ChartLegendStrip();

  @override
  Widget build(BuildContext context) {
    context.select<AppState, int>((s) => s.featureRevision);
    final expanded = context.select<AppState, bool>((s) => s.isLegendExpanded);
    final state = context.read<AppState>();
    final csv = state.currentCsv;
    if (csv == null) return const SizedBox();
    final headers = csv.headers
        .where((header) => state.visibleColumns.contains(header))
        .toList(growable: false);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: expanded ? 70 : 34,
      color: const Color(0xFF10161D),
      child: Column(
        children: [
          SizedBox(
            height: 34,
            child: InkWell(
              onTap: state.toggleLegend,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const Text(
                      'VISIBLE SERIES',
                      style: TextStyle(
                        color: Color(0xFF7B8794),
                        fontSize: 9,
                        letterSpacing: 1.05,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${headers.length}',
                      style: const TextStyle(
                        color: Color(0xFFB9C1CA),
                        fontSize: 10,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_up_rounded,
                      size: 17,
                      color: const Color(0xFF7E8995),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 7),
                itemCount: headers.length,
                itemBuilder: (context, index) {
                  final header = headers[index];
                  return Container(
                    width: 156,
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141C24),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF29333E)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 12,
                          height: 2,
                          color: _chartPalette[index % _chartPalette.length],
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            header,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFB7C0C9),
                              fontSize: 9.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ChartEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _ChartEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 360,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xAA111820),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF252F3A)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: const Color(0xFF647280)),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFFD7DDE3),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF7D8995),
                fontSize: 10.5,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

