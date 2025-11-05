import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For Clipboard
import 'package:provider/provider.dart';
import 'app_data.dart';
import 'counting_page.dart';
import 'settings_page.dart';
import 'dart:convert'; // For JSON and base64
import 'package:web/web.dart' as web;
import 'dart:js_interop';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _isButtonGridExpanded = true;

  @override
  void dispose() {
    super.dispose();
  }

  // --- Backend functions (unchanged) ---
  String _buildCsvData(BuildContext context) {
    final allResults = context.read<AppData>().allUserResults;
    List<List<String>> rows = [];
    rows.add(['Name', 'Category', 'Item', 'Count']);
    for (var userName in allResults.keys) {
      final userResults = allResults[userName]!;
      for (var category in userResults.keys) {
        final categoryResults = userResults[category]!;
        for (var item in categoryResults.keys) {
          var count = categoryResults[item];
          rows.add(['"$userName"', '"$category"', '"$item"', count.toString()]);
        }
      }
    }
    return rows.map((row) => row.join(',')).join('\n');
  }

  void _downloadResults(BuildContext context) {
    final csvData = _buildCsvData(context);
    final bytes = utf8.encode(csvData);
    final base64 = base64Encode(bytes);
    web.HTMLAnchorElement()
      ..href = 'data:text/csv;base64,$base64'
      ..setAttribute('download', 'all-user-results.csv')
      ..click();
  }

  void _copyResultsToClipboard(BuildContext context) {
    final csvData = _buildCsvData(context);
    Clipboard.setData(ClipboardData(text: csvData));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('All results copied to clipboard!'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        width: 300,
      ),
    );
  }

  void _pickAndLoadResults(BuildContext context) {
    final web.HTMLInputElement uploadInput = web.HTMLInputElement();
    uploadInput.type = 'file';
    uploadInput.accept = '.csv,text/csv';
    uploadInput.click();
    uploadInput.onChange.listen((e) {
      if (uploadInput.files == null || uploadInput.files!.length == 0) return;
      final web.File file = uploadInput.files!.item(0)!;
      final web.FileReader reader = web.FileReader();
      reader.onLoadEnd.listen((e) {
        if (!context.mounted) return;
        final String csvContent = (reader.result as JSString).toDart;
        if (csvContent.isNotEmpty) {
          context.read<AppData>().loadResultsFromCsv(csvContent);
        }
      });
      reader.readAsText(file);
    });
  }

  void _pickAndLoadSettings(BuildContext context) {
    final web.HTMLInputElement uploadInput = web.HTMLInputElement();
    uploadInput.type = 'file';
    uploadInput.accept = '.json,application/json';
    uploadInput.click();
    uploadInput.onChange.listen((e) {
      if (uploadInput.files == null || uploadInput.files!.length == 0) return;
      final web.File file = uploadInput.files!.item(0)!;
      final web.FileReader reader = web.FileReader();
      reader.onLoadEnd.listen((e) {
        if (!context.mounted) return;
        final String jsonContent = (reader.result as JSString).toDart;
        if (jsonContent.isNotEmpty) {
          context.read<AppData>().loadSettings(jsonContent);
        }
      });
      reader.readAsText(file);
    });
  }

  // --- Dialogs (unchanged) ---
  void _showDeleteUserDialog(BuildContext context) {
    final appData = context.read<AppData>();
    final currentUser = appData.currentUser;
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add or select a user first.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Delete User?'),
          content: Text(
            'Are you sure you want to delete "$currentUser" and all their results?\n\nThis cannot be undone.',
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Delete'),
              onPressed: () {
                if (!context.mounted) return;
                appData.deleteCurrentUser();
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _showResetCategoryDialog(BuildContext context, String categoryName) {
    final appData = context.read<AppData>();
    final currentUser = appData.currentUser;
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Reset Category?'),
          content: Text(
            'Are you sure you want to reset the results for "$categoryName" for user "$currentUser"?',
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Reset'),
              onPressed: () {
                if (!context.mounted) return;
                appData.clearCategoryResults(categoryName);
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _showAddUserDialog(BuildContext context) {
    final TextEditingController userController = TextEditingController();
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Add New User'),
          content: TextField(
            controller: userController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'User Name'),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              child: const Text('Add'),
              onPressed: () {
                if (!context.mounted) return;
                if (userController.text.isNotEmpty) {
                  context.read<AppData>().addUser(userController.text);
                  Navigator.of(dialogContext).pop();
                }
              },
            ),
          ],
        );
      },
    );
  }

  // --- Helper: Builds the user panel (Unchanged) ---
  Widget _buildUserPanel(BuildContext context) {
    final appData = context.watch<AppData>();
    final users = appData.users;
    final currentUser = appData.currentUser;

    return Card(
      elevation: 2,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButton<String>(
              value: currentUser,
              isExpanded: true,
              underline: Container(),
              hint: const Text('Select a User'),
              items: users.map((String userName) {
                return DropdownMenuItem<String>(
                  value: userName,
                  child: Text(userName),
                );
              }).toList(),
              onChanged: (String? newValue) {
                context.read<AppData>().setCurrentUser(newValue);
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add New User'),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => _showAddUserDialog(context),
            ),
          ],
        ),
      ),
    );
  }

  // --- Helper: Calculate average (Unchanged) ---
  double _calculateCategoryAverage(Map<String, int> results) {
    if (results.isEmpty) return 0.0;
    final sum = results.values.reduce((a, b) => a + b);
    return sum / results.length;
  }

  // --- Category board (Unchanged) ---
  Widget _buildCategoryBoard(BuildContext context) {
    final appData = context.watch<AppData>();
    final categories = appData.settingsData.keys.toList();

    if (categories.isEmpty) {
      return Card(
        elevation: 2,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          padding: const EdgeInsets.all(16),
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'No settings loaded.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => SettingsPage()),
                  );
                },
                child: const Text('Create Settings'),
              ),
            ],
          ),
        ),
      );
    }

    if (appData.currentUser == null) {
      return Card(
        elevation: 2,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          padding: const EdgeInsets.all(16),
          width: double.infinity,
          child: Text(
            'Please add or select a user to start a test.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.3,
      children: categories.map((categoryKey) {
        final results = appData.currentResultsData[categoryKey] ?? {};
        final isFinished = _isCategoryFinished(context, categoryKey);
        final average = _calculateCategoryAverage(results);

        return _buildCategoryCard(
          categoryName: categoryKey,
          results: results,
          isFinished: isFinished,
          average: average,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => CountingPage(mainKey: categoryKey),
              ),
            );
          },
          onLongPress: () {
            _showResetCategoryDialog(context, categoryKey);
          },
        );
      }).toList(),
    );
  }

  //
  // --- 💡 MODIFIED: Category card layout (Fixes syntax error) ---
  //
  Widget _buildCategoryCard({
    required String categoryName,
    required Map<String, int> results,
    required bool isFinished,
    required double average,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- 💡 This is the corrected Row ---
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Name (on the left)
                  Flexible(
                    flex: 3, // Give name more space
                    child: Text(
                      categoryName,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 28,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),

                  // 2. Average (in the middle)
                  Flexible(
                    flex: 2, // Give average space
                    child: (average > 0)
                        ? Text(
                            average.toStringAsFixed(1),
                            textAlign: TextAlign.center, // Center it
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Colors.black54,
                            ),
                          )
                        : const SizedBox(), // Empty space if no average
                  ),

                  // 3. Checkmark (on the end)
                  if (isFinished)
                    const Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 30,
                    )
                  else
                    // Placeholder to keep spacing correct
                    const SizedBox(width: 20),
                ],
              ),
              const Divider(height: 12),

              // --- End of modified Row ---
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (results.isEmpty)
                        Text(
                          'No results yet.',
                          style: TextStyle(
                            fontSize: 24,
                            color: Colors.grey.shade600,
                          ),
                        )
                      else
                        ...results.entries.map((entry) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Flexible(
                                  child: Text(
                                    entry.key,
                                    style: const TextStyle(fontSize: 24),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  entry.value.toString(),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isCategoryFinished(BuildContext context, String categoryKey) {
    final appData = context.read<AppData>();
    final requiredItems = appData.settingsData[categoryKey];
    final recordedResults = appData.currentResultsData[categoryKey];

    if (requiredItems == null || requiredItems.isEmpty) return false;
    if (recordedResults == null) return false;
    if (requiredItems.length != recordedResults.length) return false;

    return requiredItems.every((item) => recordedResults.containsKey(item));
  }

  // --- Main build method (unchanged) ---
  @override
  Widget build(BuildContext context) {
    final appData = context.watch<AppData>();
    final bool hasAllResults = appData.allUserResults.isNotEmpty;
    final bool hasCurrentUserResults = appData.currentResultsData.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Data Collector')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildUserPanel(context),
            const SizedBox(height: 24),

            Card(
              elevation: 2,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  ListTile(
                    title: Text(
                      'Actions',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        _isButtonGridExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                      ),
                      onPressed: () {
                        setState(() {
                          _isButtonGridExpanded = !_isButtonGridExpanded;
                        });
                      },
                    ),
                  ),
                  Visibility(
                    visible: _isButtonGridExpanded,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 1.5,
                        children: [
                          _buildActionButton(
                            context,
                            icon: Icons.upload_file,
                            label: 'Load Settings',
                            onTap: () => _pickAndLoadSettings(context),
                          ),
                          _buildActionButton(
                            context,
                            icon: Icons.folder_open,
                            label: 'Load Results',
                            onTap: () => _pickAndLoadResults(context),
                          ),
                          _buildActionButton(
                            context,
                            icon: Icons.settings,
                            label: 'Settings',
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => SettingsPage(),
                                ),
                              );
                            },
                          ),
                          _buildActionButton(
                            context,
                            icon: Icons.download,
                            label: 'Download',
                            isEnabled: hasAllResults,
                            onTap: () => _downloadResults(context),
                          ),
                          _buildActionButton(
                            context,
                            icon: Icons.copy_all_outlined,
                            label: 'Copy',
                            color: Colors.green.shade700,
                            isEnabled: hasAllResults,
                            onTap: () => _copyResultsToClipboard(context),
                          ),
                          _buildActionButton(
                            context,
                            icon: Icons.delete_sweep_outlined,
                            label: 'Delete User',
                            color: Colors.red.shade700,
                            isEnabled: hasCurrentUserResults,
                            onTap: () => _showDeleteUserDialog(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            Text(
              'Test Categories',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(color: Colors.black54),
            ),
            const SizedBox(height: 10),
            _buildCategoryBoard(context),
          ],
        ),
      ),
    );
  }

  // --- Button helper (unchanged) ---
  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isEnabled = true,
    Color? color,
  }) {
    final anabledColor = color ?? Theme.of(context).colorScheme.primary;
    final disabledColor = Colors.grey.shade400;

    return Card(
      elevation: isEnabled ? 4 : 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: isEnabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Opacity(
          opacity: isEnabled ? 1.0 : 0.5,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 28,
                color: isEnabled ? anabledColor : disabledColor,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                  color: isEnabled ? anabledColor : disabledColor,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
