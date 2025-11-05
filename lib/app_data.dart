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

  // This simulates "downloading" or loading the settings JSON
  void loadSettings() {
    // This is your example JSON structure.
    // I've simplified the inner values to a list of keys.
    _settingsData = {
      "TAP": ["Screen", "Button A", "Icon B"],
      "SWIPE": ["Left", "Right", "Up"],
      "LONG_PRESS": ["Header", "Footer Image"],
    };

    // When we load new settings, we clear the old results
    _resultsData = {};

    // Tell all listening widgets (like your pages) to rebuild
    notifyListeners();
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
