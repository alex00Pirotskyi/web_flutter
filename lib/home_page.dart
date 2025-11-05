import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For Clipboard
import 'package:provider/provider.dart';
import 'app_data.dart';
import 'counting_page.dart';
import 'dart:convert'; // For JSON and base64
import 'dart:html' as html; // For web-only

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // --- 💡 NEW State variable for Request 2 ---
  bool _isButtonGridExpanded = true;

  @override
  void dispose() {
    super.dispose();
  }

  // --- All backend functions (CSV, Download, etc.) are unchanged ---
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
    final anchor =
        html.AnchorElement(href: 'data:text/csv;base64,$base64')
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
            borderRadius: BorderRadius.all(Radius.circular(12))),
        width: 300,
      ),
    );
  }
  
  void _pickAndLoadResults(BuildContext context) {
    final html.FileUploadInputElement uploadInput =
        html.FileUploadInputElement();
    uploadInput.accept = '.csv,text/csv';
    uploadInput.click();
    uploadInput.onChange.listen((e) {
      if (uploadInput.files == null || uploadInput.files!.isEmpty) return;
      final html.File file = uploadInput.files!.first;
      final html.FileReader reader = html.FileReader();
      reader.onLoadEnd.listen((e) {
        final String csvContent = reader.result as String;
        if (csvContent.isNotEmpty) {
          context.read<AppData>().loadResultsFromCsv(csvContent);
        }
      });
      reader.readAsText(file);
    });
  }

  void _pickAndLoadSettings(BuildContext context) {
    final html.FileUploadInputElement uploadInput =
        html.FileUploadInputElement();
    uploadInput.accept = '.json,application/json';
    uploadInput.click();
    uploadInput.onChange.listen((e) {
      if (uploadInput.files == null || uploadInput.files!.isEmpty) return;
      final html.File file = uploadInput.files!.first;
      final html.FileReader reader = html.FileReader();
      reader.onLoadEnd.listen((e) {
        final String jsonContent = reader.result as String;
        if (jsonContent.isNotEmpty) {
          context.read<AppData>().loadSettings(jsonContent);
        }
      });
      reader.readAsText(file);
    });
  }
  // --- End of helper functions ---


  // --- Dialogs (Unchanged) ---
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
              'Are you sure you want to delete "$currentUser" and all their results?\n\nThis cannot be undone.'),
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
                appData.deleteCurrentUser();
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        );
      },
    );
  }

  // --- 💡 NEW: Alert Dialog for Request 1 ---
  void _showResetCategoryDialog(BuildContext context, String categoryName) {
    final appData = context.read<AppData>();
    final currentUser = appData.currentUser;

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Reset Category?'),
          content: Text(
              'Are you sure you want to reset the results for "$categoryName" for user "$currentUser"?'),
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
                // Call the new function
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

  // --- Category board and card widgets ---
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
          child: Text(
            'Load a settings JSON file to begin.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
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
      childAspectRatio: 0.9,
      children: categories.map((categoryKey) {
        final results = appData.currentResultsData[categoryKey] ?? {};
        final isFinished = _isCategoryFinished(context, categoryKey);

        return _buildCategoryCard(
          categoryName: categoryKey,
          results: results,
          isFinished: isFinished,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => CountingPage(mainKey: categoryKey),
              ),
            );
          },
          // 💡 NEW: Pass the long-press action
          onLongPress: () {
            _showResetCategoryDialog(context, categoryKey);
          },
        );
      }).toList(),
    );
  }
  
  Widget _buildCategoryCard({
    required String categoryName,
    required Map<String, int> results,
    required bool isFinished,
    required VoidCallback onTap,
    required VoidCallback onLongPress, // 💡 NEW
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress, // 💡 NEW
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      categoryName,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isFinished)
                    const Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 20,
                    ),
                ],
              ),
              const Divider(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (results.isEmpty)
                        Text(
                          'No results yet.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
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
                                    style: const TextStyle(fontSize: 12),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  entry.value.toString(),
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
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

  @override
  Widget build(BuildContext context) {
    final appData = context.watch<AppData>();
    final bool hasAllResults = appData.allUserResults.isNotEmpty;
    final bool hasCurrentUserResults = appData.currentResultsData.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Data Collector'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- User Panel ---
            _buildUserPanel(context),
            const SizedBox(height: 24),

            // --- 💡 MODIFIED: Foldable Button Grid ---
            Card(
              elevation: 2,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              child: Column(
                children: [
                  ListTile(
                    title: Text('Actions',
                        style: Theme.of(context).textTheme.titleMedium),
                    trailing: IconButton(
                      icon: Icon(_isButtonGridExpanded
                          ? Icons.expand_less
                          : Icons.expand_more),
                      onPressed: () {
                        setState(() {
                          _isButtonGridExpanded = !_isButtonGridExpanded;
                        });
                      },
                    ),
                  ),
                  // This will hide/show the grid
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
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.black54,
                  ),
            ),
            const SizedBox(height: 10),
            _buildCategoryBoard(context), // The grid widget
          ],
        ),
      ),
    );
  }

  // (This widget is unchanged)
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
                  fontSize: 11,
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