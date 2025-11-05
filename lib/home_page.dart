import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_data.dart';
import 'counting_page.dart'; // We will create this file
import 'dart:convert'; // For JSON and base64
import 'dart:html' as html; // For web-only download

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void _downloadResults(BuildContext context) {
    // Get the data from the AppData provider
    final appData = context.read<AppData>();
    final jsonString = appData.getResultsAsJsonString();

    // Create a downloadable link
    final bytes = utf8.encode(jsonString);
    final base64 = base64Encode(bytes);
    final anchor =
        html.AnchorElement(href: 'data:application/json;base64,$base64')
          ..setAttribute('download', 'results.json')
          ..click();
  }

  @override
  Widget build(BuildContext context) {
    // Watch for changes in AppData
    final appData = context.watch<AppData>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('JSON Data Collector'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- The 3 Control Buttons ---
            ElevatedButton(
              onPressed: () {
                // Call the loadSettings method in AppData
                context.read<AppData>().loadSettings();
              },
              child: const Text('Load Settings JSON'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: appData.resultsData.isEmpty
                  ? null // Disable button if there are no results
                  : () => _downloadResults(context),
              child: const Text('Download Results JSON'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                // Call the clearResults method in AppData
                context.read<AppData>().clearResults();
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red[100]),
              child: const Text('Clear Results Data'),
            ),

            const Divider(height: 40),

            // --- The List of Loaded Keys ---
            Text(
              'Categories',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),

            // This builds the list of buttons ("TAP", "SWIPE", etc.)
            Expanded(
              child: ListView.builder(
                itemCount: appData.settingsData.keys.length,
                itemBuilder: (context, index) {
                  final mainKey = appData.settingsData.keys.elementAt(index);
                  return Card(
                    child: ListTile(
                      title: Text(mainKey),
                      trailing: const Icon(Icons.arrow_forward_ios),
                      onTap: () {
                        // Go to Page 2, passing the key they tapped
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                CountingPage(mainKey: mainKey),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
