import 'package:flutter/foundation.dart';
import 'dart:convert';

class AppData extends ChangeNotifier {
  // This holds your settings, e.g., {"TAP": ["bla", "bla2"], ...}
  Map<String, List<String>> _settingsData = {};

  // This holds your results, e.g., {"TAP": {"bla": 6}, ...}
  Map<String, Map<String, int>> _resultsData = {};

  // "Getters" to allow other widgets to read the data
  Map<String, List<String>> get settingsData => _settingsData;
  Map<String, Map<String, int>> get resultsData => _resultsData;

  // --- 💡 MODIFIED FUNCTION ---
  // This now parses JSON content passed to it from the file uploader
  void loadSettings(String jsonContent) {
    try {
      // Decode the JSON string
      final Map<String, dynamic> newSettings = json.decode(jsonContent);

      // Convert the dynamic map to the correct type
      // This ensures that "TAP": ["val1", "val2"] is correctly parsed
      _settingsData = Map<String, List<String>>.from(
        newSettings.map(
          (key, value) => MapEntry(
            key,
            // Ensure the value is treated as a list of strings
            List<String>.from(value as List<dynamic>),
          ),
        ),
      );

      // When we load new settings, we clear the old results
      _resultsData = {};

      // Tell all listening widgets (like your pages) to rebuild
      notifyListeners();
    } catch (e) {
      // Handle bad JSON
      debugPrint('Error loading settings JSON: $e');
      // In a real app, you'd show a user-facing error here
    }
  }

  // Clears all the results you've collected
  void clearResults() {
    _resultsData = {};
    notifyListeners();
  }

  // Called from Page 2 to add a new count
  void updateResult(String mainKey, String subKey, int count) {
    // Create the inner map if it doesn't exist
    if (!_resultsData.containsKey(mainKey)) {
      _resultsData[mainKey] = {};
    }
    // Add the count
    _resultsData[mainKey]![subKey] = count;
    notifyListeners();
  }

  // Converts your results map into a formatted JSON string
  String getResultsAsJsonString() {
    JsonEncoder encoder = const JsonEncoder.withIndent('  ');
    return encoder.convert(_resultsData);
  }
}
