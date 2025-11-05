import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_data.dart';

// A simple class to store our tap effect's position
class TapEffect {
  final Offset position;
  TapEffect({required this.position});
}

class CountingPage extends StatefulWidget {
  final String mainKey; // e.g., "TAP" or "SWIPE"
  const CountingPage({super.key, required this.mainKey});

  @override
  State<CountingPage> createState() => _CountingPageState();
}

class _CountingPageState extends State<CountingPage> {
  // We need to keep track of which sub-key is currently selected
  String? _selectedSubKey;

  // --- New state variables ---
  int _mousePressCount = 0;
  final List<TapEffect> _tapEffects = [];
  // ---

  // This handles all the new logic for taps
  void _handlePageTap(PointerDownEvent event) {
    // 1. Create the new effect
    final effect = TapEffect(position: event.localPosition);

    setState(() {
      // 2. Increment counter
      _mousePressCount++;
      // 3. Add effect to the list to be drawn
      _tapEffects.add(effect);
    });

    // 4. Set a timer to remove the effect after a short time
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _tapEffects.remove(effect);
        });
      }
    });
  }

  //
  // --- 💡 THE MODIFICATION: Making buttons much shorter ---
  //
  Widget _buildNumberPad() {
    return Container(
      // Reduced container padding
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
          childAspectRatio: 4.5, // <-- 💡 KEY CHANGE: (Was 1.2) Makes buttons very short.
          crossAxisSpacing: 4, // Reduced spacing
          mainAxisSpacing: 4, // Reduced spacing
        ),
        itemCount: 10,
        shrinkWrap: true, // Don't let the grid scroll
        physics: const NeverScrollableScrollPhysics(),
        itemBuilder: (context, index) {
          final score = index + 1;
          return ElevatedButton(
            // Disable button if no sub-key is selected
            onPressed: _selectedSubKey == null
                ? null
                : () {
                    // Update the result in AppData
                    context.read<AppData>().updateResult(
                          widget.mainKey,
                          _selectedSubKey!,
                          score,
                        );
                  },
            // Make button smaller
            style: ElevatedButton.styleFrom(
              padding: EdgeInsets.zero, // Minimal padding
              textStyle: const TextStyle(
                fontSize: 12, // Small font
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
    // Get the list of sub-keys for this category (e.g., ["Left", "Right"])
    final subKeys = appData.settingsData[widget.mainKey] ?? [];
    // Get the current results for this category to display them
    final currentResults = appData.resultsData[widget.mainKey] ?? {};

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mainKey), // Title is the category name
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset Click Counter',
            onPressed: () {
              setState(() {
                _mousePressCount = 0;
              });
            },
          ),
          const SizedBox(width: 10), // Some spacing
        ],
      ),
      body: Column(
        children: [
          // --- 1. The main content area ---
          Expanded(
            child: Listener(
              onPointerDown: _handlePageTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // --- This is all your main page content ---
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // --- 1. The list of sub-key buttons ---
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

                        // --- 2. The list of current results ---
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
                                style:
                                    Theme.of(context).textTheme.headlineSmall,
                              ),
                            );
                          }),
                      ],
                    ),
                  ),

                  // --- Floating Click Counter ---
                  Align(
                    alignment: Alignment.topCenter, // Position at the top-center
                    child: IgnorePointer(
                      // Clicks pass through this widget
                      child: Container(
                        margin: const EdgeInsets.only(top: 20.0), // Space from app bar
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black
                              .withOpacity(0.6), // Semi-transparent background
                          borderRadius:
                              BorderRadius.circular(20), // Rounded corners
                        ),
                        child: Text(
                          'Clicks: $_mousePressCount',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white, // White text
                          ),
                        ),
                      ),
                    ),
                  ),

                  // --- This renders the tap effects ---
                  ..._tapEffects.map(
                    (effect) => Positioned(
                      // Position the effect where the tap happened
                      left: effect.position.dx - 12, // center the circle
                      top: effect.position.dy - 12, // center the circle
                      child: IgnorePointer(
                        // Clicks pass through this widget
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
                  // ---
                ],
              ),
            ),
          ),

          // --- 2. The number pad at the bottom ---
          _buildNumberPad(),
        ],
      ),
    );
  }
}