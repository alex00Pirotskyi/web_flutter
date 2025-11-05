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

  void _showResetCategoryDialog(BuildContext context) {
    final appData = context.read<AppData>();
    final currentUser = appData.currentUser ?? "current user";

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Reset Category Test?'),
          content: Text(
            'Are you sure you want to clear all results for "${widget.mainKey}" for $currentUser?',
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
                appData.clearCategoryResults(widget.mainKey);
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        );
      },
    );
  }

  // --- 💡 NEW: Auto-advance logic ---
  void _onScorePressed(int score) {
    // Get the sub-keys from AppData
    final subKeys = context.read<AppData>().settingsData[widget.mainKey] ?? [];
    if (_selectedSubKey == null) return; // Should not happen, but good safety

    // 1. Record the result for the current item
    context.read<AppData>().updateResult(
      widget.mainKey,
      _selectedSubKey!,
      score,
    );

    // 2. Find the index of the current item
    final int currentIndex = subKeys.indexOf(_selectedSubKey!);
    String? nextKey;

    // 3. Find the next item, if one exists
    if (currentIndex != -1 && currentIndex < subKeys.length - 1) {
      nextKey = subKeys[currentIndex + 1];
    }
    // If it's the last item, nextKey will be null, disabling the buttons

    // 4. Set the new item as selected
    setState(() {
      _selectedSubKey = nextKey;
    });
  }

  // --- 💡 NEW: Item selector widget ---
  Widget _buildItemSelector() {
    final appData = context.watch<AppData>();
    final subKeys = appData.settingsData[widget.mainKey] ?? [];

    return Container(
      // Add a subtle background to separate it
      color: Theme.of(context).cardColor.withAlpha(200),
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      // Center the chips
      alignment: Alignment.center,
      child: Wrap(
        spacing: 8.0,
        runSpacing: 4.0,
        alignment: WrapAlignment.center,
        children: subKeys.map((subKey) {
          return ChoiceChip(
            label: Text(subKey),
            // Use a stronger selected color
            selectedColor: Theme.of(context).colorScheme.primaryContainer,
            selected: _selectedSubKey == subKey,
            onSelected: (isSelected) {
              setState(() {
                _selectedSubKey = isSelected ? subKey : null;
              });
            },
          );
        }).toList(),
      ),
    );
  }

  Widget _buildNumberPad() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 4.0),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withAlpha(128),
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          childAspectRatio: 5.5,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: 10,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemBuilder: (context, index) {
          final score = index + 1;
          return ElevatedButton(
            // 💡 MODIFIED: Use the new auto-advance function
            onPressed: _selectedSubKey == null
                ? null
                : () => _onScorePressed(score),
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
    final appData = context.watch<AppData>();
    final currentResults = appData.currentResultsData[widget.mainKey] ?? {};

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mainKey),
        // 💡 MODIFICATION: Set background color to match theme
        backgroundColor: const Color(0xFFF0EAD6),
        elevation: 0,
        scrolledUnderElevation: 1,
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: 'Reset This Category',
            onPressed: () => _showResetCategoryDialog(context),
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
      // --- 💡 MODIFIED: Page layout ---
      body: Column(
        children: [
          Expanded(
            // This part now only contains the results and tap area
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
                        // The item selector (ChoiceChip Wrap) has been MOVED
                        Text(
                          'Current Results for ${widget.mainKey}:',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 10),
                        if (currentResults.isEmpty)
                          const Text('No results yet.')
                        else
                          ...currentResults.entries.map((entry) {
                            return ListTile(
                              title: Text(entry.key),
                              trailing: Text(
                                entry.value.toString(),
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
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
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(153),
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
                            color: Colors.blue.withAlpha(128),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // --- 💡 NEW POSITION: Item selector is now here ---
          _buildItemSelector(),

          // --- 💡 NEW POSITION: Number pad is now here ---
          _buildNumberPad(),
        ],
      ),
    );
  }
}
