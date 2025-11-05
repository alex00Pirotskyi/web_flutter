import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:csv/csv.dart';

class AppData extends ChangeNotifier {
  Map<String, List<String>> _settingsData = {};

  // 💡 MODIFICATION: Made these two fields final
  final List<String> _users = [];
  final Map<String, Map<String, Map<String, int>>> _allUserResults = {};

  String? _currentUser;

  Map<String, List<String>> get settingsData => _settingsData;
  List<String> get users => _users;
  String? get currentUser => _currentUser;
  Map<String, Map<String, Map<String, int>>> get allUserResults =>
      _allUserResults;

  Map<String, Map<String, int>> get currentResultsData {
    if (_currentUser == null) return {};
    return _allUserResults[_currentUser] ?? {};
  }

  void setCurrentUser(String? userName) {
    _currentUser = userName;
    notifyListeners();
  }

  void addUser(String userName) {
    if (userName.isEmpty || _users.contains(userName)) return;
    _users.add(userName);
    _allUserResults[userName] = {};
    _currentUser = userName;
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

      _allUserResults.clear();
      _currentUser = _users.isNotEmpty ? _users.first : null;
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
    notifyListeners();
  }

  void clearCurrentUserResults() {
    if (_currentUser != null) {
      _allUserResults[_currentUser]?.clear();
      notifyListeners();
    }
  }

  void clearCategoryResults(String categoryKey) {
    if (_currentUser == null) return;
    if (_allUserResults.containsKey(_currentUser)) {
      _allUserResults[_currentUser]!.remove(categoryKey);
      notifyListeners();
    }
  }

  // --- 💡 NEW FUNCTION ---
  /// Gets the current settings as a formatted JSON string.
  String getSettingsAsJsonString() {
    if (_settingsData.isEmpty) {
      // Return a nice empty template if no settings are loaded
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
}
