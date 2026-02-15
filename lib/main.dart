import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
// Conditional import for web downloading
import 'dart:html' as html;

import 'package:archive/archive.dart';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

// -----------------------------------------------------------------------------
// 1. DATA MODELS
// -----------------------------------------------------------------------------

enum FileStatus { unmarked, pass, fail }

class FileSystemItem {
  String name;
  bool isFolder;
  List<FileSystemItem> children;
  Uint8List? content;
  String? path;
  bool isExpanded;

  // 1. Tag Logic: Status field
  FileStatus status;

  FileSystemItem({
    required this.name,
    this.isFolder = false,
    this.children = const [],
    this.content,
    this.path,
    this.isExpanded = false,
    this.status = FileStatus.unmarked,
  });
}

class CsvDataSet {
  String fileName;
  List<String> headers;
  Map<String, List<double>> data;

  CsvDataSet(this.fileName, this.headers, this.data);
}

// -----------------------------------------------------------------------------
// 2. APP STATE (PROVIDER)
// -----------------------------------------------------------------------------

class AppState extends ChangeNotifier {
  SharedPreferences? _prefs;
  bool _isLoading = false;

  // Navigation
  int _selectedIndex = 0;

  // File System
  List<FileSystemItem> _rootItems = [];
  FileSystemItem? _selectedFileItem;

  // Data
  CsvDataSet? _currentCsv;

  // Features
  Set<String> _visibleColumns = {};

  // Settings
  bool _isNormalized = false;
  bool _showTooltip = true;
  bool _showMarkers = false;
  double _markerSize = 4.0;
  double _plotHeight = 600.0;
  bool _isLegendExpanded = true;

  // Getters
  bool get isLoading => _isLoading;
  int get selectedIndex => _selectedIndex;
  List<FileSystemItem> get rootItems => _rootItems;
  FileSystemItem? get selectedFileItem => _selectedFileItem;
  CsvDataSet? get currentCsv => _currentCsv;
  Set<String> get visibleColumns => _visibleColumns;
  bool get isNormalized => _isNormalized;
  bool get showTooltip => _showTooltip;
  bool get showMarkers => _showMarkers;
  double get markerSize => _markerSize;
  double get plotHeight => _plotHeight;
  bool get isLegendExpanded => _isLegendExpanded;

  AppState() {
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    _isNormalized = _prefs?.getBool('is_normalized') ?? false;
    notifyListeners();
  }

  // --- ACTIONS ---

  void setNavIndex(int index) {
    _selectedIndex = index;
    notifyListeners();
  }

  void toggleLegend() {
    _isLegendExpanded = !_isLegendExpanded;
    notifyListeners();
  }

  void setFolderExpansion(FileSystemItem item, bool expanded) {
    item.isExpanded = expanded;
  }

  // --- TAGGING LOGIC (New) ---

  void setFileStatus(FileSystemItem item, FileStatus status) {
    item.status = status;
    notifyListeners();
  }

  // 2. Download Tag Info (YAML)
  void downloadTagInfo() {
    StringBuffer yamlContent = StringBuffer();

    // Recursive function to collect all files
    void traverse(List<FileSystemItem> items) {
      for (var item in items) {
        if (!item.isFolder) {
          String statusStr = "UNMARKED";
          if (item.status == FileStatus.pass) statusStr = "PASS";
          if (item.status == FileStatus.fail) statusStr = "FAIL";

          yamlContent.writeln("${item.name}: $statusStr");
        }
        if (item.children.isNotEmpty) {
          traverse(item.children);
        }
      }
    }

    traverse(_rootItems);

    // Trigger Browser Download
    final bytes = utf8.encode(yamlContent.toString());
    final blob = html.Blob([bytes]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute("download", "tag_info.yaml")
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  // 3. Upload Tag Info (Sync)
  Future<void> uploadTagInfo() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['yaml', 'yml', 'txt'],
        withData: true,
      );

      if (result != null && result.files.isNotEmpty) {
        String content = utf8.decode(result.files.first.bytes!);
        _syncTags(content);
      }
    } catch (e) {
      debugPrint("Error uploading tags: $e");
    }
  }

  void _syncTags(String yamlContent) {
    // Simple Line Parser for YAML (name: status)
    Map<String, FileStatus> tagMap = {};

    LineSplitter.split(yamlContent).forEach((line) {
      if (line.contains(":")) {
        var parts = line.split(":");
        String key = parts[0].trim();
        String val = parts.sublist(1).join(":").trim().toUpperCase();

        if (val == "PASS")
          tagMap[key] = FileStatus.pass;
        else if (val == "FAIL")
          tagMap[key] = FileStatus.fail;
        else
          tagMap[key] = FileStatus.unmarked;
      }
    });

    // Recursive update
    void updateItems(List<FileSystemItem> items) {
      for (var item in items) {
        if (!item.isFolder && tagMap.containsKey(item.name)) {
          item.status = tagMap[item.name]!;
        }
        if (item.children.isNotEmpty) {
          updateItems(item.children);
        }
      }
    }

    updateItems(_rootItems);
    notifyListeners();
  }

  // --- FILE MANAGEMENT ---

  Future<void> uploadFiles() async {
    _isLoading = true;
    notifyListeners();

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['csv', 'zip'],
        withData: true,
      );

      if (result != null) {
        for (var file in result.files) {
          if (file.extension == 'zip') {
            await _handleZip(file.bytes!, file.name);
          } else if (file.extension == 'csv') {
            _addFileToRoot(file.name, file.bytes!);
          }
        }
      }
    } catch (e) {
      debugPrint("Error uploading file: $e");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _handleZip(Uint8List bytes, String zipName) async {
    final archive = ZipDecoder().decodeBytes(bytes);

    FileSystemItem zipRoot = FileSystemItem(
      name: zipName,
      isFolder: true,
      children: [],
      isExpanded: true,
    );

    for (final file in archive) {
      if (file.isFile && file.name.endsWith(".csv")) {
        final content = file.content as List<int>;
        zipRoot.children.add(
          FileSystemItem(
            name: file.name,
            isFolder: false,
            content: Uint8List.fromList(content),
            path: "$zipName/${file.name}",
          ),
        );
      }
    }
    _rootItems.add(zipRoot);
  }

  void _addFileToRoot(String name, Uint8List bytes) {
    _rootItems.add(
      FileSystemItem(name: name, isFolder: false, content: bytes, path: name),
    );
  }

  void clearAllFiles() {
    _rootItems.clear();
    _currentCsv = null;
    _selectedFileItem = null;
    _visibleColumns.clear();
    notifyListeners();
  }

  void removeFile(FileSystemItem itemToRemove) {
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
    }
    notifyListeners();
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

  // --- SELECTION & PARSING ---

  Future<void> selectFile(FileSystemItem item) async {
    if (item.isFolder || item.content == null) return;

    _isLoading = true;
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 50));

    try {
      _selectedFileItem = item;

      String csvString = utf8.decode(item.content!);
      List<List<dynamic>> rows = const CsvToListConverter(
        eol: '\n',
      ).convert(csvString);

      if (rows.isNotEmpty) {
        List<String> headers = rows.first
            .map((e) => e.toString().trim())
            .toList();
        Map<String, List<double>> parsedData = {};

        for (var h in headers) parsedData[h] = [];

        for (int i = 1; i < rows.length; i++) {
          var row = rows[i];
          for (int j = 0; j < headers.length; j++) {
            if (j < row.length) {
              var val = double.tryParse(row[j].toString()) ?? 0.0;
              parsedData[headers[j]]?.add(val);
            }
          }
        }

        _currentCsv = CsvDataSet(item.name, headers, parsedData);

        Set<String> savedSelection = await _loadSelectionFromPrefs();
        Set<String> candidateSelection = _visibleColumns.isNotEmpty
            ? _visibleColumns
            : savedSelection;

        Set<String> validSelection = {};
        for (String col in candidateSelection) {
          if (headers.contains(col)) {
            validSelection.add(col);
          }
        }

        _visibleColumns = validSelection;
        _saveSelectionToPrefs();
      }
    } catch (e) {
      debugPrint("Error parsing: $e");
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void toggleColumnVisibility(String header) {
    if (_visibleColumns.contains(header)) {
      _visibleColumns.remove(header);
    } else {
      _visibleColumns.add(header);
    }
    _saveSelectionToPrefs();
    notifyListeners();
  }

  void selectAllFeatures() {
    if (_currentCsv != null) {
      _visibleColumns = Set.from(_currentCsv!.headers);
      _saveSelectionToPrefs();
      notifyListeners();
    }
  }

  void unselectAllFeatures() {
    _visibleColumns.clear();
    _saveSelectionToPrefs();
    notifyListeners();
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
    notifyListeners();
  }

  void setTooltipEnabled(bool value) {
    _showTooltip = value;
    notifyListeners();
  }

  void setShowMarkers(bool value) {
    _showMarkers = value;
    notifyListeners();
  }

  void setMarkerSize(double value) {
    _markerSize = value;
    notifyListeners();
  }

  void setPlotHeight(double h) {
    _plotHeight = h;
    notifyListeners();
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter CSV Analyzer',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
        cardColor: const Color(0xFF252526),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2D2D2D),
          elevation: 0,
        ),
      ),
      home: const MainLayout(),
    );
  }
}

class MainLayout extends StatelessWidget {
  const MainLayout({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          state.currentCsv?.fileName ??
              "Flutter CSV Analyzer (No File Selected)",
          style: const TextStyle(fontSize: 14),
        ),
      ),
      body: Row(
        children: [
          NavigationRail(
            backgroundColor: const Color(0xFF333333),
            selectedIndex: state.selectedIndex,
            onDestinationSelected: state.setNavIndex,
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.folder_open),
                label: Text('Explorer'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.checklist),
                label: Text('Features'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.analytics),
                label: Text('Process'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
            ],
          ),

          Container(
            width: 300,
            color: const Color(0xFF252526),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  color: const Color(0xFF333333),
                  width: double.infinity,
                  child: Text(
                    _getSidebarTitle(state.selectedIndex),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                Expanded(child: _buildSidebarContent(context, state)),
              ],
            ),
          ),

          Expanded(
            child: Container(
              color: const Color(0xFF1E1E1E),
              child: const ChartArea(),
            ),
          ),
        ],
      ),
    );
  }

  String _getSidebarTitle(int index) {
    switch (index) {
      case 0:
        return "EXPLORER";
      case 1:
        return "VISIBLE FEATURES";
      case 2:
        return "NORMALIZATION";
      case 3:
        return "SETTINGS";
      default:
        return "";
    }
  }

  Widget _buildSidebarContent(BuildContext context, AppState state) {
    switch (state.selectedIndex) {
      case 0:
        return const ExplorerSidebar();
      case 1:
        return const FeatureSelectorSidebar();
      case 2:
        return const NormalizationSidebar();
      case 3:
        return const SettingsSidebar();
      default:
        return const SizedBox();
    }
  }
}

// -----------------------------------------------------------------------------
// 4. SIDEBAR CONTENTS
// -----------------------------------------------------------------------------

class ExplorerSidebar extends StatelessWidget {
  const ExplorerSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              // 3. Upload Tag Info Button
              OutlinedButton.icon(
                icon: const Icon(Icons.upload, size: 18),
                label: const Text("Upload Tag Info"),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 35),
                  foregroundColor: Colors.orangeAccent,
                  side: const BorderSide(color: Colors.orangeAccent),
                ),
                onPressed: state.isLoading ? null : () => state.uploadTagInfo(),
              ),
              const SizedBox(height: 8),

              // 2. Download Tag Info Button
              OutlinedButton.icon(
                icon: const Icon(Icons.download, size: 18),
                label: const Text("Download Tag Info"),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 35),
                  foregroundColor: Colors.greenAccent,
                  side: const BorderSide(color: Colors.greenAccent),
                ),
                onPressed: state.isLoading
                    ? null
                    : () => state.downloadTagInfo(),
              ),
              const SizedBox(height: 16),

              ElevatedButton.icon(
                icon: const Icon(Icons.upload_file),
                label: const Text("Upload Files/Zip"),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 40),
                  backgroundColor: Colors.blue[700],
                  foregroundColor: Colors.white,
                ),
                onPressed: state.isLoading ? null : () => state.uploadFiles(),
              ),
              const SizedBox(height: 8),

              if (state.rootItems.isNotEmpty)
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_sweep, size: 18),
                  label: const Text("Clear All Files"),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 35),
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                  ),
                  onPressed: state.isLoading
                      ? null
                      : () => state.clearAllFiles(),
                ),
            ],
          ),
        ),
        const Divider(color: Colors.grey),

        if (state.isLoading)
          const Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text("Processing...", style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: state.rootItems.isEmpty
                ? const Center(
                    child: Text(
                      "No files uploaded",
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: state.rootItems.length,
                    itemBuilder: (ctx, i) => FileNode(item: state.rootItems[i]),
                  ),
          ),
      ],
    );
  }
}

class FileNode extends StatefulWidget {
  final FileSystemItem item;
  const FileNode({super.key, required this.item});

  @override
  State<FileNode> createState() => _FileNodeState();
}

class _FileNodeState extends State<FileNode> {
  // 4. Auto-Scroll Logic: Hook into the build process
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _checkScroll();
  }

  @override
  void didUpdateWidget(FileNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    _checkScroll();
  }

  void _checkScroll() {
    final state = context.read<AppState>();
    if (state.selectedFileItem == widget.item) {
      // If this file is selected, try to scroll to it
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5, // Center in list
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final item = widget.item;
    bool isSelected = state.selectedFileItem == item;

    // 1. Tag Logic: Determine Text Color
    Color textColor = Colors.white70;
    if (isSelected) textColor = Colors.white;
    if (item.status == FileStatus.pass) textColor = Colors.greenAccent;
    if (item.status == FileStatus.fail) textColor = Colors.redAccent;

    if (item.isFolder) {
      return ExpansionTile(
        key: PageStorageKey(item.name),
        leading: const Icon(Icons.folder, size: 18, color: Colors.orange),
        title: Text(
          item.name,
          style: TextStyle(fontSize: 13, color: textColor),
          overflow: TextOverflow.ellipsis,
        ),
        childrenPadding: const EdgeInsets.only(left: 10),
        initiallyExpanded: item.isExpanded,
        onExpansionChanged: (isExpanded) {
          context.read<AppState>().setFolderExpansion(item, isExpanded);
        },
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 16, color: Colors.grey),
          onPressed: () => state.removeFile(item),
        ),
        children: item.children.map((child) => FileNode(item: child)).toList(),
      );
    } else {
      return Container(
        color: isSelected ? Colors.blue.withOpacity(0.2) : Colors.transparent,
        child: ListTile(
          leading: Icon(
            Icons.insert_drive_file,
            size: 18,
            color: isSelected ? Colors.blueAccent : Colors.blueGrey,
          ),
          title: Text(
            item.name,
            style: TextStyle(fontSize: 13, color: textColor),
            overflow: TextOverflow.ellipsis,
          ),
          dense: true,
          // 1. Tag Logic: Buttons Row
          trailing: SizedBox(
            width: 96, // Width for 3 buttons
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Pass Button (Green)
                InkWell(
                  onTap: () => state.setFileStatus(item, FileStatus.pass),
                  child: const Padding(
                    padding: EdgeInsets.all(4.0),
                    child: Icon(
                      Icons.check_circle_outline,
                      size: 16,
                      color: Colors.green,
                    ),
                  ),
                ),
                // Fail Button (Red)
                InkWell(
                  onTap: () => state.setFileStatus(item, FileStatus.fail),
                  child: const Padding(
                    padding: EdgeInsets.all(4.0),
                    child: Icon(
                      Icons.highlight_off,
                      size: 16,
                      color: Colors.red,
                    ),
                  ),
                ),
                // Delete Button
                InkWell(
                  onTap: () => state.removeFile(item),
                  child: const Padding(
                    padding: EdgeInsets.all(4.0),
                    child: Icon(
                      Icons.delete_outline,
                      size: 16,
                      color: Colors.grey,
                    ),
                  ),
                ),
              ],
            ),
          ),
          onTap: () => context.read<AppState>().selectFile(item),
        ),
      );
    }
  }
}

class FeatureSelectorSidebar extends StatelessWidget {
  const FeatureSelectorSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.currentCsv == null) {
      return const Center(
        child: Text("No CSV Selected.", textAlign: TextAlign.center),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: state.selectAllFeatures,
                  child: const Text(
                    "Select All",
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: state.unselectAllFeatures,
                  child: const Text(
                    "Unselect All",
                    style: TextStyle(fontSize: 12, color: Colors.redAccent),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: state.currentCsv!.headers.length,
            itemBuilder: (context, index) {
              String header = state.currentCsv!.headers[index];
              bool isChecked = state.visibleColumns.contains(header);

              return Theme(
                data: ThemeData.dark().copyWith(
                  unselectedWidgetColor: Colors.grey,
                ),
                child: CheckboxListTile(
                  title: Text(
                    header,
                    style: TextStyle(
                      fontSize: 12,
                      color: isChecked ? Colors.white : Colors.grey,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  value: isChecked,
                  activeColor: Colors.blueAccent,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  onChanged: (val) => state.toggleColumnVisibility(header),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class NormalizationSidebar extends StatelessWidget {
  const NormalizationSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          const Text(
            "Normalize data to range [-1.0, 1.0]",
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 20),
          SwitchListTile(
            title: const Text("Enable Normalization"),
            subtitle: Text(state.isNormalized ? "Active" : "Inactive"),
            value: state.isNormalized,
            activeColor: Colors.green,
            onChanged: (val) => state.setNormalization(val),
          ),
        ],
      ),
    );
  }
}

class SettingsSidebar extends StatelessWidget {
  const SettingsSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          "General Settings",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Enable Tooltip"),
          value: state.showTooltip,
          onChanged: (val) => state.setTooltipEnabled(val),
        ),
        const Divider(),
        const Text(
          "Marker Settings",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Show Data Points"),
          value: state.showMarkers,
          onChanged: (val) => state.setShowMarkers(val),
        ),
        if (state.showMarkers) ...[
          Text("Marker Size: ${state.markerSize.toInt()}"),
          Slider(
            min: 2,
            max: 10,
            value: state.markerSize,
            onChanged: (v) => state.setMarkerSize(v),
          ),
        ],
        const Divider(),
        const Text("Layout", style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Text("Chart Height: ${state.plotHeight.toInt()}"),
        Slider(
          min: 200,
          max: 1500,
          value: state.plotHeight,
          onChanged: (v) => state.setPlotHeight(v),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// 5. CHART AREA
// -----------------------------------------------------------------------------

class ChartArea extends StatelessWidget {
  const ChartArea({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.currentCsv == null) {
      return const Center(
        child: Text(
          "Select a CSV file to view chart",
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    if (state.visibleColumns.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.checklist_rtl, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              "No features selected.",
              style: TextStyle(fontSize: 18, color: Colors.white70),
            ),
          ],
        ),
      );
    }

    int rowCount = state.currentCsv!.data.values.first.length;
    List<int> xValues = List.generate(rowCount, (index) => index);

    final List<Color> palette = [
      Colors.cyanAccent,
      Colors.orangeAccent,
      Colors.purpleAccent,
      Colors.greenAccent,
      Colors.redAccent,
      Colors.yellowAccent,
      Colors.pinkAccent,
      Colors.tealAccent,
      Colors.indigoAccent,
    ];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        SizedBox(
          height: state.plotHeight,
          child: SfCartesianChart(
            legend: const Legend(isVisible: false),
            zoomPanBehavior: ZoomPanBehavior(
              enablePinching: true,
              enablePanning: true,
              enableSelectionZooming: true,
              enableMouseWheelZooming: true,
              zoomMode: ZoomMode.x,
            ),
            tooltipBehavior: state.showTooltip
                ? TooltipBehavior(
                    enable: true,
                    builder: (data, point, series, pointIndex, seriesIndex) {
                      return Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF252526),
                          border: Border.all(color: Colors.white24),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              (series as LineSeries).name ?? "-",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              "Y: ${point.y?.toStringAsFixed(3)}",
                              style: const TextStyle(
                                color: Colors.blueAccent,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  )
                : null,
            primaryXAxis: const NumericAxis(
              title: AxisTitle(text: 'Index'),
              majorGridLines: MajorGridLines(width: 0.5, color: Colors.white10),
            ),
            primaryYAxis: NumericAxis(
              title: AxisTitle(text: state.isNormalized ? 'Norm' : 'Raw'),
              majorGridLines: const MajorGridLines(
                width: 0.5,
                color: Colors.white10,
              ),
              minimum: state.isNormalized ? -1.1 : null,
              maximum: state.isNormalized ? 1.1 : null,
            ),
            series: _buildSeries(state, xValues, palette),
          ),
        ),

        const SizedBox(height: 10),
        const Divider(),

        InkWell(
          onTap: () => state.toggleLegend(),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Legend (Active Features)",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Icon(
                  state.isLegendExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: Colors.white70,
                ),
              ],
            ),
          ),
        ),

        if (state.isLegendExpanded)
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              childAspectRatio: 5,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: state.visibleColumns.length,
            itemBuilder: (context, index) {
              String name = state.visibleColumns.elementAt(index);
              Color color = palette[index % palette.length];
              return Row(
                children: [
                  Container(width: 12, height: 12, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              );
            },
          ),
        const SizedBox(height: 50),
      ],
    );
  }

  List<CartesianSeries> _buildSeries(
    AppState state,
    List<int> xValues,
    List<Color> palette,
  ) {
    List<CartesianSeries> seriesList = [];
    int colorIndex = 0;

    for (String header in state.visibleColumns) {
      List<double>? rawData = state.currentCsv!.data[header];
      if (rawData == null) continue;

      List<ChartDataPoint> points = [];
      double maxVal = 1.0;

      if (state.isNormalized) {
        double maxInCol = rawData.reduce(max);
        double minInCol = rawData.reduce(min);
        maxVal = max(maxInCol.abs(), minInCol.abs());
        if (maxVal == 0) maxVal = 1.0;
      }

      for (int i = 0; i < rawData.length; i++) {
        double y = rawData[i];
        if (state.isNormalized) {
          y = y / maxVal;
        }
        points.add(ChartDataPoint(i, y));
      }

      seriesList.add(
        LineSeries<ChartDataPoint, int>(
          name: header,
          dataSource: points,
          xValueMapper: (ChartDataPoint data, _) => data.x,
          yValueMapper: (ChartDataPoint data, _) => data.y,
          color: palette[colorIndex % palette.length],
          width: 1.5,
          animationDuration: 0,
          markerSettings: MarkerSettings(
            isVisible: state.showMarkers,
            width: state.markerSize,
            height: state.markerSize,
          ),
        ),
      );
      colorIndex++;
    }
    return seriesList;
  }
}

class ChartDataPoint {
  final int x;
  final double y;
  ChartDataPoint(this.x, this.y);
}
