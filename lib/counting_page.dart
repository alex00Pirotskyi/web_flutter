import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_data.dart';

// TapEffect class (unchanged)
class TapEffect {
  final Offset position;
  TapEffect({required this.position});
}

class CountingPage extends StatefulWidget {
  final String mainKey;
  const CountingPage({super.key, required this.mainKey});

  @override
  State<CountingPage> createState() => _CountingPageState();
}

class _CountingPageState extends State<CountingPage> {
  String? _selectedSubKey;
  int _mousePressCount = 0;
  final List<TapEffect> _tapEffects = [];

  @override
  void initState() {
    super.initState();
    final appData = context.read<AppData>();
    final subKeys = appData.settingsData[widget.mainKey] ?? [];
    if (subKeys.isNotEmpty) {
      _selectedSubKey = subKeys.first;
    }
  }

  void _handlePageTap(PointerDownEvent event) {
    final effect = TapEffect(position: event.localPosition);
    setState(() {
      _mousePressCount++;
      _tapEffects.add(effect);
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _tapEffects.remove(effect);
        });
      }
    });
  }
  
  // --- 💡 MODIFIED: Alert Dialog for resetting CURRENT CATEGORY ---
  void _showResetCategoryDialog(BuildContext context) {
    final appData = context.read<AppData>();
    final currentUser = appData.currentUser ?? "current user";

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          // 💡 Changed title
          title: const Text('Reset Category Test?'),
          // 💡 Changed content
          content: Text(
              'Are you sure you want to clear all results for "${widget.mainKey}" for $currentUser?'),
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
                // 💡 Call the correct function: clearCategoryResults
                appData.clearCategoryResults(widget.mainKey);
                Navigator.of(dialogContext).pop();
                // We DON'T pop the page, we just stay here
              },
            ),
          ],
        );
      },
    );
  }


  Widget _buildNumberPad() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 4.0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor,
            width: 1,
          ),
        ),
      ),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          childAspectRatio: 2.5,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: 10,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemBuilder: (context, index) {
          final score = index + 1;
          return ElevatedButton(
            onPressed: _selectedSubKey == null
                ? null
                : () {
                    context.read<AppData>().updateResult(
                          widget.mainKey,
                          _selectedSubKey!,
                          score,
                        );
                  },
            style: ElevatedButton.styleFrom(
              padding: EdgeInsets.zero,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            child: Text('$score'),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 💡 Use context.watch() so the page rebuilds when results are cleared
    final appData = context.watch<AppData>();
    final subKeys = appData.settingsData[widget.mainKey] ?? [];
    final currentResults = appData.currentResultsData[widget.mainKey] ?? {};

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mainKey),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // 💡 MODIFIED Button
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Reset This Category', // 💡 Changed tooltip
            onPressed: () => _showResetCategoryDialog(context), // 💡 Changed function
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset Click Counter',
            onPressed: () {
              setState(() {
                _mousePressCount = 0;
              });
            },
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Listener(
              onPointerDown: _handlePageTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '1. Select an item to score:',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8.0,
                          runSpacing: 4.0,
                          children: subKeys.map((subKey) {
                            return ChoiceChip(
                              label: Text(subKey),
                              selected: _selectedSubKey == subKey,
                              onSelected: (isSelected) {
                                setState(() {
                                  _selectedSubKey = isSelected ? subKey : null;
                                });
                              },
                            );
                          }).toList(),
                        ),
                        const Divider(height: 40),
                        Text(
                          'Current Results for ${widget.mainKey}:',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 10),
                        if (currentResults.isEmpty) // This will now update on reset
                          const Text('No results yet.')
                        else
                          ...currentResults.entries.map((entry) {
                            return ListTile(
                              title: Text(entry.key),
                              trailing: Text(
                                entry.value.toString(),
                                style:
                                    Theme.of(context).textTheme.headlineSmall,
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                  Align(
                    alignment: Alignment.topCenter,
                    child: IgnorePointer(
                      child: Container(
                        margin: const EdgeInsets.only(top: 20.0),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Clicks: $_mousePressCount',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                  ..._tapEffects.map(
                    (effect) => Positioned(
                      left: effect.position.dx - 12,
                      top: effect.position.dy - 12,
                      child: IgnorePointer(
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.blue.withOpacity(0.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _buildNumberPad(),
        ],
      ),
    );
  }
}