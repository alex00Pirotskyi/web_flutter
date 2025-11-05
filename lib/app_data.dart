import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Import

class AppData extends ChangeNotifier {
  Map<String, List<String>> _settingsData = {};
  final List<String> _users = [];
  final Map<String, Map<String, Map<String, int>>> _allUserResults = {};
  String? _currentUser;

  // Keys for saving data
  static const _kSettings = 'app_settings';
  static const _kUsers = 'app_users';
  static const _kCurrentUser = 'app_current_user';
  static const _kResults = 'app_all_results';

  // 💡 MODIFIED: Constructor is now empty.
  AppData();

  Map<String, List<String>> get settingsData => _settingsData;
  List<String> get users => _users;
  String? get currentUser => _currentUser;
  Map<String, Map<String, Map<String, int>>> get allUserResults =>
      _allUserResults;

  Map<String, Map<String, int>> get currentResultsData {
    if (_currentUser == null) return {};
    return _allUserResults[_currentUser] ?? {};
  }

  String getSettingsAsJsonString() {
    if (_settingsData.isEmpty) {
      return '''
{
  "CATEGORY_1_NAME": [
    "Item 1",
    "Item 2"
  ],
  "CATEGORY_2_NAME": [
    "Item A",
    "Item B"
  ]
}
''';
    }
    JsonEncoder encoder = const JsonEncoder.withIndent('  ');
    return encoder.convert(_settingsData);
  }

  //
  // --- 💡 AUTO-SAVE & LOAD FUNCTIONS ---
  //

  /// Saves the app's entire state to the browser's local storage
  Future<void> _saveDataToLocalStorage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSettings, json.encode(_settingsData));
    await prefs.setStringList(_kUsers, _users);
    if (_currentUser != null) {
      await prefs.setString(_kCurrentUser, _currentUser!);
    } else {
      await prefs.remove(_kCurrentUser);
    }
    await prefs.setString(_kResults, json.encode(_allUserResults));
  }

  // 💡 MODIFIED: Renamed to `loadData` and made public
  /// Loads the app's state when it first starts up
  Future<void> loadData() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Load Settings
    try {
      final settingsString = prefs.getString(_kSettings);
      if (settingsString != null) {
        _settingsData = Map<String, List<String>>.from(
          json
              .decode(settingsString)
              .map(
                (key, value) =>
                    MapEntry(key, List<String>.from(value as List<dynamic>)),
              ),
        );
      }
    } catch (e) {
      debugPrint('Could not load settings: $e');
    }

    // 2. Load Users
    _users.addAll(prefs.getStringList(_kUsers) ?? []);

    // 3. Load Results
    try {
      final resultsString = prefs.getString(_kResults);
      if (resultsString != null) {
        final Map<String, dynamic> decodedResults = json.decode(resultsString);
        _allUserResults.clear();
        decodedResults.forEach((userName, userResults) {
          final Map<String, Map<String, int>> newUserResults = {};
          (userResults as Map<String, dynamic>).forEach((category, items) {
            newUserResults[category] = Map<String, int>.from(items);
          });
          _allUserResults[userName] = newUserResults;
        });
      }
    } catch (e) {
      debugPrint('Could not load results: $e');
    }

    // 4. Load Current User
    _currentUser = prefs.getString(_kCurrentUser);

    // No notifyListeners() needed here, as the app hasn't built yet.
  }

  //
  // --- All other functions now call _saveDataToLocalStorage ---
  // (These are all unchanged from before)
  //

  void setCurrentUser(String? userName) {
    _currentUser = userName;
    _saveDataToLocalStorage(); // Auto-save
    notifyListeners();
  }

  void addUser(String userName) {
    if (userName.isEmpty || _users.contains(userName)) return;
    _users.add(userName);
    _allUserResults[userName] = {};
    _currentUser = userName;
    _saveDataToLocalStorage(); // Auto-save
    notifyListeners();
  }

  void loadSettings(String jsonContent) {
    try {
      final Map<String, dynamic> newSettings = json.decode(jsonContent);
      _settingsData = Map<String, List<String>>.from(
        newSettings.map(
          (key, value) =>
              MapEntry(key, List<String>.from(value as List<dynamic>)),
        ),
      );

      if (_currentUser == null && _users.isNotEmpty) {
        _currentUser = _users.first;
      }
      _saveDataToLocalStorage(); // Auto-save
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading settings JSON: $e');
    }
  }

  void updateResult(String mainKey, String subKey, int count) {
    if (_currentUser == null) return;
    if (!_allUserResults.containsKey(_currentUser)) {
      _allUserResults[_currentUser!] = {};
    }
    if (!_allUserResults[_currentUser]!.containsKey(mainKey)) {
      _allUserResults[_currentUser]![mainKey] = {};
    }
    _allUserResults[_currentUser]![mainKey]![subKey] = count;
    _saveDataToLocalStorage(); // Auto-save
    notifyListeners();
  }

  void loadResultsFromCsv(String csvString) {
    try {
      final List<List<dynamic>> rows = const CsvToListConverter().convert(
        csvString,
        eol: '\n',
      );
      if (rows.length < 2) return;
      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];
        final String userName = row[0].toString().replaceAll('"', '');
        final String category = row[1].toString().replaceAll('"', '');
        final String item = row[2].toString().replaceAll('"', '');
        final int count = int.tryParse(row[3].toString()) ?? 0;
        if (userName.isNotEmpty && !_users.contains(userName)) {
          _users.add(userName);
        }
        if (!_allUserResults.containsKey(userName)) {
          _allUserResults[userName] = {};
        }
        if (!_allUserResults[userName]!.containsKey(category)) {
          _allUserResults[userName]![category] = {};
        }
        _allUserResults[userName]![category]![item] = count;
      }
      _currentUser = _users.isNotEmpty ? _users.first : null;
      _saveDataToLocalStorage(); // Auto-save
      notifyListeners();
    } catch (e) {
      debugPrint('Error parsing CSV: $e');
    }
  }

  void deleteCurrentUser() {
    if (_currentUser == null) return;
    final String userToDelete = _currentUser!;
    final int userIndex = _users.indexOf(userToDelete);
    _users.remove(userToDelete);
    _allUserResults.remove(userToDelete);

    if (_users.isEmpty) {
      _currentUser = null;
    } else if (userIndex > 0) {
      _currentUser = _users[userIndex - 1];
    } else {
      _currentUser = _users.first;
    }
    _saveDataToLocalStorage(); // Auto-save
    notifyListeners();
  }

  void clearCurrentUserResults() {
    if (_currentUser != null) {
      _allUserResults[_currentUser]?.clear();
      _saveDataToLocalStorage(); // Auto-save
      notifyListeners();
    }
  }

  void clearCategoryResults(String categoryKey) {
    if (_currentUser == null) return;
    if (_allUserResults.containsKey(_currentUser)) {
      _allUserResults[_currentUser]!.remove(categoryKey);
      _saveDataToLocalStorage(); // Auto-save
      notifyListeners();
    }
  }
}
