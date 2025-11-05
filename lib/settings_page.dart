import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app_data.dart';
import 'dart:convert' as convert; // Add prefix 'convert'
import 'package:web/web.dart' as web;

// Imports for the code editor
import 'package:code_text_field/code_text_field.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:highlight/languages/json.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  CodeController? _codeController;
  String _initialJsonText = '';

  @override
  void initState() {
    super.initState();
    _initialJsonText = context.read<AppData>().getSettingsAsJsonString();

    _codeController = CodeController(text: _initialJsonText, language: json);
  }

  @override
  void dispose() {
    _codeController?.dispose();
    super.dispose();
  }

  bool get _isDirty => _codeController?.text != _initialJsonText;

  Future<bool> _showUnsavedChangesDialog(BuildContext context) async {
    final bool? shouldPop = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Unsaved Changes'),
          content: const Text(
            'You have unsaved changes. Are you sure you want to discard them?',
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Discard'),
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
            ),
          ],
        );
      },
    );
    return shouldPop ?? false;
  }

  // --- 💡 NEW: Helper to show a detailed error dialog ---
  void _showJsonErrorDialog(dynamic e) {
    String errorDetails = e.toString();

    // FormatException gives us the best details
    if (e is FormatException) {
      errorDetails = e.message;
      if (e.offset != null) {
        errorDetails += '\n\nError is near character: ${e.offset}';
      }
    }

    if (context.mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Invalid JSON'),
          content: Text(
            'The settings text is not valid JSON.\n\n$errorDetails',
          ),
          actions: [
            TextButton(
              child: const Text('OK'),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      );
    }
  }

  void _onFormatJson() {
    if (_codeController == null) return;
    try {
      final currentText = _codeController!.text;
      final decoded = convert.json.decode(currentText);
      final formatted = const convert.JsonEncoder.withIndent(
        '  ',
      ).convert(decoded);
      _codeController!.text = formatted;
      _initialJsonText = formatted;
    } catch (e) {
      // 💡 MODIFICATION: Use the new detailed error dialog
      _showJsonErrorDialog(e);
    }
  }

  void _onSaveAndApply(BuildContext context) {
    if (_codeController == null) return;
    final jsonText = _codeController!.text;

    try {
      convert.json.decode(jsonText);
      context.read<AppData>().loadSettings(jsonText);
      _initialJsonText = jsonText;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings applied successfully!'),
          backgroundColor: Colors.green,
        ),
      );
      if (context.mounted) Navigator.of(context).pop();
    } catch (e) {
      // 💡 MODIFICATION: Use the new detailed error dialog
      _showJsonErrorDialog(e);
    }
  }

  void _onSaveToFile(BuildContext context) {
    if (_codeController == null) return;
    final jsonText = _codeController!.text;

    final timestamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '-');
    final filename = 'settings-$timestamp.json';

    final bytes = convert.utf8.encode(jsonText);
    final base64 = convert.base64Encode(bytes);

    web.HTMLAnchorElement()
      ..href = 'data:application/json;base64,$base64'
      ..setAttribute('download', filename)
      ..click();

    _initialJsonText = jsonText;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved as $filename')));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        if (!_isDirty) {
          Navigator.of(context).pop();
          return;
        }

        final bool shouldPop = await _showUnsavedChangesDialog(context);
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings Constructor'),
          actions: [
            IconButton(
              icon: const Icon(Icons.format_align_left),
              tooltip: 'Format JSON',
              onPressed: _onFormatJson,
            ),
            const SizedBox(width: 10),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              Expanded(
                child: CodeTheme(
                  data: CodeThemeData(styles: githubTheme),
                  child: SingleChildScrollView(
                    child: CodeField(
                      controller: _codeController!,
                      minLines: 20,
                      maxLines: 100,
                      textStyle: const TextStyle(fontFamily: 'monospace'),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.save_as),
                      label: const Text('Save to File'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                      ),
                      onPressed: () => _onSaveToFile(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Save & Apply'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                      ),
                      onPressed: () => _onSaveAndApply(context),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
